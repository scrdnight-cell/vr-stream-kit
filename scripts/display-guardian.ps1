# The safety net: put the desktop back if a session dies without cleaning up.
#
# WHY. A session that ends properly hands the display back to the monitor and
# parks the virtual display. A session that dies - the window closed with X, the
# stream dropped and R never pressed, a crash - leaves the virtual display
# attached. When Windows then switches an idle monitor off, a DisplayPort monitor
# leaves the desktop completely and the virtual display, which nobody can see, is
# the only screen left. That is the fault this whole kit exists to prevent, and
# recovering from it has needed Safe Mode.
#
# WHAT THIS IS. An ordinary PowerShell process, started hidden by the session from
# the kit's own folder. Nothing is installed: no scheduled task, no service, no
# logon entry, nothing outside this folder, and no dependency on anything else
# running on the machine. It watches the session that started it, acts only if
# that session dies without finishing, and exits as soon as the desktop is safe.
# You can see it in Task Manager as powershell.exe running display-guardian.ps1,
# and ending it is harmless - opening the kit repairs the layout anyway.
#
#   while the session is alive           do nothing; the session owns the display
#   session gone, finished cleanly       exit
#   session gone, did not finish         recover:
#     1. close Bigscreen if it is still running (stream torn down first)
#     2. wait for any physical display to come back
#     3. make it primary - the one that was primary before the session, if it is there
#     4. park the virtual display
#
# Only one runs at a time. A session starting stops any that is still waiting, so
# a leftover can never undo the new session's switch to the virtual display.

param(
    [int]$OwnerPid = 0,
    [int]$MaxHours = 24,
    [string]$VirtualAdapter = 'Virtual Display Driver',
    [string]$LogFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\session.log'),
    [string]$FlagFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\session-active.json'),
    [switch]$KeepVirtualDisplay
)

. (Join-Path $PSScriptRoot 'display.ps1')

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile -Parent) | Out-Null
function Say($m) {
    try { Add-Content -Path $LogFile -Value ("{0}  guardian: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) } catch { }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\VrStreamKitGuardian')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    $deadline = (Get-Date).AddHours($MaxHours)

    # --- 1. wait for the session to finish, one way or the other -------------------
    while ($OwnerPid -gt 0 -and (Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $OwnerPid -EA SilentlyContinue)) { break }
        Start-Sleep -Seconds 3
    }

    # The session deletes the flag once it has handed the display back. No flag
    # means it finished properly - or was never dirty - so there is nothing to do.
    if (-not (Test-Path $FlagFile)) { exit 0 }

    Say 'the session ended without handing the display back - taking over.'

    # --- 2. Bigscreen first: never change displays under a live stream --------------
    if (Get-Process BigscreenRemoteDesktop -EA SilentlyContinue) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'close-bigscreen.ps1') 2>&1
        Say "closing Bigscreen: $((($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '; '))"
    }

    # --- 3. wait for a display to come back, then hand the desktop to it ------------
    Say 'waiting for a physical display.'
    while ((Get-Date) -lt $deadline) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prefer-virtual.ps1') -Restore -VirtualAdapter $VirtualAdapter 2>&1
        if ($LASTEXITCODE -eq 0) {
            Say "display handed back -$(($out | Select-Object -Last 1))"
            if (-not $KeepVirtualDisplay) {
                $r = Disconnect-VirtualDisplay $VirtualAdapter
                Say "virtual display $(if ($r.ok) { $r.why } else { 'NOT parked - ' + $r.why })."
            }
            Remove-Item $FlagFile -Force -EA SilentlyContinue
            Say 'desktop is safe - done.'
            exit 0
        }
        Start-Sleep -Seconds 3
    }
    Say "gave up after $MaxHours h without seeing a physical display."
}
finally {
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
}
