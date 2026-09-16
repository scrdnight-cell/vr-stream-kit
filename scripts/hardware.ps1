# Detect what this system actually has, so profiles are chosen from facts.
#
# Dot-source, then call Get-KitEnvironment. Everything here is readable by a
# standard account. Nothing is changed.

. (Join-Path $PSScriptRoot 'display.ps1')

function Get-GpuList {
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $out = @()
    foreach ($k in Get-ChildItem $class -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }) {
        $p = Get-ItemProperty $k.PSPath -EA SilentlyContinue
        if (-not $p.DriverDesc) { continue }
        $q = $p.'HardwareInformation.qwMemorySize'
        $bytes = if ($q -is [byte[]]) { [BitConverter]::ToUInt64($q, 0) } elseif ($q) { [uint64]$q } else { 0 }
        $name = $p.DriverDesc
        $vendor = switch -Regex ($name) { 'NVIDIA' { 'NVIDIA' } 'AMD|Radeon' { 'AMD' } 'Intel' { 'Intel' } default { 'other' } }
        $integrated = $name -match 'UHD Graphics|Iris|HD Graphics|Radeon\(TM\) Graphics|Radeon Graphics$|Vega \d+ Graphics'
        $out += [pscustomobject]@{
            Name = $name; Vendor = $vendor; VramGB = [math]::Round($bytes / 1GB, 1)
            Integrated = [bool]$integrated; Driver = $p.DriverVersion
            Virtual = $name -match 'Virtual|Basic Render|Basic Display|Parsec|IddSample|Meta|Oculus'
        }
    }
    return $out
}

function Get-KitEnvironment([string]$VirtualAdapter = 'Virtual Display Driver') {
    $gpus = @(Get-GpuList | Where-Object { -not $_.Virtual })
    # Bigscreen encodes on the GPU driving the desktop; with one real GPU that is simple.
    $gpu = $gpus | Sort-Object { -not $_.Integrated }, VramGB -Descending | Select-Object -First 1

    $encoder = switch ($gpu.Vendor) {
        'NVIDIA' { 'NVIDIA NVENC' } 'AMD' { 'AMD AMF/VCE' } 'Intel' { 'Intel Quick Sync' } default { 'CPU (software) - no supported GPU encoder found' }
    }

    $displays = @(Get-AttachedDisplays $VirtualAdapter)
    $sources  = @(Get-CcdSources)
    $vName = ($displays | Where-Object Virtual | Select-Object -First 1).Name
    $pName = ($displays | Where-Object { -not $_.Virtual } | Select-Object -First 1).Name
    $vMode = $sources | Where-Object Name -eq $vName | Select-Object -First 1
    $vPresent = [bool]$vName -or (Test-VirtualAdapterPresent $VirtualAdapter)
    $vParked = $vPresent -and -not $vName
    if ($vParked) {
        # Parked between sessions: report the resolution it will come back with.
        $saved = Get-SavedVirtualMode
        if ($saved) { $vMode = [pscustomobject]@{ Name = $null; W = [int]$saved.W; H = [int]$saved.H; Hz = [int]$saved.Hz; Primary = $false } }
    }
    $pMode = $sources | Where-Object Name -eq $pName | Select-Object -First 1

    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    $nic = if ($route) { Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -EA SilentlyContinue }
    $linkMbps = if ($nic) { [math]::Round($nic.ReceiveLinkSpeed / 1e6) } else { 0 }
    $wifi = [bool]($nic -and ($nic.PhysicalMediaType -match '802\.11' -or $nic.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11'))

    $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1

    $bsRoot = Join-Path $env:LOCALAPPDATA 'BigscreenRemoteDesktop'
    $bsDir = Get-ChildItem $bsRoot -Directory -Filter 'app-*' -EA SilentlyContinue |
             Sort-Object { [version]($_.Name -replace '^app-', '') } -Descending | Select-Object -First 1
    $node = Get-Command node -EA SilentlyContinue
    $nodeVer = if ($node) { (& node -v) -replace '^v', '' } else { $null }

    [pscustomobject]@{
        Gpu = $gpu; AllGpus = $gpus; Encoder = $encoder
        VirtualDisplay = $vMode; PhysicalDisplay = $pMode
        VirtualPresent = $vPresent; VirtualParked = $vParked
        NetworkName = if ($nic) { $nic.InterfaceDescription } else { 'not found' }
        NetworkMbps = $linkMbps; NetworkWifi = $wifi
        Cpu = if ($cpu) { $cpu.Name.Trim() } else { 'unknown' }
        CpuThreads = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 0 }
        BigscreenVersion = if ($bsDir) { $bsDir.Name -replace '^app-', '' } else { $null }
        NodeVersion = $nodeVer
        NodeOk = [bool]($nodeVer -and [version]$nodeVer -ge [version]'22.0.0')
    }
}

function Show-KitEnvironment($envInfo) {
    $e = $envInfo
    ''
    '  YOUR SYSTEM'
    '  -----------'
    if ($e.Gpu) { "  GPU            {0}  ({1} GB video memory{2})" -f $e.Gpu.Name, $e.Gpu.VramGB, $(if ($e.Gpu.Integrated) { ', integrated' }) } else { '  GPU            not found' }
    if ($e.AllGpus.Count -gt 1) { "                 also: {0}" -f (($e.AllGpus | Where-Object { $_.Name -ne $e.Gpu.Name } | ForEach-Object Name) -join ', ') }
    "  Encoder        $($e.Encoder)"
    if (-not $e.VirtualPresent) { '  Virtual        NOT INSTALLED - install or enable your virtual display driver' }
    elseif ($e.VirtualParked -and $e.VirtualDisplay) { "  Virtual        {0} x {1} at {2} Hz  (parked - connected when a session starts)" -f $e.VirtualDisplay.W, $e.VirtualDisplay.H, $e.VirtualDisplay.Hz }
    elseif ($e.VirtualParked) { '  Virtual        parked - connected when a session starts' }
    else { "  Virtual        {0} x {1} at {2} Hz{3}" -f $e.VirtualDisplay.W, $e.VirtualDisplay.H, $e.VirtualDisplay.Hz, $(if ($e.VirtualDisplay.Primary) { '  (primary)' }) }
    if ($e.PhysicalDisplay) { "  Monitor        {0} x {1} at {2} Hz{3}" -f $e.PhysicalDisplay.W, $e.PhysicalDisplay.H, $e.PhysicalDisplay.Hz, $(if ($e.PhysicalDisplay.Primary) { '  (primary)' }) } else { '  Monitor        not attached' }
    "  Network        {0}, {1} Mbit/s{2}" -f $e.NetworkName, $e.NetworkMbps, $(if ($e.NetworkWifi) { ', Wi-Fi' } else { ', wired' })
    "  CPU            {0} ({1} threads)" -f $e.Cpu, $e.CpuThreads
    "  Bigscreen      $(if ($e.BigscreenVersion) { $e.BigscreenVersion } else { 'NOT FOUND' })"
    "  Node.js        $(if ($e.NodeVersion) { $e.NodeVersion + $(if (-not $e.NodeOk) { '  (22 or newer needed)' }) } else { 'NOT FOUND - install version 22 or newer' })"
}
