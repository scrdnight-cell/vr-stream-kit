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
Start-Process powershell -WindowStyle Hidden -ArgumentList $guardArgs

# --- 5. start Bigscreen -------------------------------------------------------------------
'  [4/5] Starting Bigscreen.'
$started = Get-Date
Start-BigscreenApp $app
''
'        Connect from the headset now.'
''
if (-not (Wait-ForHeadset $app $started)) { Exit-Early 'Bigscreen closed before the headset connected.' }

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
