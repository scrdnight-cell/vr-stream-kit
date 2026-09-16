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

# WHAT TRIGGERS A RESTART. Not "the displays changed" - that misses a change made
# while nothing was watching, and the session then runs on a capture that is
# already wrong. The trigger is the fact itself: Bigscreen's own log says which
# monitors it built a capture for, and if that no longer matches what is attached,
# the capture is broken and only a restart fixes it.
#
# Kept calm by:
#   SettleSeconds    the mismatch has to still be true this long (displays settle)
#   CooldownSeconds  no second restart until this long after the last one
#   MaxRestarts      after this many, stop restarting and say so
#
# NEVER BLIND. A restart returns as soon as Bigscreen is back up; waiting for the
# headset happens here, in this loop, like any other reconnect. So R, the display
# check and the headset timeout all keep working while a restart settles - before,
# a restart waited up to 2 minutes for the headset and ignored everything else.
$SettleSeconds   = 1
$CooldownSeconds = 15
$MaxRestarts     = 6

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile -Parent) | Out-Null
$here = $PSScriptRoot
$app  = Find-BigscreenApp $BigscreenDir
function Say($m) {
    $line = "  $((Get-Date).ToString('HH:mm:ss'))  $m"
    $line
    try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $line.Trim()) } catch { }
}
# The shared start/stop/restart code reports through here, so a restart is
# recorded step by step even with the monitor off.
Set-KitLogger { param($m) Say "$m" }

Say "---- session started ($Height lines, $Mbps Mbps, $Fps fps) ----"
Say 'Press R in this window to end the session.'

$seen = @(Get-Content $app.Log -EA SilentlyContinue).Count
$downSince = $null
$reason = $null

$mismatchSince = $null     # when the capture first stopped matching the displays
$awaitingSince = $null     # a restart is waiting for the headset; when it was detected
$lastRestart   = [datetime]::MinValue
$restarts      = 0
$capped        = $false
$cooldownNoted = $false    # said once per wait, not once a second

# Check once at startup: a monitor switched off while the headset was connecting
# leaves a wrong capture that never "changes" again.
$m0 = Test-CaptureMatchesDisplays $app $VirtualAdapter
if ($m0.Known -and -not $m0.Match) { Say "Bigscreen is capturing $($m0.Captured -join ', ') but $($m0.Attached -join ', ') is attached." }
elseif ($m0.Known) { Say "Capturing $($m0.Captured -join ', ')." }

while (-not $reason) {
    Start-Sleep -Seconds 1
    try {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'R') { $reason = 'R pressed'; break }
    } catch { }

    if (-not (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)) { $reason = 'Bigscreen is no longer running'; break }

    # --- does Bigscreen's capture still match the displays that exist? ------------------
    $m = Test-CaptureMatchesDisplays $app $VirtualAdapter
    if ($m.Known -and -not $m.Match) {
        if (-not $mismatchSince) { $mismatchSince = Get-Date }
        elseif (((Get-Date) - $mismatchSince).TotalSeconds -ge $SettleSeconds) {
            $detectedAt = $mismatchSince
            $mismatchSince = $null
            $physical = @(Get-AttachedDisplays $VirtualAdapter | Where-Object { -not $_.Virtual })
            # Say what actually changed, from the difference between the two lists -
            # not from whether a monitor happens to be attached.
            $virtualNow = (Get-AttachedDisplays $VirtualAdapter | Where-Object Virtual | Select-Object -First 1).Name
            $gone  = @($m.Captured | Where-Object { $_ -notin $m.Attached })
            $added = @($m.Attached | Where-Object { $_ -notin $m.Captured })
            $what = if ($gone.Count) {
                        if (-not $virtualNow -and $physical.Count) { 'The virtual display is gone' } else { 'The monitor is gone' }
                    } elseif ($added.Count) {
                        if ($virtualNow -and $added -contains $virtualNow) { 'The virtual display is back' } else { 'A monitor is back' }
                    } else { 'The displays changed' }
            $sinceLast = ((Get-Date) - $lastRestart).TotalSeconds
            $inCooldown = $sinceLast -lt $CooldownSeconds
            # One line per event: while waiting out the gap between restarts this
            # branch runs every second, and the log should say it once, not fifteen times.
            if (-not $capped -and -not ($inCooldown -and $cooldownNoted)) {
                Say "$what - capturing $($m.Captured -join ', '), attached $($m.Attached -join ', ')."
            }

            if ($capped) { }
            elseif ($inCooldown) {
                if (-not $cooldownNoted) {
                    Say ("  too soon after the last restart - restarting in {0:N0} s if it has not settled back." -f ($CooldownSeconds - $sinceLast))
                    $cooldownNoted = $true
                }
                $mismatchSince = (Get-Date).AddSeconds(-$SettleSeconds)   # try again next loop
            }
            else {
                $cooldownNoted = $false
                $restarts++
                if ($restarts -gt $MaxRestarts) {
                    $capped = $true
                    Say 'The displays keep changing - not restarting again. Press R to end the session.'
                } else {
                    $goal = if ($physical.Count -and $OnMonitorReturn -eq 'monitor') { 'monitor primary' } else { 'the virtual display' }
                    Say "Restarting Bigscreen on $goal (restart $restarts of $MaxRestarts)."
                    $kept = Save-BigscreenLog $app (Split-Path $LogFile -Parent) 'before-restart'
                    if ($kept) { Say "  kept Bigscreen's log as $(Split-Path $kept -Leaf)" }
                    $downSince = $null                     # a deliberate restart is not a lost headset
                    $r = Restart-BigscreenFollowingDisplays -App $app -Height $Height -Mbps $Mbps -Fps $Fps `
                            -VirtualAdapter $VirtualAdapter -OnMonitorReturn $OnMonitorReturn -SkipHeadsetWait
                    $lastRestart = Get-Date
                    $seen = 0                               # the new launch's log, from its first line
                    if ($r.Ok) {
                        # The headset reconnect is handled below, like any reconnect. If it
                        # never comes back, the usual timeout ends the session.
                        $awaitingSince = $detectedAt
                        $downSince = Get-Date
                        Say "Bigscreen is back up (primary $($r.Primary)) - waiting for the headset. R still works."
                    } else {
                        Say 'Bigscreen did not come back up. Press R to end the session.'
                    }
                    continue
                }
            }
        }
    } else { $mismatchSince = $null; $cooldownNoted = $false }

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
            Say "Headset connected - applying $Height lines, $Mbps Mbps, $Fps fps."
            Say "  $(Set-StreamProfileWhenReady $Height $Mbps $Fps)"
        }
        if ($l -like '*DTLS connected*' -and $awaitingSince) {
            # Measured, so a change in restart speed shows up in the log, not just in a
            # claim - and only called "streaming again" if the capture still matches.
            # If the displays changed again while the headset was reconnecting, the
            # stream is about to be rebuilt once more, and the log should say so.
            $secs = ((Get-Date) - $awaitingSince).TotalSeconds
            $check = Test-CaptureMatchesDisplays $app $VirtualAdapter
            if ($check.Known -and -not $check.Match) {
                Say ("Headset back after {0:N0} s, but the displays changed again meanwhile - another restart follows." -f $secs)
            } else {
                Say ("Streaming again - {0:N0} s from the display change being detected." -f $secs)
            }
            $awaitingSince = $null
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
    if (-not $KeepVirtualDisplay) { $display += ', and the virtual display will be parked then' }
    Say 'Monitor not attached - left with the guardian, which is waiting for it.'
}

# 3. Did the shutdown reset the GPU? Checked, not assumed - and checked by WHEN
#    THE RESET HAPPENED, not when Windows reported it. Windows Error Reporting
#    re-submits the same old GPU dumps over and over (on this test machine, about
#    100 times each, dumps going back years), often in a burst after a reboot.
#    Counting report times would call any such burst a new reset. Each report
#    names its dump file, and the file name carries the moment of the event:
#    WATCHDOG-20260916-0948.dmp. Only a dump from after the shutdown began counts.
Start-Sleep -Seconds 4
$sinceStamp = $shutdownAt.AddMinutes(-1).ToString('yyyyMMddHHmm')
$reset = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; StartTime = $shutdownAt } -EA SilentlyContinue |
           Where-Object { $_.Message -match 'LiveKernelEvent' -and $_.Message -match 'P1:\s*141' -and $_.Message -match '-(\d{8})-(\d{4})\.dmp' } |
           ForEach-Object { if ($_.Message -match '-(\d{8})-(\d{4})\.dmp') { "$($matches[1])$($matches[2])" } } |
           Where-Object { $_ -ge $sinceStamp } | Sort-Object -Unique)
$gpu = if ($reset.Count) { "GPU RESET at $($reset[-1].Substring(8,2)):$($reset[-1].Substring(10,2))" } else { 'no GPU reset' }

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
