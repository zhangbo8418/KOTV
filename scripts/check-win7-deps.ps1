# Win7 SP1 依赖门禁：扫描 KOTV.exe（含 CGO/QuickJS）动态库依赖。
# 用法:
#   pwsh scripts/check-win7-deps.ps1 -Exe path\to\KOTV.exe
param(
    [Parameter(Mandatory = $true)]
    [string]$Exe
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Exe)) {
    throw "File not found: $Exe"
}

Write-Host "==> Win7 gate: scanning $Exe"

# 只收集 DLL 依赖名。勿 dump 完整 objdump -p（会刷出成百上千行 reloc DIR64）。
$dllNames = New-Object System.Collections.Generic.List[string]

if (Get-Command dumpbin -ErrorAction SilentlyContinue) {
    $raw = & dumpbin /DEPENDENTS $Exe 2>&1 | Out-String
    foreach ($m in [regex]::Matches($raw, "(?im)^\s+([A-Za-z0-9_\-\.]+\.dll)\s*$")) {
        $dllNames.Add($m.Groups[1].Value) | Out-Null
    }
} elseif (Get-Command objdump -ErrorAction SilentlyContinue) {
    # -x 也很大；用 -p 但只保留 DLL Name 行
    $lines = & objdump -p $Exe 2>&1
    foreach ($line in $lines) {
        if ($line -match '(?i)DLL Name:\s*(\S+)') {
            $dllNames.Add($Matches[1]) | Out-Null
        }
    }
} else {
    Write-Warning "Neither dumpbin nor objdump found; skip detailed scan (ensure MSVCRT MinGW + Win7 CGO flags were used)."
    exit 0
}

$depsText = ($dllNames | Select-Object -Unique) -join "`n"
Write-Host "DLL dependents:"
if ([string]::IsNullOrWhiteSpace($depsText)) {
    Write-Warning "No DLL names parsed; dumping first 30 matching lines for debug."
} else {
    Write-Host $depsText
}

$hardFail = @(
    "VCRUNTIME140",
    "VCRUNTIME140_1",
    "MSVCP140",
    "MSVCR1",
    "CONCRT140",
    "api-ms-win-core-path-l1-1-0",
    "ucrtbase.dll",
    "api-ms-win-crt-",
    "libwinpthread",
    "libgcc_s",
    "libstdc++"
)

foreach ($pat in $hardFail) {
    if ($depsText -match [regex]::Escape($pat)) {
        throw "Win7 gate failed: EXE depends on '$pat' (QuickJS/CGO must use MSVCRT MinGW + static-libgcc; see package.sh)."
    }
}

$apiMatches = [regex]::Matches($depsText, "api-ms-win-[A-Za-z0-9\-]+\.dll", "IgnoreCase")
foreach ($m in $apiMatches) {
    $name = $m.Value.ToLowerInvariant()
    Write-Warning "Win7 gate: unexpected API set dependency: $($m.Value)"
    if ($name -match "core-path|core-realtime|core-winrt|appmodel") {
        throw "Win7 gate failed: disallowed API set $($m.Value)"
    }
}

Write-Host "==> Win7 dependency gate passed (QuickJS/CGO)"
