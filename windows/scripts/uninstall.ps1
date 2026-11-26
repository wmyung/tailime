# TailIME Windows Uninstaller Script
param(
    [switch]$Purge
)

$ErrorActionPreference = "SilentlyContinue"
$InstallDir = Join-Path $env:LOCALAPPDATA "TailIME"

$ExistingCtl = Join-Path $InstallDir "tailime-ctl.exe"
if (Test-Path $ExistingCtl) {
    & $ExistingCtl quit 2>$null | Out-Null
    Start-Sleep -Milliseconds 400
}
Get-Process -Name "TailIME" | Stop-Process -Force
Start-Sleep -Milliseconds 300

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "TailIME"
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TailIME" -Recurse -Force
Remove-Item -Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\TailIME.lnk") -Force

$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath) {
    $Filtered = ($UserPath -split ";" | Where-Object { $_.Trim() -ne "" -and $_.TrimEnd("\") -ine $InstallDir.TrimEnd("\") }) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $Filtered, "User")
}

$Files = @("TailIME.exe", "tailime-ctl.exe", "TailIME-Uninstall.exe", "README.ko.md", "README.md", "LICENSE", "ctl.json", "uninstall.ps1")
if ($Purge) {
    $Files += @("identity.dpapi", "settings.json", "trusted_peers.json")
}
foreach ($f in $Files) {
    Remove-Item -Path (Join-Path $InstallDir $f) -Force
}
if ($Purge) {
    Remove-Item -Path $InstallDir -Force
}

Write-Host "✓ TailIME Windows 제거 완료" -ForegroundColor Green
