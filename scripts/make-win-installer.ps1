# 用 Inno Setup 打包 Windows 安装程序（显示名 / 快捷方式：KO影视）
# 用法:
#   pwsh scripts/make-win-installer.ps1 -Plat windows-x64 -Version 1.2.3 -Tag v1.2.3
param(
    [ValidateSet("windows-x64", "windows-arm64")]
    [string]$Plat = "windows-x64",
    [string]$Version = "",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Iss = Join-Path $Root "scripts\windows\kotv.iss"
$SourceDir = Join-Path $Root "dist\KOTV-$Plat"

if (-not (Test-Path $Iss)) { throw "missing iss: $Iss" }
if (-not (Test-Path (Join-Path $SourceDir "KOTV.exe"))) {
    throw "missing package dir or KOTV.exe: $SourceDir (run package.sh first)"
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = if ($env:KOTV_VERSION) { $env:KOTV_VERSION } else { "v0.1.0" }
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $Tag.TrimStart("v")
}
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = "0.1.0" }

$arch = if ($Plat -eq "windows-arm64") { "arm64" } else { "x64" }
$archLabel = if ($Plat -eq "windows-arm64") { "arm64" } else { "amd64" }
$outBase = "KOTV-win-$archLabel-$Tag-setup"
$outDir = $Root

$iscc = $null
foreach ($cand in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe"
    )) {
    if (Test-Path $cand) { $iscc = $cand; break }
}
if (-not $iscc) {
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 (choco install innosetup)."
}

Write-Host "==> Inno Setup: $iscc"
Write-Host "    Plat=$Plat Version=$Version Tag=$Tag"
Write-Host "    Source=$SourceDir"
Write-Host "    Output=$outDir\$outBase.exe"

# 路径用正斜杠，避免 Inno 预处理把 \ 当转义
$srcIss = ($SourceDir -replace '\\', '/')
$outIss = ($outDir -replace '\\', '/')
& $iscc `
    "/DMyAppVersion=$Version" `
    "/DMySourceDir=$srcIss" `
    "/DMyOutputDir=$outIss" `
    "/DMyOutputBase=$outBase" `
    "/DMyArch=$arch" `
    $Iss
if ($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit $LASTEXITCODE"
}

$outFile = Join-Path $outDir "$outBase.exe"
if (-not (Test-Path $outFile)) {
    throw "installer not produced: $outFile"
}
Write-Host "==> installer ready: $outFile"
Get-Item $outFile | Format-List FullName, Length, LastWriteTime
