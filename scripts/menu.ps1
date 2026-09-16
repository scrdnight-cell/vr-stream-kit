# The setup menu: pick a saved profile, create one, check the system, measure
# headroom - then run the session.

param([string]$VirtualAdapter = 'Virtual Display Driver', [string]$BigscreenDir = '',
      [ValidateSet('monitor', 'virtual')] [string]$OnMonitorReturn = 'monitor',
      [switch]$KeepVirtualDisplay)

if (-not $VirtualAdapter) { $VirtualAdapter = 'Virtual Display Driver' }   # an empty name would match every display
$here = $PSScriptRoot
. (Join-Path $here 'hardware.ps1')
. (Join-Path $here 'profiles.ps1')
. (Join-Path $here 'headroom.ps1')

# Console input that also works when input is piped in (used for testing).
function Ask([string]$prompt) { Write-Host -NoNewline $prompt; $r = [Console]::ReadLine(); if ($null -eq $r) { return 'q' }; return $r.Trim() }
function Wait-MenuReturn { $null = Ask "`n  Press Enter to return to the menu. " }

function Read-Number([string]$prompt, [double]$default, [double]$min, [double]$max) {
    while ($true) {
        $a = Ask ("  {0} [{1}]: " -f $prompt, $default)
        if ($a -eq '') { return $default }
        $v = 0.0
        if ([double]::TryParse($a, [ref]$v) -and $v -ge $min -and $v -le $max) { return $v }
        "  Enter a number from $min to $max, or press Enter for $default."
    }
}

function New-CustomProfile($envInfo) {
    ''
    '  CREATE A PROFILE'
    '  ----------------'
    $name = ''
    $existing = @(Get-AllProfiles | ForEach-Object Name)
    while (-not $name) {
        $name = Ask '  Name: '
        if ($name -eq '') { return }
        if ($existing -contains $name) { "  A profile called '$name' already exists."; $name = '' }
    }
    ''
    '  What is it for?'
    '    1  Desktop and apps'
    '    2  Films and TV'
    '    3  Games'
    $act = switch (Ask '  Choose 1-3: ') { '1' { 'desktop' } '2' { 'film' } '3' { 'games' } default { $null } }
    if (-not $act) { '  Cancelled.'; return }

    $contentFps = 24
    if ($act -eq 'film') {
        ''
        '  What frame rate is the content?  24 = films and most series, 25 = UK/European TV, 30 = US TV and online video'
        $contentFps = [int](Read-Number 'Content frame rate' 24 23 60)
    }

    ''
    '  RECOMMENDATIONS FOR YOUR SYSTEM'
    Get-KitAdvice $act $envInfo | ForEach-Object { if ($_ -match '^\s') { "  $_" } else { "  - $_" } }
    $s = Get-SuggestedValues $act $envInfo $contentFps
    ''
    '  Press Enter to accept each suggestion.'
    while ($true) {
        $p = [pscustomobject]@{
            Name = $name; Activity = $act; BuiltIn = $false; Note = ''
            Height = [int](Read-Number 'Stream height in lines (1080, 1440, 2160, 4320)' $s.Height 16 4320)
            Fps    = [int](Read-Number 'Frames per second' $s.Fps 1 300)
            Mbps   = [double](Read-Number 'Bitrate in Mbps' $s.Mbps 0.5 100)
        }
        ''
        '  CHECK'
        $f = Test-KitProfile $p $envInfo
        Show-Findings $f
        if ($f | Where-Object Level -eq 'stop') { ''; '  That profile is not possible - enter the values again.'; ''; $s = [pscustomobject]@{ Height = $p.Height; Fps = $p.Fps; Mbps = $p.Mbps }; continue }
        $ok = Ask "`n  Save '$name' ($(Format-Profile $p))? [Y/n]: "
        if ($ok -match '^[nN]') { '  Not saved.'; return }
        $store = Read-KitStore
        $store.Profiles = @($store.Profiles | Where-Object { $_ }) + @([pscustomobject]@{ Name = $p.Name; Activity = $p.Activity; Height = $p.Height; Fps = $p.Fps; Mbps = $p.Mbps; Note = '' })
        Save-KitStore $store
        "  Saved to config\profiles.json."
        return
    }
}

function Remove-CustomProfile {
    $custom = @(Get-AllProfiles | Where-Object { -not $_.BuiltIn })
    if (-not $custom) { ''; '  There are no custom profiles to delete.'; return }
    ''
    for ($i = 0; $i -lt $custom.Count; $i++) { "    {0}  {1}  ({2})" -f ($i + 1), $custom[$i].Name, (Format-Profile $custom[$i]) }
    $a = Ask '  Delete which? (Enter to cancel): '
    $n = 0
    if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $custom.Count) { '  Cancelled.'; return }
    $gone = $custom[$n - 1].Name
    $store = Read-KitStore
    $store.Profiles = @($store.Profiles | Where-Object { $_ -and $_.Name -ne $gone })
    if ($store.Last -eq $gone) { $store.Last = '' }
    Save-KitStore $store
    "  Deleted '$gone'."
}

# --- first run: the terms ------------------------------------------------------------------
# Asked once, before the kit changes anything on the system. Bump TERMS_VERSION when
# TERMS.md changes in substance, so everyone is asked again.
$TERMS_VERSION = 2
$termsFile = Join-Path (Split-Path $here -Parent) 'config\terms-accepted.json'
$accepted = $null
try { $accepted = Get-Content $termsFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
if (-not $accepted -or $accepted.Version -lt $TERMS_VERSION) {
    try { Clear-Host } catch { }
    ''
    '  VR STREAM KIT - BEFORE YOU START'
    '  ================================'
    ''
    '  - This kit is unofficial. It is not made, endorsed or supported by Bigscreen, Inc.,'
    '    Meta, or the makers of your virtual display driver.'
    '  - It changes your display layout, starts Bigscreen Remote Desktop with a local'
    '    debugger (127.0.0.1 only) to set stream quality, and closes programs it started.'
    '  - Using it is at your own risk and it comes with no warranty. What you stream, and'
    '    who you share it with, is your responsibility - including following the terms of'
    '    Bigscreen and of any service or content you stream.'
    '  - It collects nothing and sends nothing anywhere. Logs stay in this folder.'
    ''
    '  By scrdnight-cell - https://github.com/scrdnight-cell'
    '  Full terms: TERMS.md    Licence: LICENSE    No warranty, no support contract.'
    ''
    $a = Ask '  Type Y to accept and continue, anything else to quit: '
    if ($a -notmatch '^[yY]') { ''; '  Not accepted - nothing was changed.'; exit 0 }
    $null = New-Item -ItemType Directory -Force (Split-Path $termsFile -Parent)
    [pscustomobject]@{ Version = $TERMS_VERSION; Accepted = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $termsFile -Encoding utf8
}

# --- on opening: park the virtual display -------------------------------------------------
# Nothing needs the virtual display until a session starts. Installing a virtual
# display driver can leave it attached - even primary - which is exactly the state
# an idle monitor switching off turns into a stranded desktop. Parking it here
# means simply opening the kit once makes a fresh install safe, and closing the
# window with X afterwards leaves nothing attached.
$openingNote = $null
$flagFile = Join-Path (Split-Path $here -Parent) 'config\session-active.json'
$staleSession = Test-Path $flagFile          # a session that never handed the display back
if (-not $KeepVirtualDisplay) {
    $r = Disconnect-VirtualDisplay $VirtualAdapter
    if ($r.changed) { $openingNote = 'The virtual display was attached - it is now parked and your monitor is primary. It is connected again when a session starts.' }
    elseif (-not $r.ok) { $openingNote = "The virtual display is attached and could not be parked: $($r.why)." }
}
if ($staleSession) {
    # Nothing more to do - parking above is the repair. Say so, because a session
    # that ended this way is worth knowing about (window closed with X, a crash,
    # or the stream dropped and R was never pressed).
    Remove-Item $flagFile -Force -EA SilentlyContinue
    $openingNote = "A previous session did not finish cleanly. $(if ($openingNote) { $openingNote } else { 'The display layout is in order.' })"
}

# --- main loop ---------------------------------------------------------------------------
$envInfo = Get-KitEnvironment $VirtualAdapter
while ($true) {
    $all = @(Get-AllProfiles $envInfo)
    $store = Read-KitStore
    $lastIdx = [array]::IndexOf(@($all | ForEach-Object Name), $store.Last)

    try { Clear-Host } catch { }
    ''
    '  VR STREAM KIT'
    '  ============='
    if (-not $envInfo.VirtualPresent) { '  [!] No virtual display driver found - install or enable it, then press S to re-check.' }
    if (-not $envInfo.BigscreenVersion) { '  [!] Bigscreen Remote Desktop not found.' }
    if (-not $envInfo.NodeOk) { '  [!] Node.js 22 or newer is required.' }
    if ($openingNote) { "  [i] $openingNote" }
    ''
    '  PROFILES'
    for ($i = 0; $i -lt $all.Count; $i++) {
        $p = $all[$i]
        "  {0,3}  {1,-18} {2,-24} {3}" -f ($i + 1), $p.Name, (Format-Profile $p), $(if ($p.BuiltIn) { $p.Note } else { '(custom)' })
    }
    ''
    '    C  Create a profile         D  Delete a custom profile'
    '    S  System report            H  Headroom check'
    '    Q  Quit'
    ''
    '  VR Stream Kit by scrdnight-cell - unofficial, MIT licence. README.md has the details.'
    ''
    $prompt = if ($lastIdx -ge 0) { "  Choose (Enter = $($all[$lastIdx].Name)): " } else { '  Choose: ' }
    $a = Ask $prompt
    if ($a -eq '' -and $lastIdx -ge 0) { $a = "$($lastIdx + 1)" }

    switch -Regex ($a) {
        '^[qQ]$' {
            # Leaving the kit parks the virtual display, so nothing is left that an
            # idle monitor switching off could strand the desktop on.
            if (-not $KeepVirtualDisplay) {
                $r = Disconnect-VirtualDisplay $VirtualAdapter
                if ($r.changed) { '  Virtual display parked.' } elseif (-not $r.ok) { "  Virtual display left attached: $($r.why)." }
            }
            exit 0
        }
        '^[cC]$' { New-CustomProfile $envInfo; Wait-MenuReturn; continue }
        '^[dD]$' { Remove-CustomProfile; Wait-MenuReturn; continue }
        '^[sS]$' { $envInfo = Get-KitEnvironment $VirtualAdapter; Show-KitEnvironment $envInfo; Wait-MenuReturn; continue }
        '^[hH]$' {
            ''
            '  Start the game or film you want to check first - including Bigscreen, if it is running.'
            $null = Ask '  Press Enter to measure for 20 seconds. '
            Measure-KitHeadroom 20 $envInfo
            Wait-MenuReturn; continue
        }
        '^\d+$' {
            $n = [int]$a
            if ($n -lt 1 -or $n -gt $all.Count) { continue }
            $p = $all[$n - 1]
            ''
            "  $($p.Name): $(Format-Profile $p)"
            $f = Test-KitProfile $p $envInfo
            Show-Findings $f
            if ($f | Where-Object Level -eq 'stop') { Wait-MenuReturn; continue }
            if ($f | Where-Object Level -eq 'warn') {
                $go = Ask "`n  Start anyway? [Y/n]: "
                if ($go -match '^[nN]') { continue }
            }
            if (-not $envInfo.VirtualPresent -or -not $envInfo.BigscreenVersion -or -not $envInfo.NodeOk) {
                ''; '  Cannot start until the problems at the top of the menu are fixed.'; Wait-MenuReturn
                $envInfo = Get-KitEnvironment $VirtualAdapter; continue
            }
            $store.Last = $p.Name
            Save-KitStore $store
            ''
            if ($p.Activity -eq 'games') { '  Reminder: render the game at the stream resolution and cap its frame rate - see H for a headroom check.'; '' }
            # Windows PowerShell 5.1 drops empty-string arguments when starting another
            # process, so "-BigscreenDir ''" arrives as a switch with no value and the
            # session refuses to start. Only pass optional values that are set.
            $sessionArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'run-session.ps1'),
                             '-Height', $p.Height, '-Mbps', $p.Mbps, '-Fps', $p.Fps, '-VirtualAdapter', $VirtualAdapter)
            if ($BigscreenDir) { $sessionArgs += @('-BigscreenDir', $BigscreenDir) }
            if ($OnMonitorReturn) { $sessionArgs += @('-OnMonitorReturn', $OnMonitorReturn) }
            if ($KeepVirtualDisplay) { $sessionArgs += '-KeepVirtualDisplay' }
            & powershell @sessionArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) { ''; '  Closing in 5 seconds.'; Start-Sleep -Seconds 5 }
            exit $code
        }
    }
}
