$os = Get-CimInstance Win32_OperatingSystem
$totalMem = $os.TotalVisibleMemorySize
$freeMem = $os.FreePhysicalMemory
$usedPct = [math]::Round((1 - ($freeMem / $totalMem)) * 100, 1)
# TotalVisibleMemorySize / FreePhysicalMemory are in KB, so KB / 1MB = GB
Write-Host ('Memory usage: {0}% ({1:N1} GB free of {2:N1} GB)' -f $usedPct, ($freeMem / 1MB), ($totalMem / 1MB))
if ($usedPct -gt 90) { Write-Host '[ISSUE] Memory consistently high - check top processes' }

$cpuSamples = @()
1..3 | ForEach-Object { $cpuSamples += (Get-CimInstance Win32_Processor).LoadPercentage; Start-Sleep -Seconds 1 }
$avgCpu = [math]::Round(($cpuSamples | Measure-Object -Average).Average, 1)
Write-Host "CPU usage (3s avg): ${avgCpu}%"
if ($avgCpu -gt 90) { Write-Host '[ISSUE] CPU consistently high - check Resource Monitor' }
Write-Host 'Tip: Chrome with many tabs or high svchost often causes slowness. Patch/driver update may be needed.'
