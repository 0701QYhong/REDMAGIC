param([string]$Out)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot "check.ps1")
if ($LASTEXITCODE -ne 0) { throw "check failed, zip not built" }

$ver = ([regex]::Match((Get-Content (Join-Path $root "module.prop") -Raw), "version=(\S+)").Groups[1].Value)
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (-not $Out) { $Out = Join-Path $dist "REDMAGIC-$ver.zip" }
if (Test-Path $Out) { Remove-Item -LiteralPath $Out }

$tmp = Join-Path $dist ("build-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Get-ChildItem $root -Force | Where-Object { $_.Name -notin "dist", ".git" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $tmp -Recurse -Force
    }

    # Compress-Archive on Windows writes backslash separators; Android unzip then
    # creates files literally named "lib\charge.sh" instead of directories.
    # Write the archive ourselves so every entry uses the ZIP-required "/".
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Out, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $base = $tmp.TrimEnd("\") + "\"
        Get-ChildItem -LiteralPath $tmp -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($base.Length).Replace("\", "/")
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($Out)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $bad = @($names | Where-Object { $_ -match '\\' })
        if ($bad.Count -gt 0) { throw "ZIP has backslash paths: $($bad[0])" }
        foreach ($req in "module.prop", "customize.sh", "service.sh", "webroot/index.html", "lib/charge.sh") {
            if ($names -notcontains $req) { throw "ZIP missing $req" }
        }
    } finally {
        $zip.Dispose()
    }
    Write-Host "[ OK ] zip layout" -ForegroundColor Green
} finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

Write-Host "output: $Out" -ForegroundColor Green
