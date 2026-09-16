# Run one streaming session from start to finish.
#
#   1. stop any guardian left from an earlier session
#   2. close Bigscreen if it is running
#   3. connect the virtual display (parked between sessions) and make it primary
#   4. start the guardian, so a session that dies badly still hands the display back
#   5. start Bigscreen from its own folder with its debugger on 127.0.0.1
#   6. wait for the headset to connect, then apply the stream profile
#   7. watch the session; on R, shut down safely (see session-watch.ps1)
#
# Called by "Start VR Stream.bat" with the chosen profile.

param(
    [int]$Height = 1440, [double]$Mbps = 60, [int]$Fps = 30,
    [string]$VirtualAdapter = 'Virtual Display Driver',
    [string]$BigscreenDir = '',
    [ValidateSet('monitor', 'virtual')] [string]$OnMonitorReturn = 'monitor',
    [switch]$KeepVirtualDisplay
)
. (Join-Path $PSScriptRoot 'display.ps1')
. (Join-Path $PSScriptRoot 'bigscreen.ps1')

$here = $PSScriptRoot
$kit  = Split-Path $here -Parent
$logs = Join-Path $kit 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$logFile  = Join-Path $logs 'session.log'
# Everything the shared code says goes to the console AND the log: with the
# monitor off, the console cannot be read, so the log is the only record.
Set-KitLogger {
    param($m)
    $m
    try { Add-Content -Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs') 'session.log') -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), "$m".Trim()) } catch { }
}
$flagFile = Join-Path $kit 'config\session-active.json'

function Exit-Early([string]$why) {
    # A session that never got going must not leave the virtual display attached
    # and primary: hand the display back and park it, as a normal end would.
    ''; "  Stopped: $why"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'prefer-virtual.ps1') -Restore -VirtualAdapter $VirtualAdapter | Out-Null
    if (-not $KeepVirtualDisplay) { $r = Disconnect-VirtualDisplay $VirtualAdapter; if ($r.changed) { '  Virtual display parked.' } }
    Remove-Item $flagFile -Force -EA SilentlyContinue
    exit 1
}

# --- requirements --------------------------------------------------------------
if (-not (Get-Command node -EA SilentlyContinue)) {
    '  Node.js was not found. Install Node.js 22 or newer from https://nodejs.org and run this again.'; exit 1
}
$app = Find-BigscreenApp $BigscreenDir
if (-not $app) {
    '  Bigscreen Remote Desktop was not found under %LOCALAPPDATA%\BigscreenRemoteDesktop.'
    '  Install it, or set BIGSCREEN_DIR in "Start VR Stream.bat" to its app-x.y.z folder.'; exit 1
}

# --- 1. stale guardians ------------------------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*display-guardian.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

# --- 2. close Bigscreen ----------------------------------------------------------------
'  [1/5] Closing Bigscreen if it is running.'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'close-bigscreen.ps1')

# --- 3. connect the virtual display, then make it primary ---------------------------------
# Parked between sessions (see display.ps1), so it is connected fresh each time.
'  [2/5] Connecting the virtual display.'
Save-PrimaryPhysical $VirtualAdapter          # remember where the desktop belongs
$r = Connect-VirtualDisplay $VirtualAdapter
if (-not $r.ok) { ''; "  Stopped: $($r.why)."; exit 1 }
if ($r.changed) { '        connected.' }
Save-VirtualMode $VirtualAdapter
'  [3/5] Making the virtual display primary. Your monitor stays on.'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'prefer-virtual.ps1') -VirtualAdapter $VirtualAdapter
if ($LASTEXITCODE -ne 0) { Exit-Early 'the display switch did not hold.' }

# --- 4. the safety net ---------------------------------------------------------------------
# From here the virtual display is attached, so from here something must be
# watching: if this window dies without handing the display back, the guardian
# does it instead. The flag says "a session is in progress"; session-watch.ps1
# deletes it once the display is back with the monitor.
New-Item -ItemType Directory -Force -Path (Split-Path $flagFile -Parent) | Out-Null
[pscustomobject]@{ Pid = $PID; Started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $flagFile -Encoding utf8
$guardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'display-guardian.ps1'),
               '-OwnerPid', $PID, '-VirtualAdapter', $VirtualAdapter, '-LogFile', $logFile, '-FlagFile', $flagFile)
if ($KeepVirtualDisplay) { $guardArgs += '-KeepVirtualDisplay' }   # switches passed only when on
# QUOTE EVERY ARGUMENT. Start-Process joins an argument array with plain spaces and
# no quoting, so "Virtual Display Driver" arrived as three words: the guardian
# failed to bind its parameters and exited the moment it started, leaving every
# session with no safety net. A kit folder with a space in its path breaks the
# same way. Unlike the & calls elsewhere, Start-Process needs this done by hand.
$guardLine = ($guardArgs | ForEach-Object { $a = "$_"; if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }) -join ' '
$guardian = Start-Process powershell -WindowStyle Hidden -ArgumentList $guardLine -PassThru
# Checked, not assumed: a guardian that dies on arrival is the failure that went
# unnoticed. It has nothing to do yet, so if it has already exited, it failed.
Start-Sleep -Seconds 2
if ($guardian.HasExited) {
    $msg = "  WARNING: the safety-net guardian did not stay running (exit $($guardian.ExitCode)). If this window is closed, the display will not be handed back automatically - use R."
    $msg
    try { Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg.Trim()) } catch { }
}

# --- 5. start Bigscreen -------------------------------------------------------------------
'  [4/5] Starting Bigscreen.'
if (-not (Start-BigscreenApp $app)) { Exit-Early 'Bigscreen did not start.' }
''
'        Connect from the headset now. You can switch the monitor off first -'
'        the session follows it either way.'
''
# Waiting for the headset is the one window where a display change used to go
# unnoticed, and switching the monitor off before putting the headset on is a
# normal way to work. So the wait keeps the capture right while it waits.
if (-not (Wait-ForHeadsetConnecting -App $app -Height $Height -Mbps $Mbps -Fps $Fps `
            -VirtualAdapter $VirtualAdapter -OnMonitorReturn $OnMonitorReturn)) {
    Exit-Early 'Bigscreen closed before the headset connected.'
}

# --- 6. apply the profile -----------------------------------------------------------------
if ($Height -gt 0) {
    '  [5/5] Headset connected. Applying the profile in 5 seconds...'
    Start-Sleep -Seconds 5
    '  ' + (Set-StreamProfile $Height $Mbps $Fps)
} else {
    '  [5/5] Headset connected. Stock profile: leaving Bigscreen''s own settings.'
}
''
'  Your monitor can be switched off now - the session follows it.'
'  TO END THE SESSION: press R in this window. Nothing else is needed.'
''

# --- 7. watch, then shut down -----------------------------------------------------------------
$watchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'session-watch.ps1'),
               '-BigscreenDir', $app.Dir, '-Height', $Height, '-Mbps', $Mbps, '-Fps', $Fps,
               '-VirtualAdapter', $VirtualAdapter, '-LogFile', $logFile, '-FlagFile', $flagFile,
               '-OnMonitorReturn', $OnMonitorReturn)
if ($KeepVirtualDisplay) { $watchArgs += '-KeepVirtualDisplay' }
& powershell @watchArgs
exit $LASTEXITCODE
