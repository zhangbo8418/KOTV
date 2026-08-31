# 检查 mpv-2.dll 及传递依赖（无需 dumpbin / VS）。
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-windows-mpv-deps.ps1 -Dir "F:\Program Files\KO影视"
param(
    [string]$Dir = ""
)

$ErrorActionPreference = "Stop"

function Get-ExeDir {
    param([string]$Hint)
    if ($Hint -and (Test-Path -LiteralPath $Hint)) {
        if ((Get-Item -LiteralPath $Hint).PSIsContainer) { return (Resolve-Path -LiteralPath $Hint).Path }
        return (Split-Path -Parent (Resolve-Path -LiteralPath $Hint).Path)
    }
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidates = @(
        (Join-Path $here "..\flutter\build\windows\x64\runner\Release"),
        (Join-Path $here "..")
    )
    foreach ($c in $candidates) {
        $p = (Resolve-Path -LiteralPath $c -ErrorAction SilentlyContinue)
        if ($p -and (Test-Path -LiteralPath (Join-Path $p "mpv-2.dll"))) { return $p.Path }
    }
    return (Get-Location).Path
}

function Test-SystemDll([string]$Name) {
    $n = $Name.ToLowerInvariant()
    if ($n.StartsWith("api-ms-") -or $n.StartsWith("ext-ms-")) { return $true }
    $sys = @(
        "kernel32.dll","user32.dll","gdi32.dll","gdiplus.dll","advapi32.dll","shell32.dll","ole32.dll","oleaut32.dll",
        "ws2_32.dll","winmm.dll","dwmapi.dll","d3d9.dll","d3d11.dll","d3d12.dll","dxgi.dll","dxva2.dll",
        "opengl32.dll","ntdll.dll","msvcrt.dll","ucrtbase.dll","vcruntime140.dll","vcruntime140_1.dll",
        "sechost.dll","rpcrt4.dll","comdlg32.dll","comctl32.dll","shlwapi.dll","crypt32.dll","bcrypt.dll",
        "iphlpapi.dll","setupapi.dll","version.dll","imm32.dll","oleacc.dll","psapi.dll","dbghelp.dll",
        "avicap32.dll","avrt.dll","ncrypt.dll","secur32.dll","uxtheme.dll","dnsapi.dll","normaliz.dll",
        "winhttp.dll","wininet.dll","mfplat.dll","mf.dll","mfreadwrite.dll","powrprof.dll","wtsapi.dll",
        "cfgmgr32.dll","userenv.dll","kernelbase.dll"
    )
    return $sys -contains $n
}

function Test-MustBundleDll([string]$Name) {
    $n = $Name.ToLowerInvariant()
    return ($n -eq "vulkan-1.dll")
}

function Test-Win7IncompatibleImport([string]$Name) {
    $n = $Name.ToLowerInvariant()
    # Win7 无 SHCORE.dll（Win8+）；mpv 若 import 它会在 Win7 上 winerr=126
    return ($n -eq "shcore.dll")
}

function Get-PeImports([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) { throw "file too small: $Path" }
    $e = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($bytes[$e] -ne 0x50 -or $bytes[$e + 1] -ne 0x45) { throw "not a PE file: $Path" }
    $magic = [BitConverter]::ToUInt16($bytes, $e + 24)
    if ($magic -ne 0x20b) { throw "only PE32+ supported (need x64 mpv-2.dll)" }
    $numSections = [BitConverter]::ToUInt16($bytes, $e + 6)
    $optSize = [BitConverter]::ToUInt16($bytes, $e + 20)
    $secOff = $e + 24 + $optSize
    $opt = $e + 24
    # DataDirectory[1]=IMPORT @112+8, [13]=DELAY_IMPORT @112+104
    $importRva = [BitConverter]::ToUInt32($bytes, $opt + 120)
    $delayRva = [BitConverter]::ToUInt32($bytes, $opt + 216)

    function RvaToOffset([uint32]$Rva) {
        for ($i = 0; $i -lt $numSections; $i++) {
            $so = $secOff + ($i * 40)
            $va = [BitConverter]::ToUInt32($bytes, $so + 12)
            $vs = [BitConverter]::ToUInt32($bytes, $so + 8)
            $raw = [BitConverter]::ToUInt32($bytes, $so + 20)
            if ($Rva -ge $va -and $Rva -lt ($va + $vs)) {
                return [int]($Rva - $va + $raw)
            }
        }
        return -1
    }

    function ReadDllNames([uint32]$Rva) {
        $names = New-Object System.Collections.Generic.List[string]
        if ($Rva -eq 0) { return $names }
        $off = RvaToOffset $Rva
        if ($off -lt 0) { return $names }
        $idx = $off
        while ($true) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $idx + 12)
            if ($nameRva -eq 0) { break }
            $no = RvaToOffset $nameRva
            if ($no -ge 0) {
                $end = $no
                while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
                $s = [System.Text.Encoding]::ASCII.GetString($bytes, $no, $end - $no)
                if ($s) { $names.Add($s) | Out-Null }
            }
            $idx += 20
        }
        return $names
    }

    function ReadDelayNames([uint32]$Rva) {
        $names = New-Object System.Collections.Generic.List[string]
        if ($Rva -eq 0) { return $names }
        $off = RvaToOffset $Rva
        if ($off -lt 0) { return $names }
        $idx = $off
        while ($true) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $idx + 4)
            if ($nameRva -eq 0) { break }
            $no = RvaToOffset $nameRva
            if ($no -ge 0) {
                $end = $no
                while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
                $s = [System.Text.Encoding]::ASCII.GetString($bytes, $no, $end - $no)
                if ($s) { $names.Add($s) | Out-Null }
            }
            $idx += 32
        }
        return $names
    }

    $all = New-Object System.Collections.Generic.List[string]
    foreach ($n in (ReadDllNames $importRva)) { $all.Add($n) | Out-Null }
    foreach ($n in (ReadDelayNames $delayRva)) { $all.Add($n) | Out-Null }
    return ($all | Select-Object -Unique)
}

function Get-ClosureMissing([string]$RootDir, [string]$StartDll) {
    $missing = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $queue = @($StartDll)
    while ($queue.Count -gt 0) {
        $name = $queue[0]
        $queue = $queue[1..($queue.Count - 1)]
        if (-not $name) { continue }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-SystemDll $name) { continue }
        $path = Join-Path $RootDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            $missing.Add($name) | Out-Null
            continue
        }
        foreach ($dep in (Get-PeImports $path)) {
            if (Test-SystemDll $dep) { continue }
            $dk = $dep.ToLowerInvariant()
            if (-not $seen.ContainsKey($dk)) { $queue += $dep }
        }
    }
    return ($missing | Select-Object -Unique)
}

$dir = Get-ExeDir $Dir
$mpv = Join-Path $dir "mpv-2.dll"
if (-not (Test-Path -LiteralPath $mpv)) {
    Write-Error "mpv-2.dll not found in: $dir"
}

$win7Bad = @()
Write-Host "==> check mpv deps in: $dir"
Write-Host "(带 SYS 的是 Windows 系统 DLL，在 System32，不用复制到安装目录)"
Write-Host ""

$imports = @(Get-PeImports $mpv)
$sysImports = @()
$bundleImports = @()
$otherImports = @()
foreach ($dll in ($imports | Where-Object { -not (Test-SystemDll $_) } | Sort-Object)) {
    if (Test-Win7IncompatibleImport $dll) { $win7Bad += $dll; continue }
    if (Test-MustBundleDll $dll) { $bundleImports += $dll; continue }
    if (Test-Path -LiteralPath (Join-Path $dir $dll)) { $otherImports += $dll }
    else { $sysImports += $dll }
}

Write-Host "=== 需要处理（安装目录） ==="
$directMissing = @()
foreach ($dll in $bundleImports) {
    if (Test-Path -LiteralPath (Join-Path $dir $dll)) {
        Write-Host ("  [OK] {0} (随安装包)" -f $dll)
    } else {
        Write-Host ("  [缺] {0} (须与 mpv-2.dll 同目录)" -f $dll)
        $directMissing += $dll
    }
}
foreach ($dll in $win7Bad) {
    Write-Host ("  [Win7阻断] {0} (Win7 无此系统库，需重编 mpv)" -f $dll)
}
if ($bundleImports.Count -eq 0 -and $win7Bad.Count -eq 0) {
    Write-Host "  (无必须捆绑项；看下方传递依赖)"
}

if ($sysImports.Count -gt 0) {
    Write-Host ""
    Write-Host "=== 系统 DLL（正常，不用管） ==="
    $sysImports | ForEach-Object { Write-Host ("  [SYS] {0}" -f $_) }
}
if ($otherImports.Count -gt 0) {
    Write-Host ""
    Write-Host "=== 已在目录的非系统 DLL ==="
    $otherImports | ForEach-Object { Write-Host ("  [OK] {0}" -f $_) }
}

# 旧版详细列表（调试用）
if ($env:KOTV_MPV_DEPS_VERBOSE -eq "1") {
    Write-Host ""
    Write-Host "mpv-2.dll direct imports (verbose):"
    foreach ($dll in ($imports | Where-Object { -not (Test-SystemDll $_) } | Sort-Object)) {
        Write-Host ("  {0}" -f $dll)
    }
}

$placeboImports = $imports | Where-Object { $_ -like "libplacebo*" }
$placeboFiles = Get-ChildItem -LiteralPath $dir -Filter "libplacebo*.dll" -ErrorAction SilentlyContinue
if ($placeboImports -and $placeboFiles) {
    foreach ($imp in $placeboImports) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $imp))) {
            Write-Host ""
            Write-Host "WARN: libplacebo name mismatch"
            Write-Host "  mpv imports : $imp"
            Write-Host "  dir has     : $($placeboFiles.Name -join ', ')"
        }
    }
}

Write-Host ""
Write-Host "transitive closure (mpv chain):"
$closureMissing = @(Get-ClosureMissing $dir "mpv-2.dll")
if ($closureMissing.Count -eq 0) {
    Write-Host "  all non-system deps present in folder"
} else {
    foreach ($m in ($closureMissing | Sort-Object)) {
        Write-Host ("  [MISSING] {0}" -f $m)
    }
}

$vulkan = Join-Path $dir "vulkan-1.dll"
Write-Host ""
if (Test-Path -LiteralPath $vulkan) {
    Write-Host "[OK] vulkan-1.dll"
} else {
    Write-Host "[MISSING] vulkan-1.dll  <-- libplacebo usually needs this (winerr=126)"
}

Write-Host ""
Write-Host "dll files in folder:"
Get-ChildItem -LiteralPath $dir -Filter "*.dll" | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }

$allMissing = @($directMissing + $closureMissing) | Select-Object -Unique
if ($win7Bad.Count -gt 0) {
    Write-Host ""
    Write-Host "WIN7 BLOCKER: mpv-2.dll imports SHCORE.dll (Windows 8+ only)."
    Write-Host "  On Win7 LoadLibrary fails with winerr=126 even if vulkan-1.dll is present."
    Write-Host "  Need a Win7-targeted mpv rebuild (_WIN32_WINNT=0x0601)."
    exit 2
}

if ($allMissing.Count -gt 0) {
    Write-Host ""
    Write-Host "SUMMARY - fix these (likely winerr=126):"
    $allMissing | Sort-Object | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
Write-Host "==> dependency closure looks complete"
exit 0
