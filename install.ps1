$ErrorActionPreference = "Stop"

# 1. Tự động nâng quyền Administrator an toàn qua tệp tạm
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Dang yeu cau quyen Administrator..." -ForegroundColor Yellow
    $tmpPs1 = Join-Path $env:TEMP "g4e_elevated_$(Get-Random).ps1"
    $envHeader = "`$env:G4E_MENU='$($env:G4E_MENU)'; `$env:G4E_ONLY_MENU='$($env:G4E_ONLY_MENU)'; `$env:G4E_BOOT_FIRST='$($env:G4E_BOOT_FIRST)';`r`n"
    [System.IO.File]::WriteAllText($tmpPs1, $envHeader + $MyInvocation.MyCommand.Definition, [System.Text.Encoding]::UTF8)
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpPs1`"" -Verb RunAs
    return
}

if ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -like "g4e_elevated_*.ps1") {
    Register-EngineEvent PowerShell.Exiting -Action { Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue } | Out-Null
}

function Mount-EfiSafely {
    $esp = Get-Partition | Where-Object { $_.GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' } |
           Sort-Object -Property IsSystem -Descending | Select-Object -First 1

    if ($esp -and $esp.DriveLetter -and ([string]$esp.DriveLetter -match '^[A-Z]$')) {
        $existingDrive = "$($esp.DriveLetter):"
        if (Test-Path "$existingDrive\EFI") {
            Write-Host "[INFO] Phan vung EFI dang duoc gan san o $existingDrive" -ForegroundColor Cyan
            return @{ Drive = $existingDrive; MountedByUs = $false }
        }
    }

    $used = (Get-PSDrive -PSProvider FileSystem).Name
    $free = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M') |
            Where-Object { ($_ -notin $used) -and (-not (Test-Path "$($_):")) } |
            Select-Object -First 1
    if (-not $free) { throw "Khong con ky tu o dia trong nao de mount phan vung EFI!" }

    $drv = "$free`:"
    Write-Host "[INFO] Dang mount tam phan vung EFI vao $drv..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "mountvol.exe" -ArgumentList "$drv /S" -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -ne 0 -or -not (Test-Path "$drv\EFI")) {
        throw "Khong the mount phan vung EFI vao $drv (Ma loi: $($proc.ExitCode))"
    }
    return @{ Drive = $drv; MountedByUs = $true }
}

function Dismount-EfiSafely($efiInfo) {
    if ($efiInfo -and $efiInfo.MountedByUs -and $efiInfo.Drive) {
        Start-Process -FilePath "mountvol.exe" -ArgumentList "$($efiInfo.Drive) /D" -Wait -NoNewWindow | Out-Null
    }
}

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   GRUB4EFI BOOT STUDIO - TU DONG CAI DAT UEFI" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

try {
    if ($env:firmware_type -ne "UEFI") {
        throw "May tinh dang chay chuan $env:firmware_type. Cong cu chi ho tro chuan UEFI!"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($env:G4E_MENU) {
        $menuBytes = [System.Convert]::FromBase64String($env:G4E_MENU)
    } else {
        $defaultMenu = "timeout 5`r`ndefault 0`r`n`r`ntitle 1. Khoi dong Windows OS`r`nfind --set-root /EFI/Microsoft/Boot/bootmgfw.efi`r`nchainloader /EFI/Microsoft/Boot/bootmgfw.efi`r`n"
        $menuBytes = $utf8NoBom.GetBytes($defaultMenu)
    }

    # Trường hợp chỉ cập nhật menu.lst từ Mục 3
    if ($env:G4E_ONLY_MENU -eq "1") {
        $efi = Mount-EfiSafely
        try {
            $grubDir = "$($efi.Drive)\EFI\grub"
            if (-not (Test-Path "$grubDir\grub4efi.efi")) {
                throw "Chua cai dat Grub4EFI! Hay chay Muc 1 (Cai dat Grub4EFI) truoc."
            }
            [System.IO.File]::WriteAllBytes("$grubDir\menu.lst", $menuBytes)
            Write-Host "[THANH CONG] Da cap nhat \EFI\grub\menu.lst moi!" -ForegroundColor Green
        } finally {
            Dismount-EfiSafely $efi
        }
        return
    }

    # 2. Sao lưu BCD gốc
    $BackupDir = "C:\Grub4EFI_Backup"
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $bakFile = "$BackupDir\BCD_Backup_$ts.bcd"
    $bakProc = Start-Process -FilePath "bcdedit.exe" -ArgumentList "/export `"$bakFile`"" -Wait -NoNewWindow -PassThru
    if ($bakProc.ExitCode -ne 0) { throw "Sao luu BCD that bai!" }
    Write-Host "[OK] Da sao luu BCD goc tai: $bakFile" -ForegroundColor Green

    # 3. Tự động tải Grub4EFI mới nhất từ GitHub (thư mục tạm không dấu cách)
    $WorkDir = Join-Path $BackupDir "_tmp_$(Get-Random)"
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    try {
        Write-Host "[DANG TAI] Dang ket noi GitHub de tai Grub4EFI moi nhat..." -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ "User-Agent" = "Grub4EFI-Boot-Studio" }
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/chenall/grub4dos/releases?per_page=15" -Headers $headers
        $uefiRel = $releases | Where-Object {
            ($_.tag_name -match "UEFI") -or ($_.name -match "UEFI") -or ($_.assets.name -match "UEFI")
        } | Select-Object -First 1
        if (-not $uefiRel) { throw "Khong tim thay ban phat hanh UEFI tren GitHub!" }

        $asset = $uefiRel.assets | Where-Object { $_.name -match "\.(zip|7z)$" } | Select-Object -First 1
        if (-not $asset) { throw "Khong tim thay goi nen (.zip/.7z) trong ban phat hanh UEFI!" }

        $arcFile = Join-Path $WorkDir $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $arcFile -Headers $headers -UseBasicParsing
        Write-Host "[OK] Da tai xong: $($asset.name)" -ForegroundColor Green

        # Giải nén chuẩn theo phần mở rộng (không dùng tar.exe cho .7z)
        $extractDir = Join-Path $WorkDir "extracted"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        if ($arcFile -match "\.zip$") {
            Expand-Archive -Path $arcFile -DestinationPath $extractDir -Force
        } else {
            $sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") |
                        Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $sevenZip) {
                Write-Host "[INFO] Dang tai bo giai nen 7zr.exe chinh chu..." -ForegroundColor Yellow
                $sevenZip = Join-Path $WorkDir "7zr.exe"
                Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $sevenZip -UseBasicParsing
            }
            Write-Host "[INFO] Dang giai nen goi .7z..." -ForegroundColor Cyan
            $zProc = Start-Process -FilePath $sevenZip -ArgumentList "x `"$arcFile`" `"-o$extractDir`" -y" -Wait -NoNewWindow -PassThru
            if ($zProc.ExitCode -ne 0) { throw "Giai nen .7z that bai (Ma loi: $($zProc.ExitCode))" }
        }

        $efiSource = Get-ChildItem -Path $extractDir -Recurse -Filter "BOOTX64.EFI" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $efiSource) { throw "Khong tim thay file BOOTX64.EFI sau khi giai nen!" }
        Write-Host "[OK] Da trich xuat: $($efiSource.Name)" -ForegroundColor Green

        # 4. Nạp vào \EFI\grub\ & đăng ký {fwbootmgr}
        $efi = Mount-EfiSafely
        try {
            $grubDir = "$($efi.Drive)\EFI\grub"
            New-Item -ItemType Directory -Path $grubDir -Force | Out-Null
            Copy-Item -Path $efiSource.FullName -Destination "$grubDir\grub4efi.efi" -Force
            [System.IO.File]::WriteAllBytes("$grubDir\menu.lst", $menuBytes)

            # Xóa mục Grub4EFI cũ nếu có (bảo vệ tuyệt đối Windows Boot Manager)
            $allBcd = (& bcdedit /enum all | Out-String)
            foreach ($b in ($allBcd -split "(\r?\n){2,}")) {
                if (($b -match "Grub4EFI" -or $b -match "\\EFI\\grub\\grub4efi\.efi" -or $b -match "\\EFI\\Grub4EFI\\") -and ($b -notmatch "bootmgfw\.efi|winload\.efi")) {
                    $m = [regex]::Match($b, "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}")
                    if ($m.Success) { Start-Process -FilePath "bcdedit.exe" -ArgumentList "/delete $($m.Value) /f" -Wait -NoNewWindow | Out-Null }
                }
            }

            # Đăng ký Firmware Application mới trong UEFI NVRAM qua {fwbootmgr}
            $copyOut = (& bcdedit /copy "{bootmgr}" /d "Grub4EFI Boot Manager" | Out-String)
            if ($LASTEXITCODE -ne 0) { throw "Loi bcdedit /copy: $copyOut" }
            $guid = ([regex]::Match($copyOut, "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}")).Value
            if (-not $guid) { throw "Khong lay duoc GUID moi tu bcdedit!" }

            Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set $guid device partition=$($efi.Drive)" -Wait -NoNewWindow | Out-Null
            Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set $guid path `"\EFI\grub\grub4efi.efi`"" -Wait -NoNewWindow | Out-Null

            if ($env:G4E_BOOT_FIRST -eq "0") {
                Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set {fwbootmgr} displayorder $guid /addlast" -Wait -NoNewWindow | Out-Null
                Write-Host "[THANH CONG] Da them Grub4EFI vao BIOS/UEFI Boot Menu (Giu Windows mac dinh)!" -ForegroundColor Green
            } else {
                Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set {fwbootmgr} displayorder $guid /addfirst" -Wait -NoNewWindow | Out-Null
                Write-Host "[THANH CONG] Da dat Grub4EFI lam Menu Boot chinh (tu vao Windows sau 5 giay)!" -ForegroundColor Green
            }

            try {
                if (Confirm-SecureBootUEFI) {
                    Write-Host "[CANH BAO] Secure Boot dang BAT! Hay vao BIOS tat Secure Boot de Grub4EFI khoi dong duoc." -ForegroundColor Yellow
                }
            } catch {}
        } finally {
            Dismount-EfiSafely $efi
        }
    } finally {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "[LOI] $($_.Exception.Message)" -ForegroundColor Red
}

Remove-Item Env:G4E_MENU, Env:G4E_ONLY_MENU, Env:G4E_BOOT_FIRST -ErrorAction SilentlyContinue
Read-Host "`nNhan Enter de hoan tat" | Out-Null