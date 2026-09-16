# Close Bigscreen with its stream shut down first.
#
# WHY. Changing displays under a live stream, or killing Bigscreen in the middle
# of one, crashed it in testing. So the order is: tear the stream down through
# Bigscreen's own functions, let the encoder release, THEN end the process.
#
# A correction, kept here because the old wording is in the history: this comment
# used to say a force-close makes Windows reset the graphics card about 1.5 s
# later ("LiveKernelEvent 141"). Measured later, that was wrong. Whenever any
# program crashes, Windows re-files the same queue of OLD GPU reports - on the
# test machine, 12 reports dated Dec 2024 to the day before - and those were read
# as new resets. Not one was from the sessions. Tearing down first is still the
# clean way to stop; it is not a guard against resets.
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
# torn down first - this says so.

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
