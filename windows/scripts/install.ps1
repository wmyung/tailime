# TailIME Windows Installer Script (for portable TailIME-*-windows-x64.zip)
# Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [-NoStartup] [-NoLaunch] [-AddFirewall]
param(
    [switch]$NoStartup,
    [switch]$NoLaunch,
    [switch]$AddFirewall
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA "TailIME"

$SrcApp = Join-Path $ScriptDir "TailIME.exe"
$SrcCtl = Join-Path $ScriptDir "tailime-ctl.exe"
if (-not (Test-Path $SrcApp) -or -not (Test-Path $SrcCtl)) {
    Write-Error "TailIME.exe 또는 tailime-ctl.exe를 찾을 수 없습니다."
    exit 1
}

# Remove Mark-of-the-Web on extracted files if present
Get-ChildItem -Path $ScriptDir -File | Unblock-File -ErrorAction SilentlyContinue

# Gracefully stop any running TailIME
$ExistingCtl = Join-Path $InstallDir "tailime-ctl.exe"
if (Test-Path $ExistingCtl) {
    & $ExistingCtl quit 2>$null | Out-Null
    Start-Sleep -Milliseconds 400
}
Get-Process -Name "TailIME" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force $SrcApp (Join-Path $InstallDir "TailIME.exe")
Copy-Item -Force $SrcCtl (Join-Path $InstallDir "tailime-ctl.exe")
foreach ($doc in @("README.ko.md", "README.md", "LICENSE", "uninstall.ps1")) {
    $src = Join-Path $ScriptDir $doc
    if (Test-Path $src) {
        Copy-Item -Force $src (Join-Path $InstallDir $doc)
    }
}

# Start Menu shortcut
$LnkPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\TailIME.lnk"
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($LnkPath)
$Shortcut.TargetPath = Join-Path $InstallDir "TailIME.exe"
$Shortcut.WorkingDirectory = $InstallDir
$Shortcut.Description = "TailIME — Tailscale Korean/English Sync"
$Shortcut.Save()

# Startup registry (HKCU)
if (-not $NoStartup) {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "TailIME" -Value "`"$(Join-Path $InstallDir 'TailIME.exe')`""
}

# Safely append to User PATH via Registry (never setx)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$Parts = @()
if ($UserPath) { $Parts = $UserPath -split ";" | Where-Object { $_.Trim() -ne "" } }
if (-not ($Parts | Where-Object { $_.TrimEnd("\") -ieq $InstallDir.TrimEnd("\") })) {
    $NewPath = (($Parts + $InstallDir) -join ";")
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
}

# Optional scoped Windows Defender Firewall rule (requires Administrator)
if ($AddFirewall) {
    $AppExe = Join-Path $InstallDir "TailIME.exe"
    $NetshCmd = "netsh advfirewall firewall delete rule name=all program=`"$AppExe`"; netsh advfirewall firewall add rule name=`"TailIME (Tailscale UDP 39418)`" dir=in action=allow protocol=UDP localport=39418 remoteip=100.64.0.0/10,fd7a:115c:a1e0::/48 program=`"$AppExe`" profile=any enable=yes"
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile", "-Command", $NetshCmd -Wait
}

Write-Host "✓ TailIME Windows 설치 완료: $InstallDir" -ForegroundColor Green
Write-Host "  • 새 터미널에서 tailime-ctl status 사용 가능"
Write-Host "  • 방화벽 수동 허용(필요 시 관리자 PowerShell): .\install.ps1 -AddFirewall"

if (-not $NoLaunch) {
    Start-Process (Join-Path $InstallDir "TailIME.exe") -WorkingDirectory $InstallDir
}
