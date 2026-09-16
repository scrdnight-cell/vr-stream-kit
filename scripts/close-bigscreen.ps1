# Close Bigscreen without leaving its hardware encoder hanging.
#
# WHY. When Bigscreen dies with a live stream - a crash or a plain force-close -
# some GPU drivers leave the video engine hung, and Windows resets the graphics
# card about 1.5 s later (Event Viewer: "LiveKernelEvent 141"). What prevents it
# is order: tear the stream down first, pause briefly for the encoder to
# release, THEN end the process. A force-close after teardown did not reset the
# GPU in testing.
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
    $out = & node (Join-Path $PSScriptRoot 'bigscreen-close.js') 2>&1
    "  $out"
    Start-Sleep -Seconds $SettleSeconds
} else {
    '  Bigscreen was not started by this kit, so the stream cannot be torn down first.'
}

if (Running) { taskkill /im BigscreenRemoteDesktop.exe /f > $null 2>&1 }
for ($i = 0; $i -lt 10 -and (Running); $i++) { Start-Sleep -Milliseconds 500 }
if (Running) { '  Bigscreen is still running after the close.'; exit 1 }
'  Bigscreen closed.'
exit 0
