$ErrorActionPreference = 'Stop'

$Repo = 'an1by/syncide'
$Version = $env:SYNCIDE_VERSION
$InstallDir = if ($env:SYNCIDE_INSTALL_DIR) {
    $env:SYNCIDE_INSTALL_DIR
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\syncide\bin'
}

$ArchRaw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$Arch = switch ($ArchRaw) {
    'arm64' { 'aarch64' }
    'x64'   { 'x86_64' }
    default {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
            'aarch64'
        } else {
            'x86_64'
        }
    }
}

$AssetName = "syncide-windows-$Arch.exe"
$BaseUrl = if ($Version) {
    $Tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    "https://github.com/$Repo/releases/download/$Tag"
} else {
    "https://github.com/$Repo/releases/latest/download"
}

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("syncide-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    $TmpExe = Join-Path $TmpDir $AssetName
    $TmpSums = Join-Path $TmpDir 'SHA256SUMS.txt'

    Write-Host "Downloading $AssetName..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$BaseUrl/$AssetName" -OutFile $TmpExe -UseBasicParsing
    Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS.txt" -OutFile $TmpSums -UseBasicParsing

    $ExpectedLine = Get-Content $TmpSums | Where-Object { $_ -match "\s$([Regex]::Escape($AssetName))$" } | Select-Object -First 1
    if (-not $ExpectedLine) {
        throw "Checksum entry for $AssetName not found in SHA256SUMS.txt"
    }
    $ExpectedHash = ($ExpectedLine -split '\s+')[0].ToLowerInvariant()
    $ActualHash = (Get-FileHash -Path $TmpExe -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($ActualHash -ne $ExpectedHash) {
        throw "SHA256 mismatch for $AssetName (expected $ExpectedHash, got $ActualHash)"
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $DestExe = Join-Path $InstallDir 'syncide.exe'
    Move-Item -Path $TmpExe -Destination $DestExe -Force

    $NormInstall = $InstallDir.TrimEnd('\')
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $Entries = if ($UserPath) { $UserPath -split ';' | Where-Object { $_ -ne '' } } else { @() }
    $AlreadyInUserPath = $false
    foreach ($Entry in $Entries) {
        if ($Entry.TrimEnd('\').Equals($NormInstall, [StringComparison]::OrdinalIgnoreCase)) {
            $AlreadyInUserPath = $true
            break
        }
    }

    if (-not $AlreadyInUserPath -and -not $env:SYNCIDE_NO_MODIFY_PATH) {
        $NewUserPath = if ($UserPath -and $UserPath.Trim().Length -gt 0) {
            "$($UserPath.TrimEnd(';'));$InstallDir"
        } else {
            $InstallDir
        }
        [Environment]::SetEnvironmentVariable('Path', $NewUserPath, 'User')
        Write-Host "Added $InstallDir to User PATH." -ForegroundColor Green
    }

    $SessionEntries = $env:Path -split ';'
    $InSession = $false
    foreach ($Entry in $SessionEntries) {
        if ($Entry.TrimEnd('\').Equals($NormInstall, [StringComparison]::OrdinalIgnoreCase)) {
            $InSession = $true
            break
        }
    }
    if (-not $InSession) {
        $env:Path = "$InstallDir;$env:Path"
    }

    Write-Host "Installed syncide -> $DestExe" -ForegroundColor Green
    Write-Host "Run 'syncide status' or 'syncide init' to start." -ForegroundColor Cyan
} finally {
    Remove-Item -Recurse -Force -Path $TmpDir -ErrorAction SilentlyContinue
}
