& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $BaseLocal = if ($env:LOCALAPPDATA) {
        $env:LOCALAPPDATA
    } else {
        Join-Path $HOME 'AppData\Local'
    }
    $BaseRoaming = if ($env:APPDATA) {
        $env:APPDATA
    } else {
        Join-Path $HOME 'AppData\Roaming'
    }

    $InstallDir = if ($env:SYNCIDE_INSTALL_DIR) {
        $env:SYNCIDE_INSTALL_DIR
    } else {
        Join-Path $BaseLocal 'Programs\syncide\bin'
    }
    $ExePath = Join-Path $InstallDir 'syncide.exe'
    $DefaultStoreDir = Join-Path $BaseRoaming 'syncide'
    $BootstrapStatePath = Join-Path $DefaultStoreDir 'state.json'

    $CanRemoveStore = $true
    $CustomStoreDir = $null
    $HasManagedIdes = $false

    if (Test-Path $BootstrapStatePath) {
        try {
            $StateJson = Get-Content $BootstrapStatePath -Raw | ConvertFrom-Json
            if ($StateJson.storeDir) {
                $CustomStoreDir = [string]$StateJson.storeDir
            }
            if ($StateJson.managedIdeIds -and @($StateJson.managedIdeIds).Count -gt 0) {
                $HasManagedIdes = $true
            }
        } catch {
            $HasManagedIdes = $true
        }

        if ($HasManagedIdes) {
            $Runner = if (Test-Path $ExePath) {
                $ExePath
            } else {
                $CmdObj = Get-Command syncide -ErrorAction SilentlyContinue
                if ($CmdObj) { $CmdObj.Source } else { $null }
            }

            if ($Runner) {
                Write-Host "Detaching linked IDEs back into standalone copies ('syncide unlink all')..." -ForegroundColor Cyan
                & $Runner unlink all
                if ($LASTEXITCODE -ne 0) {
                    $CanRemoveStore = $false
                    Write-Warning "Could not detach all IDEs (close running IDEs first). Keeping store data intact to avoid broken links."
                }
            } else {
                $CanRemoveStore = $false
                Write-Warning "syncide binary not found to detach active links; keeping $DefaultStoreDir intact."
            }
        }
    }

    if (Test-Path $ExePath) {
        Remove-Item -Force -Path $ExePath
        Write-Host "Removed binary $ExePath" -ForegroundColor Green
    }

    $ParentAppDir = Split-Path -Parent $InstallDir
    if ((Test-Path $InstallDir) -and @(Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -Force -Path $InstallDir -ErrorAction SilentlyContinue
    }
    if ($ParentAppDir -and ($ParentAppDir -like "*\Programs\syncide") -and (Test-Path $ParentAppDir) -and @(Get-ChildItem $ParentAppDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -Force -Path $ParentAppDir -ErrorAction SilentlyContinue
    }

    if (-not $env:SYNCIDE_NO_MODIFY_PATH) {
        $NormInstall = ([string]$InstallDir).TrimEnd('\')
        $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($UserPath) {
            $Filtered = @(
                $UserPath -split ';' | Where-Object {
                    $_ -and (-not $_.TrimEnd('\').Equals($NormInstall, [StringComparison]::OrdinalIgnoreCase))
                }
            )
            $NextUserPath = $Filtered -join ';'
            if ($NextUserPath -ne $UserPath) {
                [Environment]::SetEnvironmentVariable('Path', $NextUserPath, 'User')
                Write-Host "Removed $InstallDir from User PATH." -ForegroundColor Green
            }
        }

        if ($env:Path) {
            $SessionFiltered = @(
                $env:Path -split ';' | Where-Object {
                    $_ -and (-not $_.TrimEnd('\').Equals($NormInstall, [StringComparison]::OrdinalIgnoreCase))
                }
            )
            $env:Path = $SessionFiltered -join ';'
        }
    }

    if ($CanRemoveStore -and (-not $env:SYNCIDE_KEEP_DATA)) {
        if ($CustomStoreDir -and (Test-Path $CustomStoreDir)) {
            Remove-Item -Recurse -Force -Path $CustomStoreDir
            Write-Host "Removed store directory $CustomStoreDir" -ForegroundColor Green
        }
        if (Test-Path $DefaultStoreDir) {
            Remove-Item -Recurse -Force -Path $DefaultStoreDir
            Write-Host "Removed config directory $DefaultStoreDir" -ForegroundColor Green
        }
    }

    Write-Host "syncide uninstalled." -ForegroundColor Green
}
