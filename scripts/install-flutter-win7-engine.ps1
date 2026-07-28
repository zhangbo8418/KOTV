# 将 Win7 可用的 Flutter Windows x64 engine 解压进当前 Flutter SDK。
# 官方 3.24 engine 的 flutter_windows.dll 会依赖 GetHostNameW（仅 Win8+），Win7 启动即报错。
param(
    [string]$EngineZipUrl = $env:KOTV_FLUTTER_ENGINE_ZIP_URL
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($EngineZipUrl)) {
    $EngineZipUrl = "https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip"
}

$flutter = Get-Command flutter -ErrorAction Stop
$sdkRoot = Split-Path (Split-Path $flutter.Source -Parent) -Parent
$engineDir = Join-Path $sdkRoot "bin\cache\artifacts\engine\windows-x64-release"

Write-Host "Flutter SDK: $sdkRoot"
Write-Host "Engine URL:  $EngineZipUrl"
Write-Host "Engine dir:  $engineDir"

$tmp = Join-Path $env:TEMP ("kotv-flutter-engine-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $zip = Join-Path $tmp "engine.zip"
    curl.exe -fsSL -o $zip $EngineZipUrl
    Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "extract") -Force
    $src = Join-Path $tmp "extract"
    if (Test-Path (Join-Path $src "windows-x64-release")) {
        $src = Join-Path $src "windows-x64-release"
    }
    if (-not (Test-Path (Join-Path $src "flutter_windows.dll"))) {
        throw "zip 内未找到 flutter_windows.dll，请检查 engine 包结构"
    }
    if (Test-Path $engineDir) { Remove-Item -Recurse -Force $engineDir }
    New-Item -ItemType Directory -Path $engineDir -Force | Out-Null
    Copy-Item -Recurse -Force (Join-Path $src "*") $engineDir
    Write-Host "Win7 engine installed."
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
