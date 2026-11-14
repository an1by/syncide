& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $Repo = 'an1by/syncide'
    $Version = $env:SYNCIDE_VERSION
    $BaseLocal = if ($env:LOCALAPPDATA) {
        $env:LOCALAPPDATA
    } else {
        Join-Path $HOME 'AppData\Local'
    }
    $InstallDir = if ($env:SYNCIDE_INSTALL_DIR) {
        $env:SYNCIDE_INSTALL_DIR
    } else {
        Join-Path $BaseLocal 'Programs\syncide\bin'
    }

    $ProcArch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    $Arch = if ($ProcArch -eq 'ARM64') {
        'aarch64'
    } else {
        'x86_64'
    }

    $AssetName = "syncide-windows-$Arch.exe"
    $BaseUrl = if ($Version) {
        $Tag = if ($Version -like 'v*') { $Version } else { "v$Version" }
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
        $ExpectedHash = ([string]($ExpectedLine -split '\s+')[0]).ToLowerInvariant()
        $ActualHash = ([string](Get-FileHash -Path $TmpExe -Algorithm SHA256).Hash).ToLowerInvariant()

        if ($ActualHash -ne $ExpectedHash) {
            throw "SHA256 mismatch for $AssetName (expected $ExpectedHash, got $ActualHash)"
        }

        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $DestExe = Join-Path $InstallDir 'syncide.exe'
        Move-Item -Path $TmpExe -Destination $DestExe -Force

        if (-not $env:SYNCIDE_NO_MODIFY_PATH) {
            $NormInstall = ([string]$InstallDir).TrimEnd('\')
            $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $Entries = if ($UserPath) { $UserPath -split ';' } else { @() }
            $AlreadyInUserPath = $false
            foreach ($Entry in $Entries) {
                if ($Entry -and $Entry.TrimEnd('\').Equals($NormInstall, [StringComparison]::OrdinalIgnoreCase)) {
                    $AlreadyInUserPath = $true
                    break
                }
            }

            if (-not $AlreadyInUserPath) {
                $NewUserPath = if ($UserPath -and $UserPath.Trim().Length -gt 0) {
                    "$($UserPath.TrimEnd(';'));$InstallDir"
                } else {
                    $InstallDir
                }
                [Environment]::SetEnvironmentVariable('Path', $NewUserPath, 'User')
                Write-Host "Added $InstallDir to User PATH." -ForegroundColor Green
            }
        }

        $NormSession = ([string]$InstallDir).TrimEnd('\')
        $SessionEntries = if ($env:Path) { $env:Path -split ';' } else { @() }
        $InSession = $false
        foreach ($Entry in $SessionEntries) {
            if ($Entry -and $Entry.TrimEnd('\').Equals($NormSession, [StringComparison]::OrdinalIgnoreCase)) {
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
}
