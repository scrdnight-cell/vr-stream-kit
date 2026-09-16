# Stream profiles: the built-in list, the user's saved profiles, checks, advice.
#
# Custom profiles and the last one used are saved in config\profiles.json next
# to the kit, so nothing has to be re-entered. Built-in profiles are defined
# here and never written to the file.

$script:KitRoot = Split-Path $PSScriptRoot -Parent
$script:ProfileFile = Join-Path $KitRoot 'config\profiles.json'

function Get-BuiltInProfiles {
    @(
        [pscustomobject]@{ Name = 'Desktop';        Activity = 'desktop'; Height = 1440; Fps = 30; Mbps = 40; BuiltIn = $true; Note = 'Everyday desktop use.' }
        [pscustomobject]@{ Name = 'Desktop 4K';     Activity = 'desktop'; Height = 2160; Fps = 30; Mbps = 80; BuiltIn = $true; Note = 'Sharpest text. Needs GPU headroom.'; MinVirtualHeight = 2160 }
        [pscustomobject]@{ Name = 'Film (24 fps)';  Activity = 'film';    Height = 1440; Fps = 48; Mbps = 50; BuiltIn = $true; Note = 'Most films and series.' }
        [pscustomobject]@{ Name = 'TV (25 fps)';    Activity = 'film';    Height = 1440; Fps = 50; Mbps = 50; BuiltIn = $true; Note = 'UK/European broadcast content.' }
        [pscustomobject]@{ Name = 'Games';          Activity = 'games';   Height = 1440; Fps = 30; Mbps = 60; BuiltIn = $true; Note = 'Render the game at the stream resolution, cap it at 30 fps.' }
        [pscustomobject]@{ Name = 'Games (smooth)'; Activity = 'games';   Height = 1080; Fps = 60; Mbps = 60; BuiltIn = $true; Note = 'Needs GPU headroom. Cap the game at 60 fps.' }
        [pscustomobject]@{ Name = 'Stock';          Activity = 'stock';   Height = 0;    Fps = 0;  Mbps = 0;  BuiltIn = $true; Note = 'No tuning - the headset menu decides.' }
    )
}

function Read-KitStore {
    if (Test-Path $ProfileFile) {
        try { return Get-Content $ProfileFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ Last = ''; Profiles = @() }
}

function Save-KitStore($store) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ProfileFile -Parent) | Out-Null
    [pscustomobject]@{ Last = $store.Last; Profiles = @($store.Profiles) } | ConvertTo-Json -Depth 4 | Set-Content $ProfileFile -Encoding utf8
}

function Get-AllProfiles($envInfo = $null) {
    # Built-in profiles never stream taller than the virtual display: extra lines are
    # scaled up from a smaller desktop and add no detail. Custom profiles are kept as
    # entered, and the check warns if they exceed it.
    $vh = if ($envInfo -and $envInfo.VirtualDisplay) { [int]$envInfo.VirtualDisplay.H } else { 0 }
    $builtIn = @(Get-BuiltInProfiles | Where-Object {
        # A profile that exists only for a taller desktop (e.g. 4K) is hidden rather
        # than shown as a copy of another profile.
        -not ($vh -and $_.PSObject.Properties['MinVirtualHeight'] -and $vh -lt $_.MinVirtualHeight)
    } | ForEach-Object {
        if ($vh -and $_.Height -gt $vh) {
            $_.Height = $vh
            $_.Note = "$($_.Note) Fitted to your ${vh}p virtual display."
        }
        $_
    })
    $store = Read-KitStore
    $custom = @($store.Profiles | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Activity = $_.Activity; Height = [int]$_.Height; Fps = [int]$_.Fps; Mbps = [double]$_.Mbps; BuiltIn = $false; Note = $_.Note }
    })
    return $builtIn + $custom
}

function Format-Profile($p) {
    if ($p.Height -eq 0) { return 'no tuning' }
    '{0}p  {1} fps  {2} Mbps' -f $p.Height, $p.Fps, $p.Mbps
}

# --- checks ------------------------------------------------------------------------
# Three levels, and the rule for each:
#   stop  impossible - outside what Bigscreen accepts, or beyond the H.264 standard
#   warn  THIS system's detected hardware says it will not work as intended
#   info  worth knowing, nothing detectable to fix (e.g. what the headset must decode)
# Anything the hardware can justify is allowed: a custom 8K, 120 fps profile is fine
# on a system whose virtual display, network and GPU support it.

# H.264 levels: maximum frame size in macroblocks, maximum macroblocks per second.
$script:H264Levels = @(
    [pscustomobject]@{ Level = '5.1'; MaxFs = 36864;  MaxMbps = 983040 }
    [pscustomobject]@{ Level = '5.2'; MaxFs = 36864;  MaxMbps = 2073600 }
    [pscustomobject]@{ Level = '6.0'; MaxFs = 139264; MaxMbps = 4177920 }
    [pscustomobject]@{ Level = '6.1'; MaxFs = 139264; MaxMbps = 8355840 }
    [pscustomobject]@{ Level = '6.2'; MaxFs = 139264; MaxMbps = 16711680 }
)
# Hardware H.264 encoders on current GPUs generally stop at 4096 pixels per side.
$script:HwH264MaxSide = 4096

function New-Finding([string]$level, [string]$text) { [pscustomobject]@{ Level = $level; Text = $text } }

function Test-KitProfile($p, $envInfo) {
    $findings = @()
    if ($p.Height -eq 0) { return @(New-Finding 'ok' "Bigscreen's own settings; nothing to check.") }

    $vw = if ($envInfo.VirtualDisplay) { $envInfo.VirtualDisplay.W } else { 3840 }
    $vh = if ($envInfo.VirtualDisplay) { $envInfo.VirtualDisplay.H } else { 2160 }
    $vhz = if ($envInfo.VirtualDisplay -and $envInfo.VirtualDisplay.Hz) { $envInfo.VirtualDisplay.Hz } else { 0 }
    $w = [math]::Round($p.Height * $vw / $vh)
    $mbFrame = [math]::Ceiling($w / 16) * [math]::Ceiling($p.Height / 16)
    $mbRate = $mbFrame * $p.Fps

    # --- stop: impossible --------------------------------------------------------
    if ($p.Height -lt 16 -or $p.Height -gt 4320) { $findings += New-Finding 'stop' 'Height must be between 16 and 4320 lines - the range Bigscreen accepts.' }
    if ($p.Fps -lt 1 -or $p.Fps -gt 300) { $findings += New-Finding 'stop' 'Frame rate must be between 1 and 300 - the range Bigscreen accepts.' }
    if ($p.Mbps -lt 0.5 -or $p.Mbps -gt 100) { $findings += New-Finding 'stop' 'Bitrate must be between 0.5 and 100 Mbps - the range Bigscreen accepts.' }
    $level = $H264Levels | Where-Object { $mbFrame -le $_.MaxFs -and $mbRate -le $_.MaxMbps } | Select-Object -First 1
    if (-not $level) {
        $findings += New-Finding 'stop' "${w}x$($p.Height) at $($p.Fps) fps is beyond the H.264 standard (level 6.2 is the highest). Lower the frame rate or height."
    }

    # --- warn: this system's hardware says otherwise ------------------------------------
    if ($p.Height -gt $vh) { $findings += New-Finding 'warn' "Taller than your virtual display ($vh lines): the extra lines are scaled up and add no detail. Raise the virtual display's resolution to match." }
    if ($vhz -and $p.Fps -gt $vhz) { $findings += New-Finding 'warn' "Faster than your virtual display's refresh rate ($vhz Hz): the extra frames are repeats. Raise its refresh rate to match." }
    if ($w -gt $HwH264MaxSide -or $p.Height -gt $HwH264MaxSide) {
        $findings += New-Finding 'warn' "A ${w}x$($p.Height) frame is wider than hardware H.264 encoders on current GPUs generally support ($HwH264MaxSide pixels per side). Your $($envInfo.Encoder) encoder may refuse it, or Bigscreen may fall back to slow software encoding."
    }
    if ($envInfo.NetworkMbps -and $p.Mbps -gt ($envInfo.NetworkMbps * 0.5)) {
        $findings += New-Finding 'warn' "More than half your PC's network link ($($envInfo.NetworkMbps) Mbit/s). Expect stutter."
    }
    if ($envInfo.NetworkWifi -and $p.Mbps -gt 40) {
        $findings += New-Finding 'warn' 'Your PC is on Wi-Fi, so the stream crosses wireless twice. Prefer a wired PC, or keep bitrate at 40 Mbps or below.'
    }
    $pixelRate = $w * $p.Height * $p.Fps
    $ref4k30 = 3840 * 2160 * 30
    $gpu = $envInfo.Gpu
    $limitedGpu = $gpu -and ($gpu.Integrated -or $gpu.VramGB -lt 6)
    $strongGpu = $gpu -and -not $gpu.Integrated -and $gpu.VramGB -ge 12
    if ($limitedGpu -and $p.Height -gt 1080) {
        $findings += New-Finding 'warn' "Your GPU ($($gpu.Name)) has limited headroom for streams above 1080p, especially alongside games."
    } elseif (-not $strongGpu -and $pixelRate -gt $ref4k30) {
        $findings += New-Finding 'warn' "This stream is more encoding work than 4K at 30 fps, and your GPU ($($gpu.Name), $($gpu.VramGB) GB) is not in the class that usually handles it. Run the headroom check."
    }

    # --- info: nothing detectable to fix --------------------------------------------------------
    if ($level -and $level.Level -ne '5.1') {
        $findings += New-Finding 'info' "Needs H.264 level $($level.Level). The PC cannot see what your headset's decoder supports - if the picture freezes when the profile applies, the headset is the limit."
    }
    if ($p.Activity -eq 'games' -and $strongGpu -and $pixelRate -gt $ref4k30) {
        $findings += New-Finding 'info' 'Heavy stream alongside a game: your GPU is in the class that can carry it - confirm with the headroom check while the game runs.'
    }
    if ($p.Activity -eq 'film' -and ($p.Fps % 24 -ne 0) -and ($p.Fps % 25 -ne 0) -and ($p.Fps % 30 -ne 0)) {
        $findings += New-Finding 'info' 'For the smoothest motion use a multiple of the content frame rate: 48 for 24 fps films, 50 for 25 fps TV, 60 for 30 fps video.'
    }

    if (-not ($findings | Where-Object { $_.Level -in 'stop', 'warn' })) { $findings = @(New-Finding 'ok' 'Your system supports this profile.') + @($findings) }
    return $findings
}

function Show-Findings($findings) {
    foreach ($f in $findings) {
        $tag = switch ($f.Level) { 'stop' { '  [X] ' } 'warn' { '  [!] ' } 'info' { '  [i] ' } default { '  [ok]' } }
        "$tag $($f.Text)"
    }
}
# --- advice ------------------------------------------------------------------------------
function Get-KitAdvice([string]$activity, $envInfo) {
    $gpu = $envInfo.Gpu
    $limited = $gpu -and ($gpu.Integrated -or $gpu.VramGB -lt 6)
    $strong = $gpu -and -not $gpu.Integrated -and $gpu.VramGB -ge 12
    $lines = @()

    switch ($activity) {
        'desktop' {
            $lines += 'Desktop work is mostly still, so it is cheap to encode and text benefits from resolution.'
            $lines += if ($limited) { 'Suggested: 1080p, 30 fps, 30 Mbps.' } elseif ($strong) { 'Suggested: 1440p, 30 fps, 40 Mbps - or 2160p, 30 fps, 80 Mbps for the sharpest text.' } else { 'Suggested: 1440p, 30 fps, 40 Mbps.' }
        }
        'film' {
            $lines += 'Match the stream to the content: 48 fps for 24 fps films, 50 for 25 fps TV, 60 for 30 fps video. Every frame is then shown evenly.'
            $lines += 'Streaming services usually send desktop browsers 720p or 1080p, so a 4K stream spends encoder work on detail that is not there.'
            $lines += 'Film motion is the hardest content to compress, so give it bitrate rather than resolution.'
            $lines += if ($limited) { 'Suggested: 1080p, 48 fps, 40 Mbps.' } else { 'Suggested: 1440p, 48 fps, 50 Mbps.' }
        }
        'games' {
            $lines += 'The game and the stream encoder share one GPU. If the GPU runs at 100%, the encoder is starved and the stream can freeze or drop - often during loading.'
            $lines += 'Keep the game below about 85% GPU load (use the headroom check):'
            $lines += '  - render the game at the stream resolution, not higher'
            $lines += '  - cap the game frame rate at the stream frame rate'
            $lines += '  - turn on the upscaler if offered (DLSS, FSR or XeSS)'
            $lines += if ($limited) { 'Suggested: 1080p, 30 fps, 50 Mbps.' } elseif ($strong) { 'Suggested: 1440p, 30 fps, 60 Mbps. With plenty of headroom, 1080p at 60 fps plays smoother.' } else { 'Suggested: 1440p, 30 fps, 60 Mbps.' }
            $lines += 'Systems with ample headroom may never see starvation - measure before lowering anything.'
        }
    }
    $lines += 'A Quest 3 shows roughly 2K per eye, so streams above 1440p mostly benefit desktop text.'
    if ($envInfo.NetworkWifi) { $lines += 'Your PC is on Wi-Fi. A wired PC with the headset on 5 or 6 GHz Wi-Fi is the most reliable setup.' }
    return $lines
}

function Get-SuggestedValues([string]$activity, $envInfo, [int]$contentFps = 24) {
    $gpu = $envInfo.Gpu
    $limited = $gpu -and ($gpu.Integrated -or $gpu.VramGB -lt 6)
    $h = if ($limited) { 1080 } else { 1440 }
    switch ($activity) {
        'desktop' { $f = 30; $m = if ($h -eq 1080) { 30 } else { 40 } }
        'film'    { $f = [math]::Min(2 * $contentFps, 60); $m = if ($h -eq 1080) { 40 } else { 50 } }
        default   { $f = 30; $m = if ($h -eq 1080) { 50 } else { 60 } }
    }
    if ($envInfo.VirtualDisplay -and $h -gt $envInfo.VirtualDisplay.H) { $h = [int]$envInfo.VirtualDisplay.H }
    if ($envInfo.NetworkWifi) { $m = [math]::Min($m, 40) }
    if ($envInfo.NetworkMbps) { $m = [math]::Min($m, [math]::Floor($envInfo.NetworkMbps * 0.5)) }
    [pscustomobject]@{ Height = $h; Fps = $f; Mbps = $m }
}
