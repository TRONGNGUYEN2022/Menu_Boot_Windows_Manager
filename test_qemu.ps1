$ErrorActionPreference = "Stop"

# Tự động nâng quyền Administrator (cần để đọc bcdedit và phân vùng EFI thật)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Dang yeu cau quyen Administrator de doc cau hinh EFI va BCD that..." -ForegroundColor Yellow
    $tmpPs1 = Join-Path $env:TEMP "g4e_test_$(Get-Random).ps1"
    [System.IO.File]::WriteAllText($tmpPs1, $MyInvocation.MyCommand.Definition, [System.Text.Encoding]::UTF8)
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpPs1`"" -Verb RunAs
    return
}

if ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -like "g4e_test_*.ps1") {
    Register-EngineEvent PowerShell.Exiting -Action { Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue } | Out-Null
}

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
    $bmOut = (& bcdedit /enum "{bootmgr}" | Out-String)
    $bootDevice = ""
    if ($bmOut -match "device\s+partition=([^\r\n]+)") { $bootDevice = $Matches[1].Trim() }
    if ($bootDevice -match "^[A-Z]:$" -and [System.IO.Directory]::Exists("$bootDevice\EFI")) {
        return @{ Drive = $bootDevice; MountedByUs = $false; Method = "existing" }
    }
    if (-not ($bootDevice -match "^\\Device\\")) {
        $regSys = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name SystemPartition -ErrorAction SilentlyContinue).SystemPartition
        if ($regSys) { $bootDevice = $regSys.Trim() }
    }

    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady) {
            $drvLetter = $d.Name.TrimEnd('\')
            $nt = [Win32VolHelper]::GetNtPath($drvLetter)
            if ($bootDevice -and $nt -and ($nt -ieq $bootDevice) -and [System.IO.Directory]::Exists("$drvLetter\EFI")) {
                return @{ Drive = $drvLetter; MountedByUs = $false; Method = "existing" }
            }
        }
    }

    $allEsps = @(Get-Partition | Where-Object { $_.GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' })
    if ($allEsps.Count -eq 0) { throw "Khong tim thay phan vung EFI System Partition (ESP) nao!" }

    $targetEsp = $null; $targetVolGuid = $null
    foreach ($p in $allEsps) {
        $vGuid = ($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
        if (-not $vGuid) {
            $vObj = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($vObj -and $vObj.UniqueId) { $vGuid = $vObj.UniqueId }
        }
        $ntPath = if ($vGuid) { [Win32VolHelper]::GetNtPath($vGuid) } else { "" }
        if ($bootDevice -and $ntPath -and ($ntPath -ieq $bootDevice)) {
            $targetEsp = $p; $targetVolGuid = $vGuid; break
        }
    }
    if (-not $targetEsp) {
        $osDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
        $targetEsp = $allEsps | Sort-Object -Property @{Expression={$_.IsSystem};Descending=$true}, @{Expression={$_.DiskNumber -eq $osDisk};Descending=$true} | Select-Object -First 1
        $targetVolGuid = ($targetEsp.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
    }

    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1).ToUpper() })
    $free = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M') | Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $free) { throw "Khong con ky tu o dia trong nao de mount EFI!" }
    $drv = "$free`:"

    if ($targetVolGuid) {
        if (-not $targetVolGuid.EndsWith('\')) { $targetVolGuid += '\' }
        $mv = Start-Process -FilePath "mountvol.exe" -ArgumentList "$drv $targetVolGuid" -Wait -NoNewWindow -PassThru
        if ($mv.ExitCode -eq 0 -and (Wait-EfiFolder $drv)) {
            return @{ Drive = $drv; Letter = $free; MountedByUs = $true; Method = "mountvol" }
        }
    }
    $dpCode = Invoke-DiskpartScript "select disk $($targetEsp.DiskNumber)`r`nselect partition $($targetEsp.PartitionNumber)`r`nassign letter=$free`r`n"
    if ($dpCode -eq 0 -and (Wait-EfiFolder $drv)) {
        return @{ Drive = $drv; Letter = $free; MountedByUs = $true; Method = "diskpart"; Disk = $targetEsp.DiskNumber; Part = $targetEsp.PartitionNumber }
    }
    throw "Khong the mount phan vung EFI de kiem tra!"
}

function Dismount-ActiveEfi($efiInfo) {
    if (-not $efiInfo -or -not $efiInfo.MountedByUs -or -not $efiInfo.Drive) { return }
    if ($efiInfo.Method -eq "mountvol") {
        Start-Process -FilePath "mountvol.exe" -ArgumentList "$($efiInfo.Drive) /D" -Wait -NoNewWindow | Out-Null
    } elseif ($efiInfo.Method -eq "diskpart") {
        Invoke-DiskpartScript "select disk $($efiInfo.Disk)`r`nselect partition $($efiInfo.Part)`r`nremove letter=$($efiInfo.Letter)`r`n" | Out-Null
    }
}

function Find-QemuBinary([string]$miniDir) {
    $candidates = @(
        (Join-Path $miniDir "qemu-system-x86_64.exe"),
        "C:\Grub4EFI_QEMU\qemu-uefi-mini\qemu-system-x86_64.exe",
        "C:\Program Files\qemu\qemu-system-x86_64.exe",
        "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
        "C:\Tools\qemu\qemu-system-x86_64.exe",
        "$env:LOCALAPPDATA\Programs\qemu\qemu-system-x86_64.exe"
    )
    $found = ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
    if ($found) { return $found }

    $cmd = Get-Command "qemu-system-x86_64.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-OvmfFirmware([string]$qemuExe) {
    $qemuDir = Split-Path $qemuExe -Parent
    $directCandidates = @(
        (Join-Path $qemuDir "share\edk2-x86_64-code.fd"),
        (Join-Path $qemuDir "share\OVMF_CODE.fd"),
        (Join-Path $qemuDir "share\OVMF.fd")
    )
    $direct = ($directCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if ($direct) { return $direct }

    $fw = Get-ChildItem -Path $qemuDir -Recurse -Include "edk2-x86_64-code.fd", "OVMF_CODE.fd", "OVMF.fd" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fw) { return $fw.FullName }
    return $null
}

function Get-SevenZipTool([string]$workDir) {
    $existing = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "C:\Grub4EFI_QEMU\cache\7zr.exe",
        "C:\Grub4EFI_QEMU\7zr.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($existing) { return $existing }

    $zr = Join-Path $workDir "7zr.exe"
    if (-not (Test-Path $zr)) {
        & curl.exe -fsSL "https://www.7-zip.org/a/7zr.exe" -o "$zr"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zr)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $zr -UseBasicParsing
        }
    }
    return $zr
}

function Install-MiniQemuPortable([string]$baseDir, [string]$miniDir) {
    $miniUrl = "https://github.com/trongnguyen2022/Menu_Boot_Windows_Manager/releases/download/qemu-mini/qemu-uefi-mini.7z"
    $archivePath = Join-Path $baseDir "qemu-uefi-mini.7z"

    Write-Host "  [DANG TAI] Dang tai goi QEMU UEFI Mini Portable qua curl.exe..." -ForegroundColor Yellow
    & curl.exe -fL --progress-bar "$miniUrl" -o "$archivePath"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $archivePath) -or ((Get-Item $archivePath).Length -lt 1MB)) {
        if (Test-Path $archivePath) { Remove-Item $archivePath -Force -ErrorAction SilentlyContinue }
        throw "Khong tai duoc goi qemu-uefi-mini.7z tu GitHub Releases (tag: qemu-mini)."
    }

    try {
        [System.IO.Directory]::CreateDirectory($miniDir) | Out-Null
        $sevenZip = Get-SevenZipTool $baseDir
        Write-Host "  [DANG GIAI NEN] Dang giai nen QEMU UEFI Mini..." -ForegroundColor Cyan
        $zProc = Start-Process -FilePath $sevenZip -ArgumentList "x `"$archivePath`" `"-o$miniDir`" -y" -Wait -NoNewWindow -PassThru
        if ($zProc.ExitCode -ne 0) {
            throw "Giai nen qemu-uefi-mini.7z that bai (Ma loi: $($zProc.ExitCode))."
        }

        # Nếu gói nén chứa 1 thư mục con bọc ngoài thì đưa file ra thẳng $miniDir
        $nestedExe = Get-ChildItem -Path $miniDir -Recurse -Filter "qemu-system-x86_64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nestedExe -and ((Split-Path $nestedExe.FullName -Parent) -ne $miniDir)) {
            $subRoot = Split-Path $nestedExe.FullName -Parent
            Get-ChildItem -Path $subRoot -Force | Move-Item -Destination $miniDir -Force
        }
    } finally {
        Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "   KIEM TRA KET QUA CAI DAT THUC TE & BOOT THU TRONG QEMU" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

$passAll = $true
$grubGuid = $null

try {
    # === PHẦN 1: KIỂM TRA UEFI NVRAM / BCD THẬT ===
    Write-Host "`n[1/4] Kiem tra muc khoi dong trong UEFI NVRAM (bcdedit)..." -ForegroundColor Yellow
    $fwText = (& bcdedit /enum firmware | Out-String)
    $blocks = $fwText -split "(\r?\n){2,}"
    $grubBlock = $blocks | Where-Object { $_ -match "\\EFI\\grub\\grub4efi\.efi" -or $_ -match "Grub4EFI" } | Select-Object -First 1

    if ($grubBlock) {
        $m = [regex]::Match($grubBlock, "\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}")
        if ($m.Success) { $grubGuid = $m.Value }
        Write-Host "  [PASS] Da tim thay muc boot: Grub4EFI ($grubGuid)" -ForegroundColor Green

        $fwMgr = $blocks | Where-Object { $_ -match "\{fwbootmgr\}" } | Select-Object -First 1
        if ($fwMgr -and $grubGuid) {
            if ($fwMgr -match "displayorder\s+$([regex]::Escape($grubGuid))") {
                Write-Host "  [PASS] Grub4EFI dang dung VI TRI SO 1 trong thu tu khoi dong UEFI." -ForegroundColor Green
            } elseif ($fwMgr -match [regex]::Escape($grubGuid)) {
                Write-Host "  [INFO] Grub4EFI da co trong danh sach UEFI (khong dung vi tri #1 - giu menu chinh hien tai)." -ForegroundColor Cyan
            }
        }
    } else {
        Write-Host "  [FAIL] Chua thay muc Grub4EFI trong bcdedit /enum firmware! Hay chay Muc 1 truoc." -ForegroundColor Red
        $passAll = $false
    }

    # === PHẦN 2: KIỂM TRA SECURE BOOT ===
    Write-Host "`n[2/4] Kiem tra trang thai Secure Boot..." -ForegroundColor Yellow
    try {
        if (Confirm-SecureBootUEFI) {
            Write-Host "  [CANH BAO] Secure Boot dang BAT! May that se chan Grub4EFI tru khi tat Secure Boot trong BIOS." -ForegroundColor Yellow
        } else {
            Write-Host "  [PASS] Secure Boot dang TAT - Tuong thich 100% voi Grub4EFI." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [INFO] Khong doc duoc trang thai Secure Boot." -ForegroundColor Gray
    }

    # === PHẦN 3: KIỂM TRA FILE THẬT TRÊN PHÂN VÙNG EFI & QUÉT FILE ISO/VHD TRONG MENU.LST ===
    Write-Host "`n[3/4] Kiem tra file that tren phan vung EFI & duong dan trong menu.lst..." -ForegroundColor Yellow
    $BaseDir = "C:\Grub4EFI_QEMU"
    $MiniDir = Join-Path $BaseDir "qemu-uefi-mini"
    $EspDir  = Join-Path $BaseDir "esp"
    [System.IO.Directory]::CreateDirectory($BaseDir) | Out-Null
    if (Test-Path $EspDir) { Remove-Item $EspDir -Recurse -Force }
    [System.IO.Directory]::CreateDirectory("$EspDir\EFI\BOOT") | Out-Null
    [System.IO.Directory]::CreateDirectory("$EspDir\EFI\grub") | Out-Null

    $efi = Mount-ActiveEfi
    try {
        $realEfiFile = "$($efi.Drive)\EFI\grub\grub4efi.efi"
        $realMenuLst = "$($efi.Drive)\EFI\grub\menu.lst"

        if ([System.IO.File]::Exists($realEfiFile)) {
            $efiKB = [math]::Round((Get-Item $realEfiFile).Length / 1KB, 1)
            Write-Host "  [PASS] Co file that: $realEfiFile ($efiKB KB)" -ForegroundColor Green
            [System.IO.File]::Copy($realEfiFile, "$EspDir\EFI\BOOT\BOOTX64.EFI", $true)
        } else {
            Write-Host "  [FAIL] Khong thay file $realEfiFile!" -ForegroundColor Red
            $passAll = $false
        }

        if ([System.IO.File]::Exists($realMenuLst)) {
            $menuContent = [System.IO.File]::ReadAllText($realMenuLst)
            Write-Host "  [PASS] Co file that: $realMenuLst" -ForegroundColor Green
            [System.IO.File]::Copy($realMenuLst, "$EspDir\EFI\grub\menu.lst", $true)
            [System.IO.File]::Copy($realMenuLst, "$EspDir\EFI\BOOT\menu.lst", $true)

            Write-Host "`n  --- NOI DUNG MENU.LST DANG CAI TREN MAY ---" -ForegroundColor DarkCyan
            Write-Host $menuContent -ForegroundColor Gray
            Write-Host "  -------------------------------------------" -ForegroundColor DarkCyan

            $allDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') })
            $matches = [regex]::Matches($menuContent, "find\s+--set-root\s+([^\r\n]+)")
            foreach ($mt in $matches) {
                $relPath = $mt.Groups[1].Value.Trim()
                $winRel  = $relPath -replace '/', '\'
                $foundAt = @()
                foreach ($drv in $allDrives) {
                    if ([System.IO.File]::Exists("$drv$winRel")) { $foundAt += "$drv$winRel" }
                }
                if ($foundAt.Count -gt 0) {
                    Write-Host "  [PASS] File ton tai tren may: $relPath -> Tim thay tai $($foundAt -join ', ')" -ForegroundColor Green
                } else {
                    Write-Host "  [CANH BAO] Khong thay file '$relPath' tren bat ky o dia nao! Khi boot chon muc nay se bao loi 'File not found'." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  [FAIL] Khong thay file $realMenuLst!" -ForegroundColor Red
            $passAll = $false
        }
    } finally {
        Dismount-ActiveEfi $efi
    }

    if (-not $passAll) {
        Write-Host "`n[KET LUAN] Cau hinh chua day du, hay sua cac muc [FAIL] o tren truoc khi boot thu." -ForegroundColor Red
        return
    }

    # === PHẦN 4: CHẠY THỬ CHÍNH BỘ GRUB4EFI + MENU.LST THẬT TRONG QEMU UEFI MINI ===
    Write-Host "`n[4/4] Chay thu chinh grub4efi.efi va menu.lst vua cai trong may ao QEMU UEFI..." -ForegroundColor Yellow
    $qemuExe = Find-QemuBinary $MiniDir

    if (-not $qemuExe) {
        try {
            Install-MiniQemuPortable -baseDir $BaseDir -miniDir $MiniDir
            $qemuExe = Find-QemuBinary $MiniDir
        } catch {
            Write-Host "  [INFO] Chua tai duoc goi Mini ($($_.Exception.Message))" -ForegroundColor Yellow
            $ans = Read-Host "  Ban co muon tai bo cai QEMU goc tu qemu.weilnetz.de de chay thu khong? (Y/N)"
            if ($ans -notmatch "^[Yy]") {
                Write-Host "`n[HOAN TAT KIEM TRA TINH] Ban co the thu boot 1 lan an toan tren may that bang lenh:" -ForegroundColor Cyan
                if ($grubGuid) { Write-Host "  bcdedit /set {fwbootmgr} bootsequence $grubGuid" -ForegroundColor White }
                return
            }
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $page = Invoke-WebRequest -Uri "https://qemu.weilnetz.de/w64/" -UseBasicParsing
            $setupName = ([regex]::Matches($page.Content, 'qemu-w64-setup-[0-9]{8}\.exe') | Select-Object -Last 1).Value
            if (-not $setupName) { throw "Khong lay duoc link tai QEMU tu qemu.weilnetz.de!" }
            $setupPath = Join-Path $BaseDir $setupName
            Write-Host "  [DANG TAI] $setupName..." -ForegroundColor Yellow
            & curl.exe -fL --progress-bar "https://qemu.weilnetz.de/w64/$setupName" -o "$setupPath"
            Start-Process -FilePath $setupPath -ArgumentList "/S" -Wait
            $qemuExe = Find-QemuBinary $MiniDir
            if (-not $qemuExe) { throw "Khong tim thay qemu-system-x86_64.exe sau khi cai dat!" }
        }
    }

    $ovmfPath = Find-OvmfFirmware $qemuExe
    if (-not $ovmfPath) { throw "Khong tim thay firmware UEFI (edk2-x86_64-code.fd / OVMF.fd) trong thu muc QEMU!" }

    Write-Host "  [OK] Su dung QEMU: $qemuExe" -ForegroundColor Green
    Write-Host "  [DANG MO QEMU] Hien thi chinh xac giao dien Grub4EFI & menu.lst that cua may ban..." -ForegroundColor Magenta
    Write-Host "  (Luu y: Trong may ao QEMU chi co phan vung EFI ao de kiem tra giao dien/cu phap menu, khong gan o cung Windows that de tranh ghi trung)" -ForegroundColor Gray

    $qemuArgs = @(
        "-name", "`"Test Ket Qua Grub4EFI That (QEMU UEFI)`"",
        "-machine", "q35",
        "-m", "1024M",
        "-bios", "`"$ovmfPath`"",
        "-drive", "format=raw,file=fat:ro:esp",
        "-net", "none"
    )

    Push-Location $BaseDir
    try {
        Start-Process -FilePath $qemuExe -ArgumentList ($qemuArgs -join " ") -Wait
    } finally {
        Pop-Location
    }

    Write-Host "`n[HOAN TAT] Neu man hinh QEMU vua hien du danh sach Menu khong bi loi 'grub>', cai dat da OK!" -ForegroundColor Green
    if ($grubGuid) {
        Write-Host "De test tren phan cung that AN TOAN 1 LAN DUY NHAT (khong doi thu tu boot vinh vien), chay:" -ForegroundColor Cyan
        Write-Host "  bcdedit /set {fwbootmgr} bootsequence $grubGuid" -ForegroundColor White
    }
} catch {
    Write-Host "[LOI] $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "`nNhan Enter de hoan tat" | Out-Null