# devbench Windows runtime_init. Mirrors scripts/common/runtime_init.sh.
# Emits the initial `runtime` object (minus `ended`) as JSON to stdout.

[CmdletBinding()]
param(
    [int]   $AmbientSeconds = 10,
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib.ps1')

# Power source
$powerSource = 'unknown'
try {
    $bs = Get-CimInstance -ClassName BatteryStatus -Namespace root\wmi -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bs) {
        $powerSource = if ($bs.PowerOnline) { 'ac' } else { 'battery' }
    } else {
        $powerSource = 'ac'   # desktop, no battery
    }
} catch { $powerSource = 'unknown' }

# Ambient CPU%
Write-Info "sampling ambient CPU for $AmbientSeconds s ..."
$samples = 1..$AmbientSeconds | ForEach-Object {
    (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples.CookedValue
    Start-Sleep -Seconds 1
}
$samples = $samples | Where-Object { $_ -is [double] -or $_ -is [int] }
$ambientCpuPct = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Average).Average, 2) } else { $null }

# RAM used
$os = Get-CimInstance Win32_OperatingSystem
$totalKb = $os.TotalVisibleMemorySize
$freeKb  = $os.FreePhysicalMemory
$ramUsedGb = if ($totalKb -and $freeKb) { [math]::Round((($totalKb - $freeKb) / 1MB), 2) } else { $null }

# Config sha
$configSha = $null
if ($Config -and (Test-Path $Config)) {
    $configSha = (Get-FileHash -Path $Config -Algorithm SHA256).Hash.ToLower()
}

$obj = [ordered]@{
    started            = Get-Timestamp
    power_source       = $powerSource
    ambient_cpu_pct    = $ambientCpuPct
    ambient_ram_used_gb = $ramUsedGb
    devbench_version   = $script:DevbenchVersion
    config_sha         = $configSha
}
$obj | ConvertTo-DevbenchJson
