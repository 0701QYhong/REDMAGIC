param(
    [string]$Adb = "C:\Program Files (x86)\platform-tools\adb.exe",
    [switch]$SkipDevice
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Ok($msg) { Write-Host "[ OK ] $msg" -ForegroundColor Green }

# 1) JS syntax
Get-ChildItem (Join-Path $root "webroot\js") -Filter *.js | ForEach-Object {
    node --check $_.FullName
    if ($LASTEXITCODE -ne 0) { Fail "node --check $($_.Name)" } else { Ok "js $($_.Name)" }
}

# 2) CRLF
Get-ChildItem $root -Recurse -File | Where-Object {
    $_.Extension -in ".sh", ".txt", ".js", ".html", ".css", ".prop", ".req", ".md", ".ps1"
} | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    for ($i = 0; $i -lt $b.Length - 1; $i++) {
        if ($b[$i] -eq 13 -and $b[$i + 1] -eq 10) { Fail "CRLF: $($_.FullName)"; break }
    }
}

# 3) Contract checks
$status = Get-Content (Join-Path $root "lib\status.sh") -Raw
$touch = Get-Content (Join-Path $root "lib\touch.sh") -Raw
if ($status -match '(?m)^touch_key\(\)') { Fail "status.sh redefines touch_key" } else { Ok "touch_key single definition" }
if ($status -match '(?m)^touch_vals_string\(\)') { Fail "status.sh redefines touch_vals_string" } else { Ok "touch_vals_string single definition" }
if ($touch -match 'rd "\$TP_DIR/edge_report_limit"') { Fail "touch.sh still reads edge_report_limit with 64-byte rd" } else { Ok "edge_report_limit full read" }

$prop = Get-Content (Join-Path $root "module.prop") -Raw
$ver = [regex]::Match($prop, "version=(\S+)").Groups[1].Value
$vtxt = (Get-Content (Join-Path $root "webroot\version.txt") -Raw).Trim()
if ($ver -ne $vtxt) { Fail "version mismatch: $ver / $vtxt" } else { Ok "version $ver" }
if (Test-Path (Join-Path $root "install.sh")) {
    Fail "install.sh is reserved by KernelSU and would bypass customize.sh"
} else {
    Ok "no legacy install.sh"
}

# 4) Android sh syntax (needs a connected device)
if (-not $SkipDevice -and (Test-Path $Adb)) {
    $dev = & $Adb get-state 2>$null
    if ($dev -eq "device") {
        Get-ChildItem $root -Recurse -Filter *.sh | ForEach-Object {
            $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
            $r = & $Adb shell "echo $b64 | base64 -d | sh -n" 2>&1
            if ($LASTEXITCODE -ne 0) { Fail "sh -n $($_.Name): $r" } else { Ok "sh $($_.Name)" }
        }
    } else { Write-Host "[SKIP] no device, sh -n skipped" -ForegroundColor Yellow }
}

if ($fail -gt 0) { Write-Host "`n$fail failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall checks passed" -ForegroundColor Green
