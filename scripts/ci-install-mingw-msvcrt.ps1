# CI：安装 MSVCRT MinGW（Win7 安全 CGO；去 libwinpthread/libpthread 导入库以免动态依赖）。
$ErrorActionPreference = "Stop"
$url = "https://github.com/niXman/mingw-builds-binaries/releases/download/15.2.0-rt_v13-rev1/x86_64-15.2.0-release-win32-seh-msvcrt-rt_v13-rev1.7z"
$dest = Join-Path $env:RUNNER_TEMP "mingw.7z"
curl.exe -sSL -o $dest $url
7z x $dest -o"C:\mingw-msvcrt" | Out-Null
Get-ChildItem -Path "C:\mingw-msvcrt" -Recurse -Filter "libwinpthread.dll.a" -ErrorAction SilentlyContinue |
  ForEach-Object { Remove-Item -Force $_.FullName }
Get-ChildItem -Path "C:\mingw-msvcrt" -Recurse -Filter "libpthread.dll.a" -ErrorAction SilentlyContinue |
  ForEach-Object { Remove-Item -Force $_.FullName }
"C:\mingw-msvcrt\mingw64\bin" | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
& "C:\mingw-msvcrt\mingw64\bin\gcc.exe" --version
