# Starting, waiting for, and restarting Bigscreen Remote Desktop.
#
# Dot-source this file. It defines:
#   Find-BigscreenApp          newest installed app-x.y.z folder, its exe and log
#   Get-BigscreenMonitors      which displays it built a capture for, from its log
#   Test-CaptureMatchesDisplays   is that still the set of displays attached?
#   Start-BigscreenApp         start it, and confirm it really started
#   Stop-BigscreenApp          close it, and wait until the process is gone
#   Wait-ForHeadsetConnecting  wait for the headset, fixing the capture if it is wrong
#   Restart-BigscreenFollowingDisplays   the whole transition, in a safe order
#
# WHY RESTARTING. Bigscreen creates a screen capture for every monitor on the GPU
# when it starts, and cannot rebuild one for a monitor that has left the desktop.
# Its own log shows what happens when a monitor is switched off mid-session:
#
#   Failed to recreate duplication object: -2147467259     (once a second)
#
# It recovers only when that monitor comes back, so the headset sees a dead
# picture for as long as the monitor is off. Restarting Bigscreen is what fixes
# the capture, because a fresh start enumerates the displays that exist now.
#
# ONE INSTANCE AT A TIME. Bigscreen is an Electron app and refuses to run twice:
# starting a new instance before the old one has finished exiting silently does
# nothing, and the session is left with no app at all. Every restart therefore
# waits for the old process to be gone, and confirms the new one is up, rather
# than assuming either.

# Callers set a logger so that what happens during a restart reaches the session
# log - with the monitor off, the console cannot be read.
$script:KitLogger = $null
function Set-KitLogger([scriptblock]$Logger) { $script:KitLogger = $Logger }
function Write-KitLog([string]$Message) {
    if ($script:KitLogger) { & $script:KitLogger $Message } else { $Message }
}

function Find-BigscreenApp([string]$BigscreenDir = '') {
    if (-not $BigscreenDir) {
        # Bigscreen installs per user, one folder per version: pick the newest.
        $root = Join-Path $env:LOCALAPPDATA 'BigscreenRemoteDesktop'
        $BigscreenDir = Get-ChildItem $root -Directory -Filter 'app-*' -EA SilentlyContinue |
                        Sort-Object { [version]($_.Name -replace '^app-', '') } -Descending |
                        Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $BigscreenDir) { return $null }
    $exe = Join-Path $BigscreenDir 'BigscreenRemoteDesktop.exe'
    if (-not (Test-Path $exe)) { return $null }
    # Bigscreen writes its log into the folder it starts from.
    return [pscustomobject]@{ Dir = $BigscreenDir; Exe = $exe; Log = (Join-Path $BigscreenDir 'out.txt') }
}

function Get-BigscreenMonitors($App) {
    <# Which displays Bigscreen actually built a capture for, from its own log.

       This is the fact that matters. Watching for display CHANGES misses one made
       while nothing was looking, and the session then runs on a capture that is
       already wrong with nothing left to notice. A mismatch, by contrast, stays
       true until it is fixed. #>
    $lines = @(Get-Content $App.Log -EA SilentlyContinue)
    if (-not $lines.Count) { return @() }
    $start = 0      # only the newest launch: the log is rewritten each time
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match 'Initiating BigSoup') { $start = $i; break } }
    $found = @()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        # e.g. "    Found monitor: \\.\DISPLAY5."  - take the token, drop the full stop.
        if ($lines[$i] -match 'Found monitor:\s*(\S+)') { $found += ($matches[1].TrimEnd('.')) }
    }
    return $found
}

function Test-CaptureMatchesDisplays($App, [string]$VirtualAdapter = 'Virtual Display Driver') {
    $captured = @(Get-BigscreenMonitors $App | Sort-Object -Unique)
    $attached = @(Get-AttachedDisplays $VirtualAdapter | ForEach-Object Name | Sort-Object -Unique)
    return [pscustomobject]@{
        Match    = (($captured -join '|') -eq ($attached -join '|')) -and $captured.Count -gt 0
        Captured = $captured
        Attached = $attached
        Known    = $captured.Count -gt 0
    }
}

function Save-BigscreenLog($App, [string]$LogDir, [string]$Tag) {
    # out.txt is rewritten on every launch, so keep a copy: it is the only record
    # of what the previous capture was built from.
    try {
        if (-not (Test-Path $App.Log)) { return $null }
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $dest = Join-Path $LogDir ("bigscreen-{0}-{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Tag)
        Copy-Item $App.Log $dest -Force
        return $dest
    } catch { return $null }
}

function Stop-BigscreenApp([int]$TimeoutSeconds = 20) {
    <# Close Bigscreen and do not return until the process is really gone.

       Starting the next instance a moment too early is the same as not starting
       it: Electron's single-instance lock makes the new process exit silently,
       and the session is then left with nothing running. #>
    if (-not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { return $true }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'close-bigscreen.ps1') 2>&1
    Write-KitLog ('  ' + (($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '; '))
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { Start-Sleep -Seconds 1; return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-KitLog "  Bigscreen is still running $TimeoutSeconds s after being asked to close."
    return $false
}

function Start-BigscreenApp($App, [int]$TimeoutSeconds = 20) {
    # Start it, then confirm: a start that silently did nothing must not be
    # mistaken for a running app.
    #
    # ELECTRON_RUN_AS_NODE. Some hosts set this for their own child processes -
    # VS Code's extension host does, and so do tools and tasks run from it. It is
    # inherited, and it makes ANY Electron app, Bigscreen included, run as bare
    # Node with no script: it exits at once with code 0, writes nothing and shows
    # nothing. Cleared here so the kit works wherever it is launched from.
    Remove-Item Env:ELECTRON_RUN_AS_NODE -EA SilentlyContinue
    $before = @(Get-Content $App.Log -EA SilentlyContinue).Count
    Start-Process -FilePath $App.Exe -WorkingDirectory $App.Dir -ArgumentList '--inspect=127.0.0.1:9229'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue) {
            # Running - and it has written its own log, which proves this is a new
            # launch rather than the old process still shutting down.
            $now = @(Get-Content $App.Log -EA SilentlyContinue).Count
            if ($now -ne $before) { return $true }
        }
    }
    Write-KitLog "  Bigscreen did not start within $TimeoutSeconds s."
    return $false
}

function Set-StreamProfile([int]$Height, [double]$Mbps, [int]$Fps) {
    if ($Height -le 0) { return 'stock profile - nothing to apply' }
    return (& node (Join-Path $PSScriptRoot 'bigscreen-quality.js') $Height $Mbps $Fps 2>&1 | Out-String).Trim()
}

function Set-PrimaryForDisplays([string]$VirtualAdapter = 'Virtual Display Driver', [string]$OnMonitorReturn = 'monitor') {
    <# Point the desktop at whatever should be primary for the displays attached
       right now: the monitor if one is there and the user wants it, otherwise the
       virtual display. #>
    $displays = @(Get-AttachedDisplays $VirtualAdapter)
    $physical = @($displays | Where-Object { -not $_.Virtual })
    if ($physical.Count -gt 0 -and $OnMonitorReturn -eq 'monitor') {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prefer-virtual.ps1') -Restore -VirtualAdapter $VirtualAdapter 2>&1
    } else {
        $c = Connect-VirtualDisplay $VirtualAdapter
        if (-not $c.ok -and -not ($displays | Where-Object Virtual)) {
            Write-KitLog "  virtual display unavailable: $($c.why)"
            return [pscustomobject]@{ Ok = $false; Primary = $null }
        }
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prefer-virtual.ps1') -VirtualAdapter $VirtualAdapter 2>&1
    }
    Write-KitLog ('  ' + (($out | Select-Object -Last 1) -replace '^\s+', ''))
    return [pscustomobject]@{ Ok = $true; Primary = (Get-CcdSources | Where-Object Primary | Select-Object -First 1).Name }
}

function Restart-BigscreenFollowingDisplays {
    <# Rebuild the session around the displays attached now.

       The order is the shutdown's order, for the same reason: the stream is torn
       down and Bigscreen closed BEFORE any display change, because changing the
       primary display under a live stream crashed Bigscreen in testing, and a
       crash with a live encoder can reset the GPU. #>
    param(
        $App,
        [int]$Height, [double]$Mbps, [int]$Fps,
        [string]$VirtualAdapter = 'Virtual Display Driver',
        [string]$OnMonitorReturn = 'monitor',
        [int]$HeadsetTimeoutSeconds = 120,
        [switch]$SkipHeadsetWait
    )
    if (-not (Stop-BigscreenApp)) { return [pscustomobject]@{ Ok = $false; Primary = $null } }

    $aim = Set-PrimaryForDisplays $VirtualAdapter $OnMonitorReturn
    if (-not $aim.Ok) { return [pscustomobject]@{ Ok = $false; Primary = $null } }

    if (-not (Start-BigscreenApp $App)) { return [pscustomobject]@{ Ok = $false; Primary = $aim.Primary } }
    $started = Get-Date
    Start-Sleep -Seconds 1
    $m = Test-CaptureMatchesDisplays $App $VirtualAdapter
    Write-KitLog "  Bigscreen restarted, capturing $($m.Captured -join ', ')."
    if ($SkipHeadsetWait) { return [pscustomobject]@{ Ok = $true; Primary = $aim.Primary } }

    # The headset reconnects on its own; give it time before calling it a failure.
    $deadline = (Get-Date).AddSeconds($HeadsetTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $f = Get-Item $App.Log -EA SilentlyContinue
        if ($f -and $f.LastWriteTime -gt $started -and (Select-String -Path $App.Log -Pattern 'DTLS connected' -Quiet)) {
            Start-Sleep -Seconds 5
            Write-KitLog ('  ' + (Set-StreamProfile $Height $Mbps $Fps))
            return [pscustomobject]@{ Ok = $true; Primary = $aim.Primary }
        }
        if (-not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) {
            Write-KitLog '  Bigscreen closed while waiting for the headset.'
            return [pscustomobject]@{ Ok = $false; Primary = $aim.Primary }
        }
    }
    Write-KitLog "  the headset has not reconnected after $HeadsetTimeoutSeconds s."
    return [pscustomobject]@{ Ok = $false; Primary = $aim.Primary }
}

function Wait-ForHeadsetConnecting {
    <# Wait for the headset, keeping the capture correct while waiting.

       Switching the monitor off before putting the headset on is a normal way to
       work, and it used to be the one window where nothing was watching: the
       capture was built for a monitor that then vanished, and the headset arrived
       to a dead picture. So the same mismatch check runs here. #>
    param(
        $App,
        [int]$Height, [double]$Mbps, [int]$Fps,
        [string]$VirtualAdapter = 'Virtual Display Driver',
        [string]$OnMonitorReturn = 'monitor',
        [int]$SettleSeconds = 2
    )
    $since = Get-Date
    $mismatchSince = $null
    while ($true) {
        Start-Sleep -Seconds 2
        $connected = $false
        $f = Get-Item $App.Log -EA SilentlyContinue
        if ($f -and $f.LastWriteTime -gt $since -and (Select-String -Path $App.Log -Pattern 'DTLS connected' -Quiet)) { $connected = $true }
        if (-not $connected -and ((Get-Date) - $since).TotalSeconds -gt 15 -and -not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { return $false }

        $m = Test-CaptureMatchesDisplays $App $VirtualAdapter
        if ($m.Known -and -not $m.Match) {
            if (-not $mismatchSince) { $mismatchSince = Get-Date }
            elseif (((Get-Date) - $mismatchSince).TotalSeconds -ge $SettleSeconds) {
                $mismatchSince = $null
                Write-KitLog "  Displays changed while waiting - capturing $($m.Captured -join ', '), attached $($m.Attached -join ', '). Restarting Bigscreen."
                $r = Restart-BigscreenFollowingDisplays -App $App -Height $Height -Mbps $Mbps -Fps $Fps `
                        -VirtualAdapter $VirtualAdapter -OnMonitorReturn $OnMonitorReturn -SkipHeadsetWait
                if (-not $r.Ok) { return $false }
                $since = Get-Date
                Write-KitLog '  Connect from the headset now.'
            }
            continue
        }
        $mismatchSince = $null
        if ($connected) { return $true }
    }
}
