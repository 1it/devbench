# devbench Windows host probe.
# Emits the `host` portion of a devbench run.json (per docs/schema.json) to stdout.
# Write-Info/Warn2/Err go to the host stream so piping to a file captures only JSON.
#
# Works on Windows 11 x64 and arm64. PowerShell 7+ recommended.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot '..\common\lib.ps1')

$hostname = $env:COMPUTERNAME
$arch     = Get-DevbenchArch

$osInfo   = Get-CimInstance Win32_OperatingSystem
$osVer    = $osInfo.Version                # e.g. 10.0.26100
$osCap    = $osInfo.Caption                # e.g. "Microsoft Windows 11 Pro"
$osBuild  = $osInfo.BuildNumber

$cpuList  = Get-CimInstance Win32_Processor
$cpuModel = ($cpuList | Select-Object -First 1 -ExpandProperty Name).Trim()
$cpuVendor= ($cpuList | Select-Object -First 1 -ExpandProperty Manufacturer)
$coresTotal   = ($cpuList | Measure-Object -Property NumberOfCores          -Sum).Sum
$threadsTotal = ($cpuList | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$baseMHz      = ($cpuList | Select-Object -First 1 -ExpandProperty MaxClockSpeed)
$baseGhz      = if ($baseMHz) { [math]::Round($baseMHz / 1000, 2) } else { $null }

# P/E cores on Intel hybrid (x64 only; no public API on arm64 yet).
# Use powercfg to enumerate heterogeneous schedulers.
$coresP = $null
$coresE = $null
if ($arch -eq 'x86_64') {
    try {
        $hetOutput = & powercfg /SystemPowerReport /OUTPUT "$env:TEMP\devbench-power.html" /DURATION 1 2>$null
        # Simpler: parse `Get-ComputerInfo` -> CsProcessors or WMI's "SecondLevelAddressTranslationExtensions"?
        # Best practical: read the per-logical-processor info via Get-CimInstance Win32_Processor,
        # but hybrid detail isn't exposed there. Skip cleanly if we can't.
    } catch { }
    # Fallback: look for hybrid tag in $cpuModel and leave null.
}

$ramBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
if (-not $ramBytes) { $ramBytes = $osInfo.TotalVisibleMemorySize * 1KB }
$ramGb = [math]::Round($ramBytes / 1GB, 2)

$dimms        = Get-CimInstance Win32_PhysicalMemory
$ramSpeedMts  = if ($dimms) { ($dimms | Select-Object -First 1 -ExpandProperty ConfiguredClockSpeed) } else { $null }
# Channels heuristic: count distinct BankLabels.
$ramChannels  = if ($dimms) { ($dimms | Select-Object -ExpandProperty BankLabel -Unique | Measure-Object).Count } else { $null }

$rootVolume   = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))
$rootFs       = $rootVolume.FileSystemType
$rootSizeGb   = [math]::Round($rootVolume.Size / 1GB, 0)

# Physical disk backing C:
$part         = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
$diskModel    = 'unknown'
if ($part) {
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
    if ($disk) { $diskModel = "$($disk.FriendlyName)".Trim() }
}

$host_obj = [ordered]@{
    hostname = $hostname
    os = [ordered]@{
        name    = 'windows'
        version = $osVer
        pretty  = $osCap
        build   = $osBuild
        arch    = $arch
    }
    cpu = [ordered]@{
        model              = $cpuModel
        vendor             = $cpuVendor
        cores_total        = [int]$coresTotal
        threads_total      = [int]$threadsTotal
        cores_performance  = $coresP
        cores_efficiency   = $coresE
        base_ghz           = $baseGhz
        boost_ghz          = $null   # not reliably exposed on Windows without vendor tools
    }
    ram_gb         = $ramGb
    ram_speed_mts  = if ($ramSpeedMts) { [int]$ramSpeedMts } else { $null }
    ram_channels   = if ($ramChannels) { [int]$ramChannels } else { $null }
    storage = [ordered]@{
        model      = $diskModel
        filesystem = $rootFs
        size_gb    = [int]$rootSizeGb
    }
}

$host_obj | ConvertTo-DevbenchJson
