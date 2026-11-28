# CI：安装 go-legacy-win7（Windows x64 runner；Win7 兼容构建用）。
# 用法: ./scripts/ci-install-go-legacy-win7.ps1 [-Ver 1.27.4-1]
param(
  [string]$Ver = $(if ($env:KOTV_GO_LEGACY_WIN7_VER) { $env:KOTV_GO_LEGACY_WIN7_VER } else { "1.27.4-1" })
)
$ErrorActionPreference = "Stop"
$zip = "go-legacy-win7-$Ver.windows_amd64.zip"
$url = "https://github.com/thongtech/go-legacy-win7/releases/download/v$Ver/$zip"
$dest = Join-Path $env:RUNNER_TEMP $zip
curl.exe -sSL -o $dest $url
Expand-Archive -Path $dest -DestinationPath "C:\" -Force
"GOROOT=C:\go-legacy-win7" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"C:\go-legacy-win7\bin" | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
& "C:\go-legacy-win7\bin\go.exe" version
