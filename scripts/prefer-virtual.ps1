# Make the virtual display primary (or, with -Restore, the physical monitor).
#
#   prefer-virtual.ps1             virtual display primary; the monitor stays on
#   prefer-virtual.ps1 -Restore    physical monitor primary again
#
# WHY. Bigscreen Remote Desktop captures whichever display is primary when it
# starts. If that is your physical monitor, switching the monitor off destroys
# Bigscreen's capture source and the stream dies. Making the virtual display
# primary before Bigscreen launches binds the stream to a display that never
# goes away.
#
# The result is read back rather than trusted, and retried: a switch made while
# another program is changing the desktop can be undone a moment later.

param(
    [switch]$Restore,
    [string]$VirtualAdapter = 'Virtual Display Driver'
)

. (Join-Path $PSScriptRoot 'display.ps1')

$displays = Get-AttachedDisplays $VirtualAdapter
$virtual  = ($displays | Where-Object Virtual | Select-Object -First 1).Name
# Prefer the display that was primary when the session began - which is not
# necessarily the first one Windows lists, and on a multi-monitor desk is the one
# the user actually works on. Any physical display will do if that one is gone.
$physical = Resolve-SavedPhysicalName
if (-not $physical -or -not ($displays | Where-Object Name -eq $physical)) {
    $physical = ($displays | Where-Object { -not $_.Virtual } | Select-Object -First 1).Name
}

if (-not $physical) {
    # With no monitor attached, the virtual display is the whole desktop - and so
    # already primary. That is the goal when streaming with the monitor off, not a
    # failure; only handing the display BACK needs a monitor to hand it to.
    if (-not $Restore -and $virtual) { "  primary -> $virtual  (the only display attached)"; exit 0 }
    '  The physical monitor is not attached. Switch it on first.'; exit 1
}
if (-not $virtual) {
    # Handing the display back needs only the monitor: with no virtual display
    # attached - parked, or gone - the monitor is already the desktop.
    if ($Restore) { "  primary -> $physical  (no virtual display attached)"; exit 0 }
    "  No virtual display attached (adapter name matching '$VirtualAdapter'). Enable it in your virtual display driver's control app."; exit 1
}

$target = if ($Restore) { $physical } else { $virtual }
for ($try = 1; $try -le 3; $try++) {
    # A monitor switched off mid-switch is gone, not stubborn: retrying it only
    # costs time. Exit 2 tells the caller to re-decide from what is attached now.
    if (-not (Get-AttachedDisplays $VirtualAdapter | Where-Object Name -eq $target)) {
        "  $target is no longer attached."; exit 2
    }
    $r = Set-PrimaryByCcd $target
    if (-not $r.ok) { "  attempt $try refused: $($r.why)" }
    # Read back until it holds, rather than always waiting the full 2 s. It must
    # still be primary on a second look: a switch can be undone a moment later.
    $now = $null
    for ($t = 0; $t -lt 8; $t++) {
        Start-Sleep -Milliseconds 250
        $now = (Get-CcdSources | Where-Object Primary | Select-Object -First 1).Name
        if ($now -eq $target) {
            Start-Sleep -Milliseconds 500
            $now = (Get-CcdSources | Where-Object Primary | Select-Object -First 1).Name
            break
        }
    }
    if ($now -eq $target) { "  primary -> $target  (confirmed)"; exit 0 }
    "  attempt $try did not hold - primary is still $now"
}
"  FAILED: $target would not stay primary. Is another display tool running?"
exit 1
