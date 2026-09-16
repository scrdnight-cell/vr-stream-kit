# Display helpers: find the virtual and physical displays, and move the primary.
#
# Dot-source this file. It defines:
#   Get-AttachedDisplays     one row per attached display: Name, Adapter, Virtual
#   Get-CcdSources           one row per active desktop source: Name, X, Y, W, H, Primary
#   Set-PrimaryByCcd $name   make that display primary
#
# WHY THE MODERN (CCD) API. The older ChangeDisplaySettingsEx + CDS_SET_PRIMARY
# call refuses to persist a new layout for a standard (non-administrator)
# account on some systems - it returns DISP_CHANGE_FAILED while the identical
# mode passes CDS_TEST. SetDisplayConfig is what the Windows Settings app uses,
# and it works without administrator rights.

Add-Type -Namespace VrKit -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
}
[DllImport("user32.dll", CharSet = CharSet.Ansi)]
public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

[StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
[StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Numerator; public uint Denominator; }
[StructLayout(LayoutKind.Sequential)] public struct REGION2D { public uint cx; public uint cy; }
[StructLayout(LayoutKind.Sequential)] public struct POINTL { public int x; public int y; }

[StructLayout(LayoutKind.Sequential)]
public struct PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

[StructLayout(LayoutKind.Sequential)]
public struct PATH_TARGET_INFO {
    public LUID adapterId; public uint id; public uint modeInfoIdx;
    public uint outputTechnology; public uint rotation; public uint scaling;
    public RATIONAL refreshRate; public uint scanLineOrdering;
    [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
    public uint statusFlags;
}

[StructLayout(LayoutKind.Sequential)]
public struct PATH_INFO { public PATH_SOURCE_INFO sourceInfo; public PATH_TARGET_INFO targetInfo; public uint flags; }

[StructLayout(LayoutKind.Sequential)]
public struct VIDEO_SIGNAL_INFO {
    public ulong pixelRate; public RATIONAL hSyncFreq; public RATIONAL vSyncFreq;
    public REGION2D activeSize; public REGION2D totalSize;
    public uint videoStandard; public uint scanLineOrdering;
}
[StructLayout(LayoutKind.Sequential)] public struct TARGET_MODE { public VIDEO_SIGNAL_INFO targetVideoSignalInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct SOURCE_MODE { public uint width; public uint height; public uint pixelFormat; public POINTL position; }

// infoType/id/adapterId followed by a union: target and source mode share 48 bytes.
[StructLayout(LayoutKind.Explicit, Size = 64)]
public struct MODE_INFO {
    [FieldOffset(0)]  public uint infoType;
    [FieldOffset(4)]  public uint id;
    [FieldOffset(8)]  public LUID adapterId;
    [FieldOffset(16)] public TARGET_MODE targetMode;
    [FieldOffset(16)] public SOURCE_MODE sourceMode;
}

[StructLayout(LayoutKind.Sequential)]
public struct DEVICE_INFO_HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct SOURCE_DEVICE_NAME {
    public DEVICE_INFO_HEADER header;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
}

[DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
[DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr topologyId);
[DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPath, [In] PATH_INFO[] paths, uint numMode, [In] MODE_INFO[] modes, uint flags);
[DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref SOURCE_DEVICE_NAME deviceName);
'@

$script:QDC_ONLY_ACTIVE_PATHS = 0x00000002
$script:SDC_USE_SUPPLIED      = 0x00000020
$script:SDC_APPLY             = 0x00000080
$script:SDC_SAVE_TO_DATABASE  = 0x00000200
$script:SDC_ALLOW_CHANGES     = 0x00000400
$script:MODE_INFO_TYPE_SOURCE = 1
$script:GET_SOURCE_NAME       = 1

function Test-VirtualAdapterPresent([string]$VirtualAdapter = 'Virtual Display Driver') {
    # True if the virtual display adapter is installed and working, attached to the
    # desktop or not. Asked of Device Manager, because a detached virtual display
    # is no longer listed by the display API under its adapter name.
    return [bool](Get-PnpDevice -Class Display -EA SilentlyContinue |
                  Where-Object { $_.FriendlyName -match $VirtualAdapter -and $_.Status -eq 'OK' })
}

function Get-AttachedDisplays([string]$VirtualAdapter = 'Virtual Display Driver') {
    $out = @()
    for ($i = 0; $i -lt 16; $i++) {
        $d = New-Object VrKit.Native+DISPLAY_DEVICE
        $d.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($d)
        if (-not [VrKit.Native]::EnumDisplayDevices([NullString]::Value, $i, [ref]$d, 0)) { break }
        if (-not ($d.StateFlags -band 1)) { continue }          # not attached to the desktop
        $out += [pscustomobject]@{ Name = $d.DeviceName; Adapter = $d.DeviceString; Virtual = ($d.DeviceString -match $VirtualAdapter) }
    }
    return $out
}

function Get-CcdConfig {
    $np = 0; $nm = 0
    if ([VrKit.Native]::GetDisplayConfigBufferSizes($QDC_ONLY_ACTIVE_PATHS, [ref]$np, [ref]$nm) -ne 0) { return $null }
    $paths = New-Object 'VrKit.Native+PATH_INFO[]' $np
    $modes = New-Object 'VrKit.Native+MODE_INFO[]' $nm
    if ([VrKit.Native]::QueryDisplayConfig($QDC_ONLY_ACTIVE_PATHS, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) { return $null }
    return [pscustomobject]@{ Paths = $paths; Modes = $modes; NPath = $np; NMode = $nm }
}

function Get-SourceGdiName($adapterId, [uint32]$sourceId) {
    # PowerShell hands back a COPY of a nested value type, so "$n.header.size = x"
    # would write to a temporary. Build the header whole, then assign it.
    $n = New-Object VrKit.Native+SOURCE_DEVICE_NAME
    $h = New-Object VrKit.Native+DEVICE_INFO_HEADER
    $h.type = $GET_SOURCE_NAME
    $h.size = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($n)
    $h.adapterId = $adapterId
    $h.id = $sourceId
    $n.header = $h
    if ([VrKit.Native]::DisplayConfigGetDeviceInfo([ref]$n) -ne 0) { return $null }
    return $n.viewGdiDeviceName
}

function Get-CcdSources {
    $c = Get-CcdConfig
    if (-not $c) { return @() }
    # Refresh rate lives on the path's target, keyed here by the source mode it drives.
    $hz = @{}
    for ($p = 0; $p -lt $c.NPath; $p++) {
        $rr = $c.Paths[$p].targetInfo.refreshRate
        if ($rr.Denominator) { $hz[[int]$c.Paths[$p].sourceInfo.modeInfoIdx] = [math]::Round($rr.Numerator / $rr.Denominator) }
    }
    $out = @()
    for ($i = 0; $i -lt $c.NMode; $i++) {
        if ($c.Modes[$i].infoType -ne $MODE_INFO_TYPE_SOURCE) { continue }
        $sm = $c.Modes[$i].sourceMode
        $out += [pscustomobject]@{
            Name = Get-SourceGdiName $c.Modes[$i].adapterId $c.Modes[$i].id
            X = $sm.position.x; Y = $sm.position.y; W = $sm.width; H = $sm.height
            Hz = $hz[$i]
            Primary = ($sm.position.x -eq 0 -and $sm.position.y -eq 0)
        }
    }
    return $out
}

function Set-PrimaryByCcd([string]$gdiName) {
    <# Primary is whichever source sits at the desktop origin. Shift every source
       by the target's offset so the target lands on (0,0) and the arrangement
       keeps its shape, then apply the whole layout at once. #>
    $c = Get-CcdConfig
    if (-not $c) { return @{ ok = $false; why = 'QueryDisplayConfig failed' } }

    $srcIdx = @()
    for ($i = 0; $i -lt $c.NMode; $i++) { if ($c.Modes[$i].infoType -eq $MODE_INFO_TYPE_SOURCE) { $srcIdx += $i } }
    if ($srcIdx.Count -lt 2) { return @{ ok = $false; why = "only $($srcIdx.Count) display attached" } }

    $target = -1
    foreach ($i in $srcIdx) { if ((Get-SourceGdiName $c.Modes[$i].adapterId $c.Modes[$i].id) -eq $gdiName) { $target = $i; break } }
    if ($target -lt 0) { return @{ ok = $false; why = "no active display named $gdiName" } }

    $dx = $c.Modes[$target].sourceMode.position.x
    $dy = $c.Modes[$target].sourceMode.position.y
    if ($dx -eq 0 -and $dy -eq 0) { return @{ ok = $true; why = 'already primary'; moved = $false } }

    foreach ($i in $srcIdx) {
        # Unwrap to the leaf, edit, and write every level back - see Get-SourceGdiName.
        $m = $c.Modes[$i]; $sm = $m.sourceMode; $p = $sm.position
        $p.x -= $dx; $p.y -= $dy
        $sm.position = $p; $m.sourceMode = $sm; $c.Modes[$i] = $m
    }

    $flags = $SDC_APPLY -bor $SDC_USE_SUPPLIED -bor $SDC_SAVE_TO_DATABASE -bor $SDC_ALLOW_CHANGES
    $rc = [VrKit.Native]::SetDisplayConfig($c.NPath, $c.Paths, $c.NMode, $c.Modes, $flags)
    if ($rc -eq 0) { return @{ ok = $true; why = 'applied'; moved = $true } }
    $rc2 = [VrKit.Native]::SetDisplayConfig($c.NPath, $c.Paths, $c.NMode, $c.Modes, $SDC_APPLY -bor $SDC_USE_SUPPLIED -bor $SDC_SAVE_TO_DATABASE)
    if ($rc2 -eq 0) { return @{ ok = $true; why = 'applied'; moved = $true } }
    return @{ ok = $false; why = "SetDisplayConfig returned $rc / $rc2" }
}

# --- parking the virtual display ----------------------------------------------------------
#
# WHY. A virtual display left attached to the desktop between sessions is a trap.
# When Windows switches the monitor off after its idle timer, a DisplayPort
# monitor drops off the desktop entirely - and the virtual display, which no one
# can see, is left as the only screen. Without something running to switch back,
# the desktop is stranded there. So the kit keeps the virtual display attached
# only while a session runs: connected at the start, parked (detached, still
# installed) at the end.
#
# Detaching needs no administrator rights: it removes the virtual display from the
# desktop layout, the same as unticking it in Display settings. It never detaches
# the virtual display when it is the only screen attached.

$script:SDC_TOPOLOGY_EXTEND = 0x00000004
$script:SDC_VALIDATE        = 0x00000040
$script:PATH_ACTIVE         = 0x00000001
$script:MODE_IDX_NONE       = [uint32]::MaxValue
$script:VirtualModeFile     = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\virtual-display.json'

function Save-VirtualMode([string]$VirtualAdapter = 'Virtual Display Driver') {
    $v = (Get-AttachedDisplays $VirtualAdapter | Where-Object Virtual | Select-Object -First 1).Name
    if (-not $v) { return }
    $m = Get-CcdSources | Where-Object Name -eq $v | Select-Object -First 1
    if (-not $m) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $VirtualModeFile -Parent) | Out-Null
    [pscustomobject]@{ W = $m.W; H = $m.H; Hz = $m.Hz } | ConvertTo-Json | Set-Content $VirtualModeFile -Encoding utf8
}

function Get-SavedVirtualMode {
    if (Test-Path $VirtualModeFile) { try { return Get-Content $VirtualModeFile -Raw | ConvertFrom-Json } catch { } }
    return $null
}

# --- following the display set --------------------------------------------------------------
#
# Bigscreen creates a screen capture for EVERY monitor on the GPU when it starts,
# not just the one it streams. When a monitor leaves the desktop - a DisplayPort
# monitor switched off, a cable pulled - that capture cannot be rebuilt, and the
# capture thread can stop, taking the stream down even though the headset was
# watching the virtual display. So the session watches the set of attached
# displays, and restarts Bigscreen whenever it changes (see session-watch.ps1).
#
# The signature is built from adapter and target ids rather than names: a monitor
# that comes back can be handed a different \\.\DISPLAYn name, but the same target.

$script:PhysicalFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\physical-display.json'

function Get-DisplaySetSignature {
    # One short string for "which displays are attached right now".
    $c = Get-CcdConfig
    if (-not $c) { return $null }
    $ids = for ($i = 0; $i -lt $c.NPath; $i++) {
        $t = $c.Paths[$i].targetInfo
        '{0}:{1}:{2}' -f $t.adapterId.HighPart, $t.adapterId.LowPart, $t.id
    }
    return (($ids | Sort-Object) -join '|')
}

function Save-PrimaryPhysical([string]$VirtualAdapter = 'Virtual Display Driver') {
    # Remember which display was primary before the session took over, so it can be
    # handed back to the same one afterwards - on any system, not just a two-display
    # one. Falls back to any attached physical display if nothing was saved.
    $physical = @(Get-AttachedDisplays $VirtualAdapter | Where-Object { -not $_.Virtual })
    if (-not $physical) { return }
    $primary = (Get-CcdSources | Where-Object Primary | Select-Object -First 1).Name
    $name = if ($primary -and ($physical | Where-Object Name -eq $primary)) { $primary } else { $physical[0].Name }

    $c = Get-CcdConfig
    if (-not $c) { return }
    for ($i = 0; $i -lt $c.NPath; $i++) {
        $s = $c.Paths[$i].sourceInfo
        if ((Get-SourceGdiName $s.adapterId $s.id) -ne $name) { continue }
        $t = $c.Paths[$i].targetInfo
        New-Item -ItemType Directory -Force -Path (Split-Path $PhysicalFile -Parent) | Out-Null
        [pscustomobject]@{ Name = $name; AdapterHigh = $t.adapterId.HighPart; AdapterLow = $t.adapterId.LowPart; TargetId = $t.id } |
            ConvertTo-Json | Set-Content $PhysicalFile -Encoding utf8
        return
    }
}

function Get-SavedPrimaryPhysical {
    if (Test-Path $PhysicalFile) { try { return Get-Content $PhysicalFile -Raw | ConvertFrom-Json } catch { } }
    return $null
}

function Resolve-SavedPhysicalName {
    # The saved display's CURRENT name, or $null if it is not attached: a display
    # that has been switched off and on again can come back under another name.
    $saved = Get-SavedPrimaryPhysical
    if (-not $saved) { return $null }
    $c = Get-CcdConfig
    if (-not $c) { return $null }
    for ($i = 0; $i -lt $c.NPath; $i++) {
        $t = $c.Paths[$i].targetInfo
        if ($t.adapterId.HighPart -ne $saved.AdapterHigh -or $t.adapterId.LowPart -ne $saved.AdapterLow -or $t.id -ne $saved.TargetId) { continue }
        $s = $c.Paths[$i].sourceInfo
        return Get-SourceGdiName $s.adapterId $s.id
    }
    return $null
}

function Disconnect-VirtualDisplay([string]$VirtualAdapter = 'Virtual Display Driver') {
    $displays = @(Get-AttachedDisplays $VirtualAdapter)
    $virtual = $displays | Where-Object Virtual | Select-Object -First 1
    if (-not $virtual) { return @{ ok = $true; why = 'already parked'; changed = $false } }
    if (-not ($displays | Where-Object { -not $_.Virtual })) {
        return @{ ok = $false; why = 'it is the only screen attached - left in place so the desktop is never without a display'; changed = $false }
    }
    Save-VirtualMode $VirtualAdapter

    $c = Get-CcdConfig
    if (-not $c) { return @{ ok = $false; why = 'QueryDisplayConfig failed'; changed = $false } }

    # Keep every other path with its own mode records, renumbered into a fresh
    # array. Handing back modes that belong to the removed path makes Windows
    # reject the whole layout; handing back none lets it choose modes itself.
    $modes = New-Object System.Collections.Generic.List[VrKit.Native+MODE_INFO]
    $remap = @{}
    function Keep-Mode([uint32]$idx) {
        if ($idx -ge $c.NMode) { return $MODE_IDX_NONE }
        if (-not $remap.ContainsKey([int]$idx)) { $remap[[int]$idx] = $modes.Count; $modes.Add($c.Modes[$idx]) }
        return [uint32]$remap[[int]$idx]
    }
    for ($i = 0; $i -lt $c.NPath; $i++) {
        $p = $c.Paths[$i]; $si = $p.sourceInfo; $ti = $p.targetInfo
        $name = Get-SourceGdiName $si.adapterId $si.id
        if ($name -eq $virtual.Name) {
            if ($p.flags -band $PATH_ACTIVE) { $p.flags = [uint32]($p.flags - $PATH_ACTIVE) }
            $si.modeInfoIdx = $MODE_IDX_NONE; $ti.modeInfoIdx = $MODE_IDX_NONE
        } else {
            $si.modeInfoIdx = Keep-Mode $si.modeInfoIdx
            $ti.modeInfoIdx = Keep-Mode $ti.modeInfoIdx
        }
        $p.sourceInfo = $si; $p.targetInfo = $ti; $c.Paths[$i] = $p
    }
    $arr = $modes.ToArray()

    # Something must remain at the desktop origin: if the virtual display was
    # primary, shift the remaining sources so the first lands on (0,0).
    $srcIdx = @(for ($k = 0; $k -lt $arr.Length; $k++) { if ($arr[$k].infoType -eq $MODE_INFO_TYPE_SOURCE) { $k } })
    if ($srcIdx.Count -and -not ($srcIdx | Where-Object { $arr[$_].sourceMode.position.x -eq 0 -and $arr[$_].sourceMode.position.y -eq 0 })) {
        $dx = $arr[$srcIdx[0]].sourceMode.position.x; $dy = $arr[$srcIdx[0]].sourceMode.position.y
        foreach ($k in $srcIdx) { $m = $arr[$k]; $sm = $m.sourceMode; $pos = $sm.position; $pos.x -= $dx; $pos.y -= $dy; $sm.position = $pos; $m.sourceMode = $sm; $arr[$k] = $m }
    }

    $flags = $SDC_USE_SUPPLIED -bor $SDC_SAVE_TO_DATABASE -bor $SDC_ALLOW_CHANGES
    $rc = [VrKit.Native]::SetDisplayConfig($c.NPath, $c.Paths, [uint32]$arr.Length, $arr, $flags -bor $SDC_VALIDATE)
    if ($rc -ne 0) { return @{ ok = $false; why = "Windows rejected the layout (validate returned $rc)"; changed = $false } }
    $rc = [VrKit.Native]::SetDisplayConfig($c.NPath, $c.Paths, [uint32]$arr.Length, $arr, $flags -bor $SDC_APPLY)
    if ($rc -ne 0) { return @{ ok = $false; why = "SetDisplayConfig returned $rc"; changed = $false } }

    for ($t = 0; $t -lt 20; $t++) {
        if (-not (Get-AttachedDisplays $VirtualAdapter | Where-Object Virtual)) { return @{ ok = $true; why = 'parked'; changed = $true } }
        Start-Sleep -Milliseconds 500
    }
    return @{ ok = $false; why = 'the layout was applied but the virtual display is still attached'; changed = $false }
}

function Connect-VirtualDisplay([string]$VirtualAdapter = 'Virtual Display Driver', [int]$TimeoutSeconds = 15) {
    if (Get-AttachedDisplays $VirtualAdapter | Where-Object Virtual) { return @{ ok = $true; why = 'already connected'; changed = $false } }
    if (-not (Test-VirtualAdapterPresent $VirtualAdapter)) { return @{ ok = $false; why = "no display adapter matching '$VirtualAdapter' is installed"; changed = $false } }
    # "Extend" asks Windows to bring every connected display back into the desktop,
    # using the layout it last saved for that set of displays.
    $rc = [VrKit.Native]::SetDisplayConfig(0, $null, 0, $null, $SDC_TOPOLOGY_EXTEND -bor $SDC_APPLY)
    if ($rc -ne 0) { return @{ ok = $false; why = "SetDisplayConfig (extend) returned $rc"; changed = $false } }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-AttachedDisplays $VirtualAdapter | Where-Object Virtual) { Start-Sleep -Seconds 1; return @{ ok = $true; why = 'connected'; changed = $true } }
        Start-Sleep -Milliseconds 500
    }
    return @{ ok = $false; why = "the virtual display did not attach within $TimeoutSeconds s"; changed = $false }
}
