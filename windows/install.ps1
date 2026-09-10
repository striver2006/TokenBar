# install.ps1 - TokenBar Windows Installer
[CmdletBinding()]
param (
    [switch]$CreateDesktopShortcut,
    [switch]$LaunchAfterInstall
)

$ErrorActionPreference = "Stop"

$appName = "TokenBar"
$publishExe = Join-Path $PSScriptRoot "publish\TokenBar.exe"

if (-not (Test-Path $publishExe)) {
    $candidate = Join-Path $PSScriptRoot "windows\publish\TokenBar.exe"
    if (Test-Path $candidate) {
        $publishExe = $candidate
    } else {
        throw "Cannot find compiled executable at: $publishExe. Please compile TokenBar first."
    }
}

$installDir = Join-Path $env:LOCALAPPDATA "Programs\$appName"
Write-Host "Installing $appName to: $installDir" -ForegroundColor Cyan

# 1. Stop running instances if any
$running = Get-Process -Name $appName -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Stopping running instance of $appName..." -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Seconds 1
}

# 2. Ensure target directory exists
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# 3. Copy executable
$targetExe = Join-Path $installDir "$appName.exe"
Copy-Item -Path $publishExe -Destination $targetExe -Force
Write-Host "Copied $appName.exe successfully." -ForegroundColor Green

# 4. Create uninstall script in install directory
$uninstallScript = @"
# uninstall.ps1 - TokenBar Uninstaller
`$appName = "TokenBar"
`$installDir = Join-Path `$env:LOCALAPPDATA "Programs\`$appName"

Write-Host "Uninstalling `$appName..." -ForegroundColor Cyan

# Stop running process
Get-Process -Name `$appName -ErrorAction SilentlyContinue | Stop-Process -Force

# Remove shortcuts
`$startMenuShortcut = Join-Path "`$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "`$appName.lnk"
if (Test-Path `$startMenuShortcut) { Remove-Item `$startMenuShortcut -Force }

`$desktopShortcut = Join-Path "`$env:USERPROFILE\Desktop" "`$appName.lnk"
if (Test-Path `$desktopShortcut) { Remove-Item `$desktopShortcut -Force }

# Remove Registry entries
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\`$appName.exe" -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\`$appName" -ErrorAction SilentlyContinue

# Remove install directory
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 >nul & rmdir /s /q `"`$installDir`"" -WindowStyle Hidden
Write-Host "`$appName has been successfully uninstalled." -ForegroundColor Green
"@

Set-Content -Path (Join-Path $installDir "uninstall.ps1") -Value $uninstallScript -Encoding UTF8

# 5. Create Start Menu Shortcut
$wscriptShell = New-Object -ComObject WScript.Shell
$startMenuDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
$startMenuShortcutPath = Join-Path $startMenuDir "$appName.lnk"

$shortcut = $wscriptShell.CreateShortcut($startMenuShortcutPath)
$shortcut.TargetPath = $targetExe
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = "TokenBar - 模型额度监控 / Model Quota Monitor"
$shortcut.Save()
Write-Host "Created Start Menu shortcut at: $startMenuShortcutPath" -ForegroundColor Green

# 6. Optional Desktop Shortcut
if ($CreateDesktopShortcut) {
    $desktopDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $desktopShortcutPath = Join-Path $desktopDir "$appName.lnk"
    $dShortcut = $wscriptShell.CreateShortcut($desktopShortcutPath)
    $dShortcut.TargetPath = $targetExe
    $dShortcut.WorkingDirectory = $installDir
    $dShortcut.Description = "TokenBar - 模型额度监控 / Model Quota Monitor"
    $dShortcut.Save()
    Write-Host "Created Desktop shortcut at: $desktopShortcutPath" -ForegroundColor Green
}

# 7. Register App Paths in Registry (enables `Win+R -> TokenBar` or cmd/powershell `TokenBar`)
$appPathsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\$appName.exe"
if (-not (Test-Path $appPathsKey)) {
    New-Item -Path $appPathsKey -Force | Out-Null
}
Set-ItemProperty -Path $appPathsKey -Name "(Default)" -Value $targetExe
Set-ItemProperty -Path $appPathsKey -Name "Path" -Value $installDir

# 8. Register in Windows Add/Remove Programs
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appName"
if (-not (Test-Path $uninstallKey)) {
    New-Item -Path $uninstallKey -Force | Out-Null
}
Set-ItemProperty -Path $uninstallKey -Name "DisplayName" -Value "$appName - 模型额度监控"
# 版本号单源：从 exe 的 FileVersionInfo 读取（来自 TokenBar.csproj 的 <Version>），不再手写
$versionInfo = (Get-Item $targetExe).VersionInfo
$displayVersion = if ($versionInfo.ProductVersion) { ($versionInfo.ProductVersion -split '\+')[0] } else { $versionInfo.FileVersion }
if (-not $displayVersion) { $displayVersion = "0.0.0" }
Set-ItemProperty -Path $uninstallKey -Name "DisplayVersion" -Value $displayVersion
Set-ItemProperty -Path $uninstallKey -Name "Publisher" -Value "TokenBar Team"
Set-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $installDir
Set-ItemProperty -Path $uninstallKey -Name "DisplayIcon" -Value "$targetExe,0"
Set-ItemProperty -Path $uninstallKey -Name "UninstallString" -Value "powershell.exe -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`""
Set-ItemProperty -Path $uninstallKey -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name "NoRepair" -Value 1 -Type DWord

# 9. Promote icon in Windows 11 NotifyIconSettings if entry exists
Get-ChildItem "HKCU:\Control Panel\NotifyIconSettings" -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PsPath
    if ($p.ExecutablePath -like "*TokenBar.exe*") {
        Set-ItemProperty -Path $_.PsPath -Name "IsPromoted" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    }
}

Write-Host "`nInstallation completed successfully!" -ForegroundColor Green
Write-Host "You can launch TokenBar from:"
Write-Host "  - Windows Start Menu: Search 'TokenBar'"
Write-Host "  - Run dialog (Win+R): Type 'TokenBar'"
Write-Host "  - Desktop shortcut: TokenBar.lnk"
Write-Host "  - File location: $targetExe"

if ($LaunchAfterInstall) {
    Write-Host "`nLaunching $appName..." -ForegroundColor Cyan
    $futureTime = (Get-Date).AddMinutes(2).ToString("HH:mm")
    schtasks /create /tn "TokenBarLauncher" /tr "`"$targetExe`"" /sc once /st $futureTime /f | Out-Null
    schtasks /run /tn "TokenBarLauncher" | Out-Null
    Start-Sleep -Seconds 1
    schtasks /delete /tn "TokenBarLauncher" /f | Out-Null
}
