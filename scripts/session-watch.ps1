# Watch a session, follow the displays, then shut down in a safe order.
#
# While the session runs:
#   - every time the headset (re)connects, re-apply the chosen stream profile: a
#     reconnect resets the stream to the headset menu's own quality;
#   - every time the set of attached displays changes - the monitor switched off,
#     switched back on, a cable moved - restart Bigscreen so it captures the
#     displays that are there now (see bigscreen.ps1 for why).
#
# The session ends when R is pressed, Bigscreen stops running, or the headset has
# been gone for $GraceSeconds. Then, in this order:
#   1. tear the stream down and close Bigscreen   (before any display change)
#   2. make the physical monitor primary, or leave the guardian waiting for it
#   3. check Windows' logs for a GPU reset since the shutdown began
#   4. print the result; exit 0 if clean, 1 if not
#
# Why the order: changing the primary display under a live stream crashed
# Bigscreen in testing, and a crash with a live encoder can reset the GPU.

param(
    [Parameter(Mandatory)] [string]$BigscreenDir,
    [int]$Height = 1440, [double]$Mbps = 60, [int]$Fps = 30,
    [int]$GraceSeconds = 60,
    [string]$VirtualAdapter = 'Virtual Display Driver',
    [ValidateSet('monitor', 'virtual')] [string]$OnMonitorReturn = 'monitor',
    [string]$LogFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\session.log'),
    [string]$FlagFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\session-active.json'),
    [switch]$KeepVirtualDisplay
)
. (Join-Path $PSScriptRoot 'display.ps1')
. (Join-Path $PSScriptRoot 'bigscreen.ps1')

# How the display-change rule is kept calm. A monitor waking up, a resolution
# change or a quick flick of the power switch must not start a restart storm:
#   DwellSeconds     the new layout has to still be there this long
#   CooldownSeconds  no second restart until this long after the last one
#   MaxRestarts      after this many, stop restarting and say so
$DwellSeconds    = 5
$CooldownSeconds = 30
$MaxRestarts     = 5

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile -Parent) | Out-Null
$here = $PSScriptRoot
$app  = Find-BigscreenApp $BigscreenDir
function Say($m) {
    $line = "  $((Get-Date).ToString('HH:mm:ss'))  $m"
    $line
    try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $line.Trim()) } catch { }
}

Say "---- session started ($Height lines, $Mbps Mbps, $Fps fps) ----"
Say 'Press R in this window to end the session.'

$seen = @(Get-Content $app.Log -EA SilentlyContinue).Count
$downSince = $null
$reason = $null

$signature   = Get-DisplaySetSignature
$pendingSig  = $null       # a change seen, waiting out the dwell
$pendingAt   = $null
$lastRestart = [datetime]::MinValue
$restarts    = 0
$capped      = $false

while (-not $reason) {
    Start-Sleep -Seconds 2
    try {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'R') { $reason = 'R pressed'; break }
    } catch { }

    if (-not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { $reason = 'Bigscreen is no longer running'; break }

    # --- has the set of attached displays changed? ------------------------------------
    $now = Get-DisplaySetSignature
    if ($now -and $now -ne $signature) {
        if ($now -ne $pendingSig) { $pendingSig = $now; $pendingAt = Get-Date }      # start the dwell
        elseif (((Get-Date) - $pendingAt).TotalSeconds -ge $DwellSeconds) {
            $signature = $now; $pendingSig = $null
            $physical = @(Get-AttachedDisplays $VirtualAdapter | Where-Object { -not $_.Virtual })
            $what = if ($physical.Count) { 'A monitor is back' } else { 'The monitor is gone' }

            if ($capped) { }
            elseif (((Get-Date) - $lastRestart).TotalSeconds -lt $CooldownSeconds) {
                Say "$what - too soon after the last restart, leaving the stream as it is."
            }
            else {
                $restarts++
                if ($restarts -gt $MaxRestarts) {
                    $capped = $true
                    Say 'The displays keep changing - not restarting again. Press R to end the session.'
                } else {
                    $goal = if ($physical.Count -and $OnMonitorReturn -eq 'monitor') { 'monitor primary' } else { 'the virtual display' }
                    Say "$what - restarting Bigscreen on $goal (restart $restarts of $MaxRestarts)."
                    $downSince = $null                     # a deliberate restart is not a lost headset
                    $r = Restart-BigscreenFollowingDisplays -App $app -Height $Height -Mbps $Mbps -Fps $Fps `
                            -VirtualAdapter $VirtualAdapter -OnMonitorReturn $OnMonitorReturn
                    foreach ($s in $r.Steps) { Say $s }
                    $lastRestart = Get-Date
                    $downSince = $null
                    $signature = Get-DisplaySetSignature   # the restart may have moved things itself
                    $seen = @(Get-Content $app.Log -EA SilentlyContinue).Count   # fresh log, fresh start
                    if ($r.Ok) { Say "Streaming again, primary is $($r.Primary)." }
                    else { Say 'The stream did not come back. Press R to end the session, or connect from the headset again.' }
                    continue
                }
            }
        }
    } elseif ($pendingSig) { $pendingSig = $null }        # it went back to what it was

    # --- what Bigscreen is reporting --------------------------------------------------
    $lines = @(Get-Content $app.Log -EA SilentlyContinue)
    if ($lines.Count -lt $seen) { $seen = 0 }             # log rewritten: Bigscreen restarted
    $new = if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] } else { @() }
    $seen = $lines.Count

    foreach ($l in $new) {
        if ($l -like '*Shutting down remote desktop data stream*') {
            if (-not $downSince) { $downSince = Get-Date; Say "Stream down. Waiting $GraceSeconds s for the headset to reconnect." }
        }
        elseif ($l -like '*DTLS connected*' -and $Height -le 0) {
            $downSince = $null
            Say 'Headset connected (stock profile - nothing to apply).'
        }
        elseif ($l -like '*DTLS connected*') {
            $downSince = $null
            Say "Headset connected - applying $Height lines, $Mbps Mbps, $Fps fps in 5 s."
            Start-Sleep -Seconds 5
            Say "  $(Set-StreamProfile $Height $Mbps $Fps)"
        }
    }
    if ($downSince -and ((Get-Date) - $downSince).TotalSeconds -ge $GraceSeconds) { $reason = "the headset has been gone for $GraceSeconds s" }
}

Say "Session over: $reason."
$shutdownAt = Get-Date

# 1. Close Bigscreen before any display change.
$closed = $true
if (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue) {
    Say 'Stopping the stream and closing Bigscreen.'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'close-bigscreen.ps1') 2>&1
    foreach ($o in $out) { Say "  $("$o".Trim())" }
    $closed = -not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)
}

# 2. Hand the display back, now or - through the guardian - when the monitor is on.
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'prefer-virtual.ps1') -Restore -VirtualAdapter $VirtualAdapter 2>&1
$parkFailed = $false
if ($LASTEXITCODE -eq 0) {
    $display = 'monitor is primary'
    Say "Display handed back:$(($out | Select-Object -Last 1))"
    # Park the virtual display so an idle monitor switching off can never strand
    # the desktop on a screen nobody can see.
    if (-not $KeepVirtualDisplay) {
        $r = Disconnect-VirtualDisplay $VirtualAdapter
        if ($r.ok) { $display += ', virtual display parked'; Say "Virtual display: $($r.why)." }
        else { $parkFailed = $true; $display += ", virtual display NOT parked ($($r.why))"; Say "Virtual display not parked: $($r.why)." }
    }
    # The desktop is safe: the guardian has nothing left to do.
    Remove-Item $FlagFile -Force -EA SilentlyContinue
} else {
    # The monitor is off. The guardian started with this session is already
    # watching for it, and will hand the display back and park the virtual
    # display as soon as it appears - so the flag stays, and so does it.
    $display = 'monitor is off - it will be made primary when you switch it on'
    if (-not $KeepVirtualDisplay) { $display += ', and the virtual display parked' }
    Say 'Monitor not attached - left with the guardian, which is waiting for it.'
}

# 3. Did the shutdown reset the GPU? Checked, not assumed.
Start-Sleep -Seconds 4
$reset = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; StartTime = $shutdownAt } -EA SilentlyContinue |
           Where-Object { $_.Message -match 'LiveKernelEvent' -and $_.Message -match 'P1:\s*141' })
$gpu = if ($reset.Count) { "GPU RESET at $($reset[-1].TimeCreated.ToString('HH:mm:ss'))" } else { 'no GPU reset' }

$ok = $closed -and -not $reset.Count -and -not $parkFailed
$verdict = if ($ok) { 'SHUTDOWN COMPLETE' } else { 'SHUTDOWN FINISHED WITH PROBLEMS' }
Say "$verdict - Bigscreen $(if ($closed) { 'closed' } else { 'STILL RUNNING' }), $gpu, $display."
''
'  ================================================================'
"   $verdict"
"     Bigscreen : $(if ($closed) { 'closed' } else { 'STILL RUNNING' })"
"     GPU       : $gpu"
"     Display   : $display"
'  ================================================================'
if (-not $ok) { exit 1 }
exit 0
