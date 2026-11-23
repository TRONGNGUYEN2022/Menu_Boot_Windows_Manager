$ErrorActionPreference = "Stop"

# Tự động nâng quyền Administrator nếu chưa chạy với quyền Admin (chuẩn MAS)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Dang yeu cau quyen Administrator..." -ForegroundColor Yellow
    $selfUrl = $MyInvocation.MyCommand.ScriptBlock.File
    $b64Menu = $env:G4E_MENU
    $onlyMenu = $env:G4E_ONLY_MENU
    $relaunch = "`$env:G4E_MENU='$b64Menu'; `$env:G4E_ONLY_MENU='$onlyMenu'; " + $MyInvocation.MyCommand.Definition
    $encCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($relaunch))
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encCmd" -Verb RunAs
    exit
}

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   GRUB4EFI BOOT STUDIO - TU DONG CAI DAT TU GITHUB" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

if ($env:firmware_type -ne "UEFI") {
    Write-Host "[LOI] May tinh dang chay chuan $env:firmware_type. Chi ho tro chuan UEFI!" -ForegroundColor Red
    Pause; exit 1
}

# Chuẩn bị nội dung menu.lst (lấy từ Web App hoặc dùng mặc định)
if ($env:G4E_MENU) {
    $menuBytes = [System.Convert]::FromBase64String($env:G4E_MENU)
} else {
    $defaultMenu = @"
timeout 10
default 0

title 1. Khoi dong Windows OS
find --set-root /EFI/Microsoft/Boot/bootmgfw.efi
chainloader /EFI/Microsoft/Boot/bootmgfw.efi
"@
    $menuBytes = [System.Text.Encoding]::UTF8.GetBytes($defaultMenu)
}

$mountDrive = "S:"
if (Test-Path $mountDrive) {
    Write-Host "[LOI] Ky tu o dia S: dang ban. Hay giai phong S: truoc!" -ForegroundColor Red
    Pause; exit 1
}

# Nếu chỉ cập nhật menu.lst từ Mục 3
if ($env:G4E_ONLY_MENU -eq "1") {
    mountvol $mountDrive /S
    try {
        $targetDir = "$mountDrive\EFI\Grub4EFI"
        if (-not (Test-Path $targetDir)) {
            Write-Host "[LOI] Chua cai dat Grub4EFI! Hay chay Muc 1 truoc." -ForegroundColor Red
            Pause; exit 1
        }
        [System.IO.File]::WriteAllBytes("$targetDir\menu.lst", $menuBytes)
        Write-Host "[THANH CONG] Da cap nhat danh sach menu.lst moi!" -ForegroundColor Green
    } finally {
        mountvol $mountDrive /D | Out-Null
    }
    Pause; exit 0
}

# 1. Sao lưu BCD gốc
$BackupDir = "C:\Grub4EFI_Backup"
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
bcdedit /export "$BackupDir\BCD_Backup_$ts.bcd" | Out-Null
Write-Host "[OK] Da sao luu BCD goc tai: $BackupDir\BCD_Backup_$ts.bcd" -ForegroundColor Green

# 2. Tải Grub4EFI mới nhất trực tiếp từ GitHub
$WorkDir = "$env:TEMP\Grub4EFI_AutoDL"
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Host "[DANG TAI] Dang tai Grub4EFI moi nhat tu GitHub..." -ForegroundColor Yellow
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/chenall/grub4dos/releases?per_page=10"
$uefiRel = $releases | Where-Object { $_.tag_name -match "UEFI" -or $_.name -match "UEFI" } | Select-Object -First 1
if (-not $uefiRel) { $uefiRel = $releases[0] }
$asset = $uefiRel.assets | Where-Object { $_.name -match "\.(7z|zip)$" } | Select-Object -First 1
if (-not $asset) { throw "Khong tim thay goi tai ve tren GitHub!" }

$arcFile = "$WorkDir\$($asset.name)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $arcFile -UseBasicParsing
Write-Host "[OK] Da tai xong: $($asset.name)" -ForegroundColor Green

tar -xf "$arcFile" -C "$WorkDir"
$efiSource = Get-ChildItem -Path $WorkDir -Recurse -Filter "BOOTX64.EFI" | Select-Object -First 1
if (-not $efiSource) { throw "Khong tim thay BOOTX64.EFI trong goi tai ve!" }

# 3. Nạp vào phân vùng EFI & đăng ký BCD
mountvol $mountDrive /S
try {
    $targetDir = "$mountDrive\EFI\Grub4EFI"
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Copy-Item -Path $efiSource.FullName -Destination "$targetDir\grub4efi.efi" -Force
    [System.IO.File]::WriteAllBytes("$targetDir\menu.lst", $menuBytes)

    $bcdText = bcdedit /enum all | Out-String
    foreach ($b in ($bcdText -split "(`r?`n){2,}")) {
        if ($b -match "Grub4EFI" -or $b -match "\\EFI\\Grub4EFI\\") {
            $m = [regex]::Match($b, "\{[0-9a-fA-F-]{36}\}")
            if ($m.Success -and $m.Value -ne "{bootmgr}" -and $m.Value -ne "{current}") {
                bcdedit /delete $m.Value /f | Out-Null
            }
        }
    }

    $copyOut = bcdedit /copy "{bootmgr}" /d "Grub4EFI Boot Manager" | Out-String
    $guid = ([regex]::Match($copyOut, "\{[0-9a-fA-F-]{36}\}")).Value
    bcdedit /set $guid device partition=$mountDrive | Out-Null
    bcdedit /set $guid path "\EFI\Grub4EFI\grub4efi.efi" | Out-Null
    bcdedit /displayorder $guid /addlast | Out-Null
    bcdedit /timeout 5 | Out-Null

    Write-Host "[THANH CONG] Da cai dat Grub4EFI vao Menu Boot Windows!" -ForegroundColor Green
    Write-Host "Luu y: Hay tat Secure Boot trong BIOS neu may bao chan chu ky EFI." -ForegroundColor Yellow
} finally {
    mountvol $mountDrive /D | Out-Null
}
Pause