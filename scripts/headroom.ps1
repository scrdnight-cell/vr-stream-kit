# Measure GPU headroom while your activity runs.
#
# Start the game or film first, then run the check. It samples the GPU for a
# short while and reports the peak load, the busiest program, the video engine
# load (Bigscreen's encoder, if running) and video memory, with a verdict.
#
# GPU load is computed the way Task Manager does: per engine, sum every
# program's share; the busiest engine is the GPU's load.

function Measure-KitHeadroom([int]$Seconds = 20, $envInfo) {
    # One counter call collecting every sample: enumerating the GPU's many engine
    # instances is the slow part, so doing it once per call - not once per
    # sample - keeps the check close to the time it promises.
    $peak = 0.0; $peak3d = 0.0; $peakVideo = 0.0; $peakMem = 0.0; $sum = 0.0
    $byProc = @{}
    $count = [math]::Max(3, [math]::Ceiling($Seconds / 2))
    Write-Host "  measuring for about $Seconds seconds..."
    $sets = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage', '\GPU Adapter Memory(*)\Dedicated Usage' `
                        -SampleInterval 2 -MaxSamples $count -EA SilentlyContinue
    $samples = 0
    foreach ($set in $sets) {
        $samples++
        $eng = @{}; $threeD = @{}; $video = @{}; $mem = 0.0
        foreach ($s in $set.CounterSamples) {
            if ($s.Path -like '*gpu adapter memory*') { $mem = [math]::Max($mem, $s.CookedValue); continue }
            $m = [regex]::Match($s.InstanceName, 'pid_(\d+)_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)_eng_(\d+)_engtype_(\w*)')
            if (-not $m.Success) { continue }
            $key = "$($m.Groups[2].Value)_$($m.Groups[3].Value)_$($m.Groups[4].Value)"
            $eng[$key] = [double]$eng[$key] + $s.CookedValue
            $type = $m.Groups[5].Value
            if ($type -eq '3D') {
                $threeD[$key] = [double]$threeD[$key] + $s.CookedValue
                $pid_ = [int]$m.Groups[1].Value
                $byProc[$pid_] = [math]::Max([double]$byProc[$pid_], $s.CookedValue)
            }
            if ($type -match '^Video') { $video[$key] = [double]$video[$key] + $s.CookedValue }
        }
        $g = [double](($eng.Values | Measure-Object -Maximum).Maximum)
        $peak = [math]::Max($peak, $g); $sum += $g
        $peak3d = [math]::Max($peak3d, [double](($threeD.Values | Measure-Object -Maximum).Maximum))
        $peakVideo = [math]::Max($peakVideo, [double](($video.Values | Measure-Object -Maximum).Maximum))
        $peakMem = [math]::Max($peakMem, $mem / 1GB)
    }
    if ($samples -eq 0) { '  Could not read the GPU performance counters.'; return }
    Write-Host ''
    $top = $byProc.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $topName = if ($top) { (Get-Process -Id $top.Key -EA SilentlyContinue).Name } else { $null }
    $bigscreen = [bool](Get-Process BigscreenRemoteDesktop -EA SilentlyContinue)
    $vram = if ($envInfo -and $envInfo.Gpu) { $envInfo.Gpu.VramGB } else { 0 }

    ''
    '  HEADROOM CHECK'
    '  --------------'
    "  GPU load         peak {0:N0}%, average {1:N0}%" -f $peak, ($sum / $samples)
    if ($topName) { "  Busiest program  {0} ({1:N0}% 3D)" -f $topName, $top.Value }
    "  Video engine     peak {0:N0}%{1}" -f $peakVideo, $(if ($bigscreen) { ' (includes Bigscreen''s encoder)' } else { ' (Bigscreen not running - its encoder is not included)' })
    if ($vram) { "  Video memory     {0:N1} of {1} GB" -f $peakMem, $vram } else { "  Video memory     {0:N1} GB used" -f $peakMem }
    ''
    if ($peak -ge 95) {
        '  VERDICT: NO HEADROOM. The GPU is flat out, so the stream encoder can be starved.'
        '  Lower the game''s render resolution, cap its frame rate, enable its upscaler, or choose a lighter profile.'
    } elseif ($peak -ge 85) {
        '  VERDICT: TIGHT. Fine most of the time, but loading screens and busy scenes may push it to 100%.'
        '  Consider a frame cap or one lighter graphics setting for safety.'
    } else {
        '  VERDICT: HEALTHY. There is room for the encoder.'
        if (-not $bigscreen) { '  Bigscreen was not running: its encoder adds roughly 10-40% video-engine load depending on the profile.' }
    }
    if ($vram -and $peakMem -gt 0.9 * $vram) { '  Video memory is nearly full - lower texture quality in the game.' }
}
