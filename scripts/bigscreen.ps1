# Starting, waiting for, and restarting Bigscreen Remote Desktop.
#
# Dot-source this file. It defines:
#   Find-BigscreenApp        newest installed app-x.y.z folder, its exe and log
#   Start-BigscreenApp       start it from its own folder with the debugger on
#   Wait-ForHeadset          wait for the headset to connect (or time out)
#   Set-StreamProfile        apply height / bitrate / fps through the debugger
#   Restart-BigscreenFollowingDisplays   the whole transition, in a safe order
#
# WHY RESTARTING. Bigscreen creates a screen capture for every monitor on the GPU
# when it starts. It cannot rebuild one for a monitor that has left the desktop,
# so switching a monitor off can stop its capture thread and take the stream with
# it. Rather than leave the stream dead, the session restarts Bigscreen whenever
# the set of attached displays changes: it then captures exactly the displays that
# are there now. The headset reconnects on its own, and the profile is re-applied.

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

function Start-BigscreenApp($app) {
    Start-Process -FilePath $app.Exe -WorkingDirectory $app.Dir -ArgumentList '--inspect=127.0.0.1:9229'
}

function Wait-ForHeadset($app, [datetime]$Since, [int]$TimeoutSeconds = 0) {
    # True when the headset has connected. Returns false if Bigscreen closes, or
    # if TimeoutSeconds passes (0 = wait for as long as it takes).
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $f = Get-Item $app.Log -EA SilentlyContinue
        if ($f -and $f.LastWriteTime -gt $Since -and (Select-String -Path $app.Log -Pattern 'DTLS connected' -Quiet)) { return $true }
        if (((Get-Date) - $Since).TotalSeconds -gt 10 -and -not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { return $false }
    }
    return $false
}

function Set-StreamProfile([int]$Height, [double]$Mbps, [int]$Fps) {
    if ($Height -le 0) { return 'stock profile - nothing to apply' }
    return (& node (Join-Path $PSScriptRoot 'bigscreen-quality.js') $Height $Mbps $Fps 2>&1 | Out-String).Trim()
}

function Restart-BigscreenFollowingDisplays {
    <# Rebuild the session around the displays that are attached now.

       The order matters and is the same one the shutdown uses: the stream is torn
       down and Bigscreen closed BEFORE any display change, because changing the
       primary display under a live stream crashed Bigscreen in testing, and a
       crash with a live encoder can reset the GPU.

       Returns an object: Ok, Steps (lines to log), Primary. #>
    param(
        $App,
        [int]$Height, [double]$Mbps, [int]$Fps,
        [string]$VirtualAdapter = 'Virtual Display Driver',
        [ValidateSet('monitor', 'virtual')] [string]$OnMonitorReturn = 'monitor',
        [int]$HeadsetTimeoutSeconds = 90
    )
    $steps = @()

    # 1. close Bigscreen first, stream torn down through its own debugger
    if (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'close-bigscreen.ps1') 2>&1
        $steps += '  ' + (($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '; ')
    }

    # 2. decide what should be primary now, and make it so
    $displays = @(Get-AttachedDisplays $VirtualAdapter)
    $physical = @($displays | Where-Object { -not $_.Virtual })
    $wantPhysical = $physical.Count -gt 0 -and $OnMonitorReturn -eq 'monitor'
    if ($wantPhysical) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prefer-virtual.ps1') -Restore -VirtualAdapter $VirtualAdapter 2>&1
    } else {
        # No monitor attached (or the user wants the stream kept on the virtual
        # display): make sure the virtual display is there and primary.
        $c = Connect-VirtualDisplay $VirtualAdapter
        if (-not $c.ok -and -not ($displays | Where-Object Virtual)) {
            return [pscustomobject]@{ Ok = $false; Steps = $steps + "  virtual display unavailable: $($c.why)"; Primary = $null }
        }
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prefer-virtual.ps1') -VirtualAdapter $VirtualAdapter 2>&1
    }
    $steps += '  ' + (($out | Select-Object -Last 1) -replace '^\s+', '')
    $primary = (Get-CcdSources | Where-Object Primary | Select-Object -First 1).Name

    # 3. start Bigscreen again: it now captures the displays that are attached
    $since = Get-Date
    Start-BigscreenApp $App
    if (-not (Wait-ForHeadset $App $since $HeadsetTimeoutSeconds)) {
        return [pscustomobject]@{ Ok = $false; Steps = $steps + '  the headset did not reconnect'; Primary = $primary }
    }

    # 4. the profile is a per-connection setting, so apply it again
    Start-Sleep -Seconds 5
    $steps += '  ' + (Set-StreamProfile $Height $Mbps $Fps)
    return [pscustomobject]@{ Ok = $true; Steps = $steps; Primary = $primary }
}
