# devbench Windows bootstrap.
#
# Usage:
#   .\bootstrap.ps1                  # baseline
#   .\bootstrap.ps1 -Toolchains
#   .\bootstrap.ps1 -AI
#   .\bootstrap.ps1 -All
#
# Uses winget. Assumes Windows 11 and PowerShell 7+. Supports x64 and arm64.

[CmdletBinding()]
param(
    [switch]$Baseline,
    [switch]$Toolchains,
    [switch]$AI,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot '..\common\lib.ps1')

if (-not ($Baseline -or $Toolchains -or $AI -or $All)) { $Baseline = $true }
if ($All) { $Baseline = $true; $Toolchains = $true; $AI = $true }

Assert-Command winget

function Install-WingetPackage {
    param([Parameter(Mandatory)][string]$Id, [string]$Source = 'winget')
    Write-Info "installing: $Id"
    winget install --id $Id --source $Source --accept-package-agreements --accept-source-agreements -e -h | Out-Null
}

if ($Baseline) {
    Write-Info '--- baseline ---'
    $pkgs = @(
        'jqlang.jq',
        'sharkdp.hyperfine',
        'sharkdp.fd',
        'BurntSushi.ripgrep.MSVC',
        'Git.Git',
        'ShiningLight.OpenSSL.Light',
        'axboe.fio',
        '7zip.7zip'
    )
    foreach ($p in $pkgs) { Install-WingetPackage -Id $p }
    # stress-ng is not available natively on Windows; use WSL for those tiers.
    Write-Warn2 'stress-ng: install inside WSL2 for tests that require it.'
}

if ($Toolchains) {
    Write-Info '--- toolchains ---'
    $pkgs = @(
        'Kitware.CMake',
        'Ninja-build.Ninja',
        'Python.Python.3.13',
        'OpenJS.NodeJS.LTS',      # Node 24 LTS when available
        'GoLang.Go',
        'Rustlang.Rustup',
        'LLVM.LLVM',
        'Microsoft.VisualStudio.2022.BuildTools',  # MSVC toolchain for Rust & native builds
        'pnpm.pnpm',
        'Oven-sh.Bun',
        'astral-sh.uv',
        'astral-sh.ruff'
    )
    foreach ($p in $pkgs) { Install-WingetPackage -Id $p }
}

if ($AI) {
    Write-Info '--- ai inference ---'
    # llama.cpp provides prebuilt Windows releases (x64 + arm64 with Vulkan/DirectML).
    Write-Warn2 'Download llama.cpp prebuilt release manually from https://github.com/ggerganov/llama.cpp/releases'
    Write-Warn2 'For Snapdragon X (QNN backend): requires Qualcomm AI Engine Direct SDK.'
    # whisper.cpp similar story
    Write-Warn2 'whisper.cpp prebuilt: https://github.com/ggerganov/whisper.cpp/releases'
}

Write-Info 'bootstrap done. restart shell to pick up PATH, then run scripts\common\self_test.ps1'
