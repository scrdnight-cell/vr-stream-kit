# Optional: record GPU and network load during a session, to tune a profile.
#
#   powershell -ExecutionPolicy Bypass -File session-telemetry.ps1 -App <process name>
#   e.g. -App msedge   (films in Edge)    -App MyGame   (a game's .exe name without .exe)
#
# Every $Every seconds it writes a CSV row: the app's GPU 3D load, Bigscreen's
# video-engine (encoder) load, dedicated GPU memory, CPU, and network send/receive
# on the busiest adapter. It prints only events - crashes, GPU resets, Bigscreen
# or the app starting and stopping, displays changing - plus a summary every
# $SummaryMinutes minutes. Stop it with Ctrl+C.
#
# What to look for: if the app's GPU load sits near 100% while Bigscreen's
# encoder load is high, the encoder can be starved of GPU time and the stream
# can drop. Lower the game's render resolution, cap its frame rate, or lower the
# stream profile until the app's load has headroom.
#
# Reading every GPU counter costs a few seconds of one CPU core per sample.

param(
    [Parameter(Mandatory)] [string]$App,
    [int]$Every = 30,
    [int]$SummaryMinutes = 5,
    [string]$Csv = (Join-Path (Split-Path $PSScriptRoot -Parent) "logs\telemetry-$(Get-Date -Format yyyyMMdd-HHmmss).csv")
)

function Emit($m) { "$((Get-Date).ToString('HH:mm:ss'))  $m" }
New-Item -ItemType Directory -Force -Path (Split-Path $Csv -Parent) | Out-Null
'time,app_3d_pct,encoder_pct,gpu_dedicated_mb,cpu_pct,net_send_mbps,net_recv_mbps' | Set-Content $Csv -Encoding utf8

$paths = @('\GPU Engine(*)\Utilization Percentage', '\GPU Adapter Memory(*)\Dedicated Usage',
           '\Processor(_Total)\% Processor Time', '\Network Interface(*)\Bytes Sent/sec', '\Network Interface(*)\Bytes Received/sec')
$lastEvents = Get-Date
$window = New-Object System.Collections.Generic.List[object]
$lastSummary = Get-Date
Emit "recording every $Every s to $Csv"

while ($true) {
    $appIds = @(Get-Process -Name $App -EA SilentlyContinue).Id
    $bsIds  = @(Get-Process -Name BigscreenRemoteDesktop -EA SilentlyContinue).Id
    $row = [ordered]@{ time = (Get-Date).ToString('HH:mm:ss'); app3d = 0.0; enc = 0.0; gpuMb = 0.0; cpu = 0.0; tx = 0.0; rx = 0.0 }
    try {
        foreach ($s in (Get-Counter $paths -EA SilentlyContinue).CounterSamples) {
            $v = $s.CookedValue
            if ($s.Path -like '*gpu engine*') {
                $m = [regex]::Match($s.InstanceName, 'pid_(\d+).*engtype_(\w+)'); $p = [int]$m.Groups[1].Value; $e = $m.Groups[2].Value
                if ($appIds -contains $p -and $e -eq '3D') { $row.app3d += $v }
                elseif ($bsIds -contains $p -and $e -eq 'VideoDecode') { $row.enc += $v }   # the Intel/AMD media engine reports under this name
            }
            elseif ($s.Path -like '*gpu adapter memory*') { $row.gpuMb = [math]::Max($row.gpuMb, $v / 1MB) }
            elseif ($s.Path -like '*processor*') { $row.cpu = $v }
            elseif ($s.Path -like '*bytes sent*') { $row.tx = [math]::Max($row.tx, $v * 8 / 1e6) }
            elseif ($s.Path -like '*bytes received*') { $row.rx = [math]::Max($row.rx, $v * 8 / 1e6) }
        }
    } catch { }
    ($row.Values | ForEach-Object { if ($_ -is [double]) { [math]::Round($_, 1) } else { $_ } }) -join ',' | Add-Content $Csv
    $window.Add($row)

    $now = Get-Date
    foreach ($ev in (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $lastEvents } -EA SilentlyContinue |
                     Where-Object { $_.ProviderName -eq 'Application Error' -or ($_.ProviderName -eq 'Windows Error Reporting' -and $_.Message -match 'P1:\s*141') } |
                     Sort-Object TimeCreated)) {
        if ($ev.ProviderName -eq 'Application Error') {
            Emit ("CRASH {0} ({1})" -f [regex]::Match($ev.Message, 'Faulting application name:\s*([^,]+)').Groups[1].Value, [regex]::Match($ev.Message, 'Exception code:\s*(\S+)').Groups[1].Value)
        } elseif (-not $resetSaid -or ($ev.TimeCreated - $resetSaid).TotalSeconds -gt 30) {
            $resetSaid = $ev.TimeCreated
            Emit ("GPU RESET at {0} - app 3D {1:N0}%, encoder {2:N0}%" -f $ev.TimeCreated.ToString('HH:mm:ss'), $row.app3d, $row.enc)
        }
    }
    $lastEvents = $now

    $bsNow = $bsIds.Count -gt 0; $appNow = $appIds.Count -gt 0
    if ($null -ne $bsWas -and $bsNow -ne $bsWas) { Emit $(if ($bsNow) { 'Bigscreen started' } else { 'Bigscreen stopped' }) }
    if ($null -ne $appWas -and $appNow -ne $appWas) { Emit $(if ($appNow) { "$App started" } else { "$App stopped" }) }
    $bsWas = $bsNow; $appWas = $appNow

    if (((Get-Date) - $lastSummary).TotalMinutes -ge $SummaryMinutes -and $window.Count) {
        $st = { param($k) $window | ForEach-Object { $_[$k] } | Measure-Object -Average -Maximum }
        $a = & $st 'app3d'; $b = & $st 'enc'; $g = & $st 'gpuMb'; $t = & $st 'tx'
        Emit ("summary: app 3D avg {0:N0}% max {1:N0}% | encoder avg {2:N0}% max {3:N0}% | GPU memory max {4:N0} MB | upload avg {5:N1} Mbit/s" -f $a.Average, $a.Maximum, $b.Average, $b.Maximum, $g.Maximum, $t.Average)
        $window.Clear(); $lastSummary = Get-Date
    }
    Start-Sleep -Seconds $Every
}
