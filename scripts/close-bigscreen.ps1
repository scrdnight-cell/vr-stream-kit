# Close Bigscreen without leaving its hardware encoder hanging.
#
# WHY. When Bigscreen dies with a live stream - a crash or a plain force-close -
# some GPU drivers leave the video engine hung, and Windows resets the graphics
# card about 1.5 s later (Event Viewer: "LiveKernelEvent 141"). What prevents it
# is order: tear the stream down first, let the encoder release, THEN end the
# process. A force-close after teardown did not reset the GPU in testing.
#
# "Let the encoder release" used to be a flat 3 s pause. It now waits for the
# teardown to report itself finished - Bigscreen logs "Shutting down remote
# desktop video stream." as its last teardown step - and only falls back to the
# full wait when that never appears (e.g. no stream was live).
#
# There is no gentle exit to wait for: the app keeps running in the tray when
# asked to close, so after teardown it is ended directly.
#
# Without the debugger (Bigscreen not started by this kit) the stream cannot be
# torn down first, and closing it may reset the GPU - this says so.

param([int]$SettleSeconds = 3)

function Running { @(Get-Process BigscreenRemoteDesktop -EA SilentlyContinue).Count -gt 0 }
if (-not (Running)) { '  Bigscreen is not running.'; exit 0 }

$debugger = $false
try { $null = Invoke-RestMethod 'http://127.0.0.1:9229/json/list' -TimeoutSec 2; $debugger = $true } catch { }

if ($debugger) {
    $proc = Get-Process BigscreenRemoteDesktop -EA SilentlyContinue | Select-Object -First 1
    $bsLog = if ($proc -and $proc.Path) { Join-Path (Split-Path $proc.Path -Parent) 'out.txt' }
    $before = if ($bsLog) { @(Get-Content $bsLog -EA SilentlyContinue).Count } else { 0 }
    $out = & node (Join-Path $PSScriptRoot 'bigscreen-close.js') 2>&1
    "  $out"
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    while ((Get-Date) -lt $deadline) {
        $lines = if ($bsLog) { @(Get-Content $bsLog -EA SilentlyContinue) } else { @() }
        if ($lines.Count -gt $before -and ($lines[$before..($lines.Count - 1)] -match 'Shutting down remote desktop video stream')) {
            Start-Sleep -Milliseconds 300      # the last teardown line is written as it happens
            break
        }
        Start-Sleep -Milliseconds 200
    }
} else {
    '  Bigscreen was not started by this kit, so the stream cannot be torn down first.'
}

if (Running) { taskkill /im BigscreenRemoteDesktop.exe /f > $null 2>&1 }
for ($i = 0; $i -lt 10 -and (Running); $i++) { Start-Sleep -Milliseconds 500 }
if (Running) { '  Bigscreen is still running after the close.'; exit 1 }
'  Bigscreen closed.'
exit 0
