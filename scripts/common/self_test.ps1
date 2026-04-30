# devbench Windows self-test / calibration.
# Mirrors scripts/common/self_test.sh. Writes verdict JSON to stdout, logs to the host.

[CmdletBinding()]
param(
    [double]$CvThresholdPct = [double]($env:DEVBENCH_CV_THRESHOLD ?? 3.0),
    [int]   $Iterations    = [int]   ($env:DEVBENCH_CALIB_ITERS   ?? 10)
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib.ps1')

Assert-Command hyperfine
Assert-Command jq
Assert-Command openssl

Write-Info "self-test on windows ($(Get-DevbenchArch))"

$tools = @('git','jq','hyperfine','openssl')
foreach ($t in $tools) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if ($cmd) { Write-Info "$t`: $($cmd.Path)" }
    else      { Write-Warn2 "$t`: missing" }
}

# Host probe sanity
$probeJson = & (Join-Path $ScriptRoot '..\windows\probe.ps1')
Write-Info ("probe ok: " + ($probeJson | ConvertFrom-Json).cpu.model)

# Calibration: 32 MB sha256 (smaller than unix version since openssl on Windows is slower per-MB
# under default installs; we want the iteration time to sit around 50–200 ms).
$tmp = New-TemporaryFile
try {
    Write-Info "calibration: $Iterations iterations of sha256(128MB) ..."
    $calibCmd = 'powershell -NoProfile -Command "[System.Security.Cryptography.SHA256]::Create().ComputeHash((New-Object byte[] 134217728)) | Out-Null"'
    & hyperfine --warmup 2 --min-runs $Iterations --max-runs $Iterations `
                --shell=none --export-json $tmp.FullName `
                --command-name 'calib_sha256_128M' $calibCmd | Out-Null

    $result = (Get-Content $tmp.FullName | ConvertFrom-Json).results[0]
    $mean   = [double]$result.mean
    $stddev = [double]$result.stddev
    $cvPct  = if ($mean -gt 0) { [math]::Round(($stddev / $mean) * 100, 3) } else { [double]::NaN }

    Write-Info "mean=${mean}s stddev=${stddev}s cv=${cvPct}%"

    $verdict = if ($cvPct -gt $CvThresholdPct) { 'noisy' } else { 'ok' }

    $out = [ordered]@{
        verdict = $verdict
        os      = 'windows'
        arch    = (Get-DevbenchArch)
        calib   = [ordered]@{
            workload      = 'sha256_128M'
            iterations    = $Iterations
            mean_s        = $mean
            stddev_s      = $stddev
            cv_pct        = $cvPct
            threshold_pct = $CvThresholdPct
        }
    }
    $out | ConvertTo-DevbenchJson

    if ($verdict -eq 'noisy') {
        Write-Err "CV ${cvPct}% exceeds threshold ${CvThresholdPct}%. Re-run preflight (docs/preflight.md)."
        exit 2
    }
    Write-Info 'self-test passed.'
}
finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
