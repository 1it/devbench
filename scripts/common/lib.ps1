# devbench shared PowerShell helpers. Dot-source me.
#   . .\scripts\common\lib.ps1

$script:DevbenchVersion        = '0.1.0'
$script:DevbenchSchemaVersion  = '1'

function Get-Timestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Write-Info  { param([string]$Msg) Write-Host -ForegroundColor Green  "[info $(Get-Timestamp)] $Msg" }
function Write-Warn2 { param([string]$Msg) Write-Host -ForegroundColor Yellow "[warn $(Get-Timestamp)] $Msg" }
function Write-Err   { param([string]$Msg) Write-Host -ForegroundColor Red    "[err  $(Get-Timestamp)] $Msg" }

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "required command not found: $Name (install via scripts\windows\bootstrap.ps1)"
    }
}

function Get-DevbenchArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x86_64' }
        'ARM64' { 'arm64'  }
        default { 'unknown' }
    }
}

function ConvertTo-DevbenchJson {
    param([Parameter(Mandatory,ValueFromPipeline)][object]$Obj, [int]$Depth = 8)
    $Obj | ConvertTo-Json -Depth $Depth -Compress:$false
}
