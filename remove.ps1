$ErrorActionPreference = "Stop"

# Tự động nâng quyền Administrator an toàn qua tệp tạm
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Dang yeu cau quyen Administrator..." -ForegroundColor Yellow
    $tmpPs1 = Join-Path $env:TEMP "g4e_rem_$(Get-Random).ps1"
    [System.IO.File]::WriteAllText($tmpPs1, $MyInvocation.MyCommand.Definition, [System.Text.Encoding]::UTF8)
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpPs1`"" -Verb RunAs
    return
}

if ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -like "g4e_rem_*.ps1") {
    Register-EngineEvent PowerShell.Exiting -Action { Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue } | Out-Null
}

Write-Host "=====================================================" -ForegroundColor Red
Write-Host "   GRUB4EFI BOOT STUDIO - GO BO KHOI MENU BOOT UEFI" -ForegroundColor Red
Write-Host "=====================================================" -ForegroundColor Red

try {
    # 1. Xóa toàn bộ mục Grub4EFI trong BCD & UEFI NVRAM (bảo vệ Windows Boot Manager)
    $allBcd = (& bcdedit /enum all | Out-String)
    $removed = 0
    foreach ($b in ($allBcd -split "(\r?\n){2,}")) {
        if (($b -match "Grub4EFI" -or $b -match "\\EFI\\grub\\grub4efi\.efi" -or $b -match "\\EFI\\Grub4EFI\\") -and ($b -notmatch "bootmgfw\.efi|winload\.efi")) {
            $m = [regex]::Match($b, "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}")
            if ($m.Success) {
                & bcdedit /delete $m.Value /f | Out-Null
                Write-Host "[DA XOA] Muc boot $($m.Value)" -ForegroundColor Green
                $removed++
            }
        }
    }

    # Đưa Windows Boot Manager lên đầu lại để chắc chắn máy vào thẳng Windows
    & bcdedit /set "{fwbootmgr}" displayorder "{bootmgr}" /addfirst | Out-Null

    # 2. Dọn thư mục \EFI\grub và \EFI\Grub4EFI trên phân vùng EFI
    $esp = Get-Partition | Where-Object { $_.GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' } |
           Sort-Object -Property IsSystem -Descending | Select-Object -First 1

    $mountDrive = $null
    $mountedByUs = $false
    if ($esp -and $esp.DriveLetter -and ([string]$esp.DriveLetter -match '^[A-Z]$')) {
        $mountDrive = "$($esp.DriveLetter):"
    } else {
        $used = (Get-PSDrive -PSProvider FileSystem).Name
        $free = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M') |
                Where-Object { ($_ -notin $used) -and (-not (Test-Path "$($_):")) } |
                Select-Object -First 1
        if ($free) {
            $mountDrive = "$free`:"
            & mountvol $mountDrive /S | Out-Null
            if ($LASTEXITCODE -eq 0) { $mountedByUs = $true }
        }
    }

    if ($mountDrive -and (Test-Path "$mountDrive\EFI")) {
        try {
            foreach ($dir in @("$mountDrive\EFI\grub", "$mountDrive\EFI\Grub4EFI")) {
                if (Test-Path $dir) {
                    Remove-Item $dir -Recurse -Force
                    Write-Host "[DA DON EFI] Da xoa thu muc $dir" -ForegroundColor Green
                }
            }
        } finally {
            if ($mountedByUs) { & mountvol $mountDrive /D | Out-Null }
        }
    }

    if ($removed -eq 0) {
        Write-Host "[INFO] Khong thay muc Grub4EFI nao con ton tai trong NVRAM/BCD." -ForegroundColor Yellow
    } else {
        Write-Host "[HOAN TAT] Da go bo sach se Grub4EFI va tra lai Windows Boot Manager mac dinh!" -ForegroundColor Green
    }
} catch {
    Write-Host "[LOI] $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "`nNhan Enter de hoan tat" | Out-Null