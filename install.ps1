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

# Win32 API ánh xạ Drive Letter / Volume GUID -> \Device\HarddiskVolumeX
if (-not ("Win32VolHelper" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32VolHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, uint ucchMax);
    public static string GetNtPath(string deviceOrGuid) {
        if (string.IsNullOrEmpty(deviceOrGuid)) return "";
        string devName = deviceOrGuid.Replace(@"\\?\", "").TrimEnd('\\');
        StringBuilder sb = new StringBuilder(1024);
        uint res = QueryDosDevice(devName, sb, 1024);
        return res > 0 ? sb.ToString() : "";
    }
}
"@
}

function Invoke-DiskpartScript([string]$scriptBody) {
    $dpFile = Join-Path $env:TEMP "g4e_dp_$(Get-Random).txt"
    [System.IO.File]::WriteAllText($dpFile, $scriptBody, [System.Text.Encoding]::ASCII)
    try {
        $p = Start-Process -FilePath "diskpart.exe" -ArgumentList "/s `"$dpFile`"" -Wait -NoNewWindow -PassThru
        return $p.ExitCode
    } finally {
        Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-EfiFolder([string]$drive) {
    for ($i = 0; $i -lt 12; $i++) {
        if ([System.IO.Directory]::Exists("$drive\EFI")) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Mount-ActiveEfi {
    # Bước A: Xác định thiết bị chứa {bootmgr} đang hoạt động
    $bmOut = (& bcdedit /enum "{bootmgr}" | Out-String)
    $bootDevice = ""
    if ($bmOut -match "device\s+partition=([^\r\n]+)") {
        $bootDevice = $Matches[1].Trim()
    }

    # Trường hợp {bootmgr} hiển thị thẳng ký tự ổ đĩa (vd: S:) và đọc được \EFI
    if ($bootDevice -match "^[A-Z]:$" -and [System.IO.Directory]::Exists("$bootDevice\EFI")) {
        Write-Host "[OK] Phan vung EFI dang boot da mount san tai $bootDevice" -ForegroundColor Green
        return @{ Drive = $bootDevice; MountedByUs = $false; Method = "existing" }
    }

    # Dự phòng lấy NT Path từ Registry SystemPartition nếu BCD không hiển thị dạng \Device\
    if (-not ($bootDevice -match "^\\Device\\")) {
        $regSys = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name SystemPartition -ErrorAction SilentlyContinue).SystemPartition
        if ($regSys) { $bootDevice = $regSys.Trim() }
    }

    # Quét mọi ổ đĩa đang mount sẵn (như S:) và đối chiếu NT Path với {bootmgr}
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady) {
            $drvLetter = $d.Name.TrimEnd('\')
            $nt = [Win32VolHelper]::GetNtPath($drvLetter)
            if ($bootDevice -and $nt -and ($nt -ieq $bootDevice) -and [System.IO.Directory]::Exists("$drvLetter\EFI")) {
                Write-Host "[OK] Phan vung EFI dang boot da duoc gan san tai $drvLetter" -ForegroundColor Green
                return @{ Drive = $drvLetter; MountedByUs = $false; Method = "existing" }
            }
        }
    }

    # Bước B: Liệt kê toàn bộ phân vùng EFI System Partition (ESP) trên mọi ổ đĩa
    $allEsps = @(Get-Partition | Where-Object { $_.GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' })
    if ($allEsps.Count -eq 0) {
        throw "Khong tim thay phan vung EFI System Partition (ESP) nao tren may!"
    }

    $targetEsp = $null
    $targetVolGuid = $null

    foreach ($p in $allEsps) {
        $vGuid = ($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
        if (-not $vGuid) {
            $vObj = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($vObj -and $vObj.UniqueId) { $vGuid = $vObj.UniqueId }
        }
        $ntPath = if ($vGuid) { [Win32VolHelper]::GetNtPath($vGuid) } else { "" }

        if ($bootDevice -and $ntPath -and ($ntPath -ieq $bootDevice)) {
            $targetEsp = $p
            $targetVolGuid = $vGuid
            break
        }
    }

    # Fallback nếu máy boot qua bộ nạp khác: ưu tiên ESP IsSystem hoặc nằm cùng ổ chứa C:
    if (-not $targetEsp) {
        $osDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
        $targetEsp = $allEsps | Sort-Object -Property @{Expression={$_.IsSystem};Descending=$true}, @{Expression={$_.DiskNumber -eq $osDisk};Descending=$true} | Select-Object -First 1
        $targetVolGuid = ($targetEsp.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
        if (-not $targetVolGuid) {
            $vObj = Get-Volume -Partition $targetEsp -ErrorAction SilentlyContinue
            if ($vObj -and $vObj.UniqueId) { $targetVolGuid = $vObj.UniqueId }
        }
    }

    $espSizeMB = [math]::Round($targetEsp.Size / 1MB)
    Write-Host "[OK] Xac dinh dung phan vung EFI dang boot: Disk $($targetEsp.DiskNumber) Partition $($targetEsp.PartitionNumber) ($espSizeMB MB)" -ForegroundColor Green

    # Kiểm tra xem ESP mục tiêu đã có sẵn ký tự ổ đĩa trong AccessPaths chưa
    $existingLetterPath = $targetEsp.AccessPaths | Where-Object { $_ -match "^[A-Z]:\\$" } | Select-Object -First 1
    if ($existingLetterPath) {
        $drvExist = $existingLetterPath.TrimEnd('\')
        if ([System.IO.Directory]::Exists("$drvExist\EFI")) {
            Write-Host "[INFO] Phan vung nay dang duoc gan san ky tu $drvExist" -ForegroundColor Cyan
            return @{ Drive = $drvExist; MountedByUs = $false; Method = "existing" }
        }
    }

    # Bước C: Tìm ký tự ổ đĩa trống (ưu tiên từ Z: lùi về M:)
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1).ToUpper() })
    $free = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M') |
            Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $free) { throw "Khong con ky tu o dia trong nao de mount phan vung EFI!" }
    $drv = "$free`:"

    # Cách 1: Mount trực tiếp bằng Volume GUID (tránh lỗi mountvol /S trên máy nhiều ESP)
    if ($targetVolGuid) {
        if (-not $targetVolGuid.EndsWith('\')) { $targetVolGuid += '\' }
        Write-Host "[INFO] Dang gan tam $drv vao Disk $($targetEsp.DiskNumber) Partition $($targetEsp.PartitionNumber)..." -ForegroundColor Cyan
        $mv = Start-Process -FilePath "mountvol.exe" -ArgumentList "$drv $targetVolGuid" -Wait -NoNewWindow -PassThru
        if ($mv.ExitCode -eq 0 -and (Wait-EfiFolder $drv)) {
            return @{ Drive = $drv; Letter = $free; MountedByUs = $true; Method = "mountvol" }
        }
    }

    # Cách 2: Gắn tạm bằng DiskPart
    Write-Host "[INFO] Chuyen sang gan tam $drv bang DiskPart..." -ForegroundColor Yellow
    $dpCode = Invoke-DiskpartScript "select disk $($targetEsp.DiskNumber)`r`nselect partition $($targetEsp.PartitionNumber)`r`nassign letter=$free`r`n"
    if ($dpCode -eq 0 -and (Wait-EfiFolder $drv)) {
        return @{ Drive = $drv; Letter = $free; MountedByUs = $true; Method = "diskpart"; Disk = $targetEsp.DiskNumber; Part = $targetEsp.PartitionNumber }
    }

    throw "Khong the mount phan vung EFI Disk $($targetEsp.DiskNumber) Partition $($targetEsp.PartitionNumber) vao $drv!"
}

function Dismount-ActiveEfi($efiInfo) {
    if (-not $efiInfo -or -not $efiInfo.MountedByUs -or -not $efiInfo.Drive) { return }
    if ($efiInfo.Method -eq "mountvol") {
        Start-Process -FilePath "mountvol.exe" -ArgumentList "$($efiInfo.Drive) /D" -Wait -NoNewWindow | Out-Null
    } elseif ($efiInfo.Method -eq "diskpart") {
        Invoke-DiskpartScript "select disk $($efiInfo.Disk)`r`nselect partition $($efiInfo.Part)`r`nremove letter=$($efiInfo.Letter)`r`n" | Out-Null
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

    # Chế độ chỉ cập nhật menu.lst từ Mục 3
    if ($env:G4E_ONLY_MENU -eq "1") {
        $efi = Mount-ActiveEfi
        try {
            $grubDir = "$($efi.Drive)\EFI\grub"
            if (-not [System.IO.File]::Exists("$grubDir\grub4efi.efi")) {
                throw "Chua cai dat Grub4EFI! Hay chay Muc 1 (Cai dat Grub4EFI) truoc."
            }
            [System.IO.File]::WriteAllBytes("$grubDir\menu.lst", $menuBytes)
            Write-Host "[THANH CONG] Da cap nhat \EFI\grub\menu.lst moi!" -ForegroundColor Green
        } finally {
            Dismount-ActiveEfi $efi
        }
        return
    }

    # 2. Sao lưu BCD gốc
    $BackupDir = "C:\Grub4EFI_Backup"
    [System.IO.Directory]::CreateDirectory($BackupDir) | Out-Null
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $bakFile = "$BackupDir\BCD_Backup_$ts.bcd"
    $bakProc = Start-Process -FilePath "bcdedit.exe" -ArgumentList "/export `"$bakFile`"" -Wait -NoNewWindow -PassThru
    if ($bakProc.ExitCode -ne 0) { throw "Sao luu BCD that bai!" }
    Write-Host "[OK] Da sao luu BCD goc tai: $bakFile" -ForegroundColor Green

    # 3. Tải & giải nén Grub4EFI mới nhất từ GitHub
    $WorkDir = Join-Path $BackupDir "_tmp_$(Get-Random)"
    [System.IO.Directory]::CreateDirectory($WorkDir) | Out-Null

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

        $extractDir = Join-Path $WorkDir "extracted"
        [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null

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

        # 4. Nạp tệp vào \EFI\grub\ & đăng ký {fwbootmgr}
        $efi = Mount-ActiveEfi
        try {
            $grubDir = "$($efi.Drive)\EFI\grub"
            [System.IO.Directory]::CreateDirectory($grubDir) | Out-Null
            [System.IO.File]::Copy($efiSource.FullName, "$grubDir\grub4efi.efi", $true)
            [System.IO.File]::WriteAllBytes("$grubDir\menu.lst", $menuBytes)
            Write-Host "[OK] Da nap grub4efi.efi va menu.lst vao $($efi.Drive)\EFI\grub\" -ForegroundColor Green

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

            $p1 = Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set $guid device partition=$($efi.Drive)" -Wait -NoNewWindow -PassThru
            $p2 = Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set $guid path `"\EFI\grub\grub4efi.efi`"" -Wait -NoNewWindow -PassThru
            if ($p1.ExitCode -ne 0 -or $p2.ExitCode -ne 0) {
                throw "Loi cau hinh device/path cho muc boot $guid!"
            }

            if ($env:G4E_BOOT_FIRST -eq "0") {
                Start-Process -FilePath "bcdedit.exe" -ArgumentList "/set {fwbootmgr} displayorder $guid /addlast" -Wait -NoNewWindow | Out-Null
                Write-Host "[THANH CONG] Da them Grub4EFI vao BIOS/UEFI Boot Menu (Giu thu tu boot hien tai)!" -ForegroundColor Green
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
            Dismount-ActiveEfi $efi
        }
    } finally {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "[LOI] $($_.Exception.Message)" -ForegroundColor Red
}

Remove-Item Env:G4E_MENU, Env:G4E_ONLY_MENU, Env:G4E_BOOT_FIRST -ErrorAction SilentlyContinue
Read-Host "`nNhan Enter de hoan tat" | Out-Null