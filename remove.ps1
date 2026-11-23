$ErrorActionPreference = "Stop"

# Tự động nâng quyền Administrator nếu chưa chạy với quyền Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Dang yeu cau quyen Administrator..." -ForegroundColor Yellow
    $encCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($MyInvocation.MyCommand.Definition))
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encCmd" -Verb RunAs
    exit
}

Write-Host "=====================================================" -ForegroundColor Red
Write-Host "   GRUB4EFI BOOT STUDIO - GO BO KHOI MENU WINDOWS" -ForegroundColor Red
Write-Host "=====================================================" -ForegroundColor Red

$bcdText = bcdedit /enum all | Out-String
foreach ($b in ($bcdText -split "(`r?`n){2,}")) {
    if ($b -match "Grub4EFI" -or $b -match "\\EFI\\Grub4EFI\\") {
        $m = [regex]::Match($b, "\{[0-9a-fA-F-]{36}\}")
        if ($m.Success -and $m.Value -ne "{bootmgr}" -and $m.Value -ne "{current}") {
            bcdedit /delete $m.Value /f | Out-Null
            Write-Host "[DA XOA BCD] $($m.Value)" -ForegroundColor Green
        }
    }
}

$mountDrive = "S:"
if (-not (Test-Path $mountDrive)) {
    mountvol $mountDrive /S
    try {
        if (Test-Path "$mountDrive\EFI\Grub4EFI") {
            Remove-Item "$mountDrive\EFI\Grub4EFI" -Recurse -Force
            Write-Host "[DA DON EFI] Da xoa thu muc \EFI\Grub4EFI." -ForegroundColor Green
        }
    } finally {
        mountvol $mountDrive /D | Out-Null
    }
}

Write-Host "[HOAN TAT] Da go bo sach se Grub4EFI khoi he thong!" -ForegroundColor Green
Pause