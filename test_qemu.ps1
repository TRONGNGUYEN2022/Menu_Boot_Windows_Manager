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

function U([string]$escapedText) {
    return [System.Text.RegularExpressions.Regex]::Unescape($escapedText)
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

function Find-OvmfFirmware([string]$qemuExe) {
    if (-not $qemuExe) { return $null }
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

function Find-QemuBinary([string]$miniDir) {
    $candidates = @(
        (Join-Path $miniDir "qemu-system-x86_64.exe"),
        "C:\Grub4EFI_QEMU\qemu-uefi-mini\qemu-system-x86_64.exe",
        "C:\Program Files\qemu\qemu-system-x86_64.exe",
        "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
        "C:\Tools\qemu\qemu-system-x86_64.exe",
        "$env:LOCALAPPDATA\Programs\qemu\qemu-system-x86_64.exe"
    )
    $cmd = Get-Command "qemu-system-x86_64.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ($c -and (Test-Path $c) -and (Find-OvmfFirmware $c)) {
            return $c
        }
    }
    return $null
}

function Download-FileFast([string]$url, [string]$outFile) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wcErr = ""
    $wc = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Grub4EFI-Boot-Studio/2.0")
        $wc.DownloadFile($url, $outFile)
        if ((Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) { return }
    } catch {
        $wcErr = $_.Exception.Message
        if ($_.Exception.InnerException) { $wcErr += " | " + $_.Exception.InnerException.Message }
    } finally {
        if ($wc) { $wc.Dispose() }
    }

    $errLog = Join-Path $env:TEMP "g4e_curl_$(Get-Random).log"
    try {
        $p = Start-Process -FilePath "curl.exe" -ArgumentList "-4 -fL -sS --max-time 60 `"$url`" -o `"$outFile`"" -Wait -NoNewWindow -PassThru -RedirectStandardError $errLog
        if ($p.ExitCode -eq 0 -and (Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) { return }
        $cErr = if (Test-Path $errLog) { ([System.IO.File]::ReadAllText($errLog)).Trim() } else { "curl exit $($p.ExitCode)" }
        throw "WebClient: $wcErr || curl: $cErr"
    } finally {
        Remove-Item $errLog -Force -ErrorAction SilentlyContinue
    }
}

function Test-SevenZipHeader([string]$filePath) {
    if (-not (Test-Path $filePath)) { return $false }
    if ((Get-Item $filePath).Length -lt 1MB) { return $false }
    $fs = [System.IO.File]::OpenRead($filePath)
    try {
        $hdr = New-Object byte[] 6
        if ($fs.Read($hdr, 0, 6) -lt 6) { return $false }
        return ($hdr[0] -eq 0x37 -and $hdr[1] -eq 0x7A -and $hdr[2] -eq 0xBC -and $hdr[3] -eq 0xAF -and $hdr[4] -eq 0x27 -and $hdr[5] -eq 0x1C)
    } finally {
        $fs.Dispose()
    }
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
        Write-Host "  [DANG TAI] Dang tai cong cu giai nen 7zr.exe..." -ForegroundColor Cyan
        Download-FileFast -url "https://www.7-zip.org/a/7zr.exe" -outFile $zr
    }
    return $zr
}

function Find-LocalMiniArchive([string]$baseDir) {
    $dl = [Environment]::GetFolderPath("UserProfile") + "\Downloads"
    $dt = [Environment]::GetFolderPath("Desktop")
    $paths = @(
        (Join-Path $baseDir "qemu-uefi-mini.7z"),
        (Join-Path $dl "qemu-uefi-mini.7z"),
        (Join-Path $dt "qemu-uefi-mini.7z"),
        "D:\qemu-uefi-mini.7z",
        "E:\qemu-uefi-mini.7z",
        "F:\qemu-uefi-mini.7z"
    )
    return ($paths | Where-Object { $_ -and (Test-SevenZipHeader $_) } | Select-Object -First 1)
}

function Resolve-MiniReleaseAsset {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "Grub4EFI-Boot-Studio/2.0" }
    try {
        $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/trongnguyen2022/Menu_Boot_Windows_Manager/releases?per_page=15" -Headers $headers -TimeoutSec 10
        foreach ($r in @($rels)) {
            foreach ($a in @($r.assets)) {
                if ($a.name -match "\.7z$" -and ($a.name -match "qemu|mini" -or $r.tag_name -match "qemu|mini")) {
                    return @{ Url = $a.browser_download_url; Name = $a.name; Tag = $r.tag_name }
                }
            }
        }
    } catch { }
    return @{
        Url  = "https://github.com/trongnguyen2022/Menu_Boot_Windows_Manager/releases/download/qemu-mini/qemu-uefi-mini.7z"
        Name = "qemu-uefi-mini.7z"
        Tag  = "qemu-mini"
    }
}

function Expand-MiniArchive([string]$archivePath, [string]$miniDir, [string]$baseDir) {
    if (-not (Test-SevenZipHeader $archivePath)) {
        throw "Tep $(Split-Path $archivePath -Leaf) bi hong hoac khong phai file .7z hop le!"
    }
    if (Test-Path $miniDir) { Remove-Item $miniDir -Recurse -Force -ErrorAction SilentlyContinue }
    [System.IO.Directory]::CreateDirectory($miniDir) | Out-Null

    $sevenZip = Get-SevenZipTool $baseDir
    Write-Host "  [DANG GIAI NEN] Dang giai nen $(Split-Path $archivePath -Leaf)..." -ForegroundColor Cyan
    $zProc = Start-Process -FilePath $sevenZip -ArgumentList "x `"$archivePath`" `"-o$miniDir`" -y" -Wait -NoNewWindow -PassThru
    if ($zProc.ExitCode -ne 0) {
        throw "Giai nen $(Split-Path $archivePath -Leaf) that bai (Ma loi 7-Zip: $($zProc.ExitCode))."
    }

    $nestedExe = Get-ChildItem -Path $miniDir -Recurse -Filter "qemu-system-x86_64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nestedExe -and ((Split-Path $nestedExe.FullName -Parent) -ne $miniDir)) {
        $subRoot = Split-Path $nestedExe.FullName -Parent
        Get-ChildItem -Path $subRoot -Force | Move-Item -Destination $miniDir -Force
    }
}

function Install-MiniQemuPortable([string]$baseDir, [string]$miniDir) {
    $localArch = Find-LocalMiniArchive $baseDir
    if ($localArch) {
        Write-Host "  [OK] Tim thay goi Mini hop le co san tren may: $localArch" -ForegroundColor Green
        Expand-MiniArchive -archivePath $localArch -miniDir $miniDir -baseDir $baseDir
        return
    }

    $assetInfo = Resolve-MiniReleaseAsset
    $tempArchive = Join-Path $baseDir "qemu-uefi-mini_dl.7z"
    Remove-Item $tempArchive -Force -ErrorAction SilentlyContinue

    Write-Host "  [DANG TAI] Dang tai $($assetInfo.Name) (tag: $($assetInfo.Tag))..." -ForegroundColor Yellow
    try {
        Download-FileFast -url $assetInfo.Url -outFile $tempArchive
        if (-not (Test-SevenZipHeader $tempArchive)) {
            throw "Tep tai ve khong dung dinh dang 7z (co the link bi chuyen huong HTML)."
        }
        Expand-MiniArchive -archivePath $tempArchive -miniDir $miniDir -baseDir $baseDir
        Remove-Item $tempArchive -Force -ErrorAction SilentlyContinue
        return
    } catch {
        Remove-Item $tempArchive -Force -ErrorAction SilentlyContinue
        $dlFolder = [Environment]::GetFolderPath("UserProfile") + "\Downloads"
        Write-Host "  [CANH BAO] Khong tai tu dong duoc goi Mini: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Ban hay tai thu cong '$($assetInfo.Name)' bang trinh duyet vao $dlFolder hoac $baseDir" -ForegroundColor Cyan
        Start-Process "explorer.exe" $baseDir -ErrorAction SilentlyContinue
        $ans = Read-Host "  Sau khi tai xong nhan Enter de tiep tuc (hoac go N de bo qua QEMU)"
        if ($ans -match "^[Nn]") { throw "Nguoi dung bo qua khoi chay QEMU." }

        $localArch2 = Find-LocalMiniArchive $baseDir
        if ($localArch2) {
            Expand-MiniArchive -archivePath $localArch2 -miniDir $miniDir -baseDir $baseDir
            return
        }
        throw "Khong tim thay tep qemu-uefi-mini.7z hop le trong $baseDir hoac $dlFolder."
    }
}

function Clear-AllTempFiles([string]$baseDir) {
    Write-Host "`n[DON DEP] Dang xoa sach toan bo file va thu muc tam..." -ForegroundColor DarkCyan
    try {
        if ((Get-Location).Path -like "$baseDir*") {
            Set-Location "$env:SystemDrive\"
        }
    } catch { }

    Start-Sleep -Milliseconds 350

    # Xóa sạch toàn bộ C:\Grub4EFI_QEMU (thử lại tối đa 3 lần phòng trường hợp QEMU vừa thoát chưa nhả khóa file)
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-Path $baseDir) {
            Remove-Item $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path $baseDir)) { break }
        Start-Sleep -Milliseconds 400
    }

    # Xóa toàn bộ file/thư mục tạm sinh ra trong %TEMP% của cả quá trình cài đặt & chạy thử
    $tempPatterns = @(
        "$env:TEMP\g4e_dp_*.txt",
        "$env:TEMP\g4e_curl_*.log",
        "$env:TEMP\test_mini.7z",
        "$env:TEMP\grub4efi*",
        "$env:TEMP\Grub4EFI*"
    )
    foreach ($pat in $tempPatterns) {
        Remove-Item $pat -Recurse -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -Path $env:TEMP -Filter "g4e_test_*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $PSCommandPath -or ($_.FullName -ine $PSCommandPath)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $baseGone = -not (Test-Path $baseDir)
    if ($baseGone) {
        Write-Host "  [OK] Da xoa sach thu muc $baseDir va toan bo tep tam trong %TEMP%." -ForegroundColor Green
    } else {
        Write-Host "  [CANH BAO] Mot vai tep trong $baseDir van dang bi he thong khoa, chua xoa het duoc." -ForegroundColor Yellow
    }
    return $baseGone
}

function Show-ResultDialog {
    param(
        [bool]$Success,
        [bool]$BcdOk,
        [string]$SecureBootState,
        [bool]$EfiFilesOk,
        [int]$MissingMediaCount,
        [bool]$QemuOk,
        [bool]$CleanedAll,
        [string]$ErrorDetail,
        [string]$GrubGuid
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $hasGuid = -not [string]::IsNullOrWhiteSpace($GrubGuid)
        $formHeight = if ($hasGuid) { 495 } else { 425 }

        $form = New-Object System.Windows.Forms.Form
        $form.Text = U "K\u1EBFt qu\u1EA3 Ki\u1EC3m tra & Ch\u1EA1y th\u1EED Grub4EFI"
        $form.ClientSize = New-Object System.Drawing.Size(660, $formHeight)
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $true
        $form.BackColor = [System.Drawing.Color]::White

        # Thanh tiêu đề màu nổi bật, chữ rất to và đậm
        $banner = New-Object System.Windows.Forms.Panel
        $banner.Dock = [System.Windows.Forms.DockStyle]::Top
        $banner.Height = 82
        $banner.BackColor = if ($Success) {
            [System.Drawing.Color]::FromArgb(5, 150, 105)
        } else {
            [System.Drawing.Color]::FromArgb(220, 38, 38)
        }

        $lblHeader = New-Object System.Windows.Forms.Label
        $lblHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
        $lblHeader.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lblHeader.ForeColor = [System.Drawing.Color]::White
        $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
        $lblHeader.Text = if ($Success) {
            U "\u2713  CH\u1EA0Y TH\u1EEC TH\u00C0NH C\u00D4NG!"
        } else {
            U "\u2715  CH\u1EA0Y TH\u1EEC TH\u1EA4T B\u1EA0I!"
        }
        $banner.Controls.Add($lblHeader)
        $form.Controls.Add($banner)

        $lblSub = New-Object System.Windows.Forms.Label
        $lblSub.Location = New-Object System.Drawing.Point(24, 98)
        $lblSub.AutoSize = $true
        $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
        $lblSub.Text = U "T\u00F3m t\u1EAFt k\u1EBFt qu\u1EA3 ki\u1EC3m tra & d\u1ECDn d\u1EB9p:"
        $form.Controls.Add($lblSub)

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add($(if ($BcdOk) { U "\u2022 M\u1EE5c boot UEFI (BCD): \u0110\u1EA0T (\u0110\u00E3 c\u00F3 Grub4EFI)" } else { U "\u2022 M\u1EE5c boot UEFI (BCD): TH\u1EA4T B\u1EA0I (Ch\u01B0a th\u1EA5y Grub4EFI)" }))

        if ($SecureBootState -eq "off") {
            $lines.Add((U "\u2022 Secure Boot: \u0110ang T\u1EAET (T\u01B0\u01A1ng th\u00EDch 100%)"))
        } elseif ($SecureBootState -eq "on") {
            $lines.Add((U "\u2022 Secure Boot: \u0110ang B\u1EACT (C\u1EA7n t\u1EAFt trong BIOS khi boot th\u1EADt)"))
        } else {
            $lines.Add((U "\u2022 Secure Boot: Kh\u00F4ng \u0111\u1ECDc \u0111\u01B0\u1EE3c tr\u1EA1ng th\u00E1i"))
        }

        $lines.Add($(if ($EfiFilesOk) { U "\u2022 File EFI (grub4efi.efi & menu.lst): \u0110\u1EA6Y \u0110\u1EE6" } else { U "\u2022 File EFI (grub4efi.efi & menu.lst): THI\u1EBEU FILE" }))

        if ($EfiFilesOk) {
            if ($MissingMediaCount -eq 0) {
                $lines.Add((U "\u2022 File ISO/WIM/VHD trong menu.lst: \u0110\u1EA7y \u0111\u1EE7 tr\u00EAn \u1ED5 \u0111\u0129a"))
            } else {
                $lines.Add(((U "\u2022 File ISO/WIM/VHD trong menu.lst: C\u1EA2NH B\u00C1O thi\u1EBFu file") + " ($MissingMediaCount)"))
            }
        }

        $lines.Add($(if ($QemuOk) { U "\u2022 M\u00E1y \u1EA3o QEMU UEFI: \u0110\u00E3 ch\u1EA1y th\u1EED & tho\u00E1t an to\u00E0n" } else { U "\u2022 M\u00E1y \u1EA3o QEMU UEFI: Kh\u00F4ng ch\u1EA1y \u0111\u01B0\u1EE3c / Th\u1EA5t b\u1EA1i" }))
        $lines.Add($(if ($CleanedAll) { U "\u2022 D\u1ECDn d\u1EB9p t\u1EA1m: \u0110\u00C3 X\u00D3A S\u1EA0CH th\u01B0 m\u1EE5c & file t\u1EA1m!" } else { U "\u2022 D\u1ECDn d\u1EB9p t\u1EA1m: \u0110\u00E3 d\u1ECDn h\u1EA7u h\u1EBFt file t\u1EA1m" }))

        if (-not [string]::IsNullOrWhiteSpace($ErrorDetail)) {
            $lines.Add("")
            $lines.Add((U "Chi ti\u1EBFt l\u1ED7i:") + " " + $ErrorDetail)
        }

        $txtBox = New-Object System.Windows.Forms.TextBox
        $txtBox.Location = New-Object System.Drawing.Point(24, 130)
        $txtBox.Size = New-Object System.Drawing.Size(612, 215)
        $txtBox.Multiline = $true
        $txtBox.ReadOnly = $true
        $txtBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $txtBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $txtBox.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
        $txtBox.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $txtBox.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular)
        $txtBox.Text = ($lines -join "`r`n")
        $txtBox.TabStop = $false
        $form.Controls.Add($txtBox)

        $btnY = 362
        if ($hasGuid) {
            $bootSeqCmd = "bcdedit /set {fwbootmgr} bootsequence $GrubGuid"

            $lblHint = New-Object System.Windows.Forms.Label
            $lblHint.Location = New-Object System.Drawing.Point(24, 355)
            $lblHint.AutoSize = $true
            $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(3, 105, 161)
            $lblHint.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
            $lblHint.Text = U "L\u1EC7nh test boot 1 l\u1EA7n an to\u00E0n tr\u00EAn m\u00E1y th\u1EADt (kh\u00F4ng \u0111\u1ED5i th\u1EE9 t\u1EF1 boot):"
            $form.Controls.Add($lblHint)

            $txtCmd = New-Object System.Windows.Forms.TextBox
            $txtCmd.Location = New-Object System.Drawing.Point(24, 382)
            $txtCmd.Size = New-Object System.Drawing.Size(612, 32)
            $txtCmd.ReadOnly = $true
            $txtCmd.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
            $txtCmd.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
            $txtCmd.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
            $txtCmd.Text = $bootSeqCmd
            $form.Controls.Add($txtCmd)

            $btnY = 430

            $btnCopy = New-Object System.Windows.Forms.Button
            $btnCopy.Location = New-Object System.Drawing.Point(24, $btnY)
            $btnCopy.Size = New-Object System.Drawing.Size(250, 46)
            $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $btnCopy.ForeColor = [System.Drawing.Color]::White
            $btnCopy.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btnCopy.FlatAppearance.BorderSize = 0
            $btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
            $btnCopy.Text = U "Copy l\u1EC7nh boot 1 l\u1EA7n"
            $btnCopy.Tag = @{ Cmd = $bootSeqCmd; CopiedText = (U "\u2713 \u0110\u00E3 Copy!") }
            $btnCopy.Add_Click({
                param($s, $e)
                try {
                    [System.Windows.Forms.Clipboard]::SetText($s.Tag.Cmd)
                    $s.Text = $s.Tag.CopiedText
                    $s.BackColor = [System.Drawing.Color]::FromArgb(5, 150, 105)
                } catch { }
            })
            $form.Controls.Add($btnCopy)
        }

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Location = New-Object System.Drawing.Point(456, $btnY)
        $btnClose.Size = New-Object System.Drawing.Size(180, 46)
        $btnClose.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $btnClose.ForeColor = [System.Drawing.Color]::White
        $btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnClose.FlatAppearance.BorderSize = 0
        $btnClose.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
        $btnClose.Text = U "\u0110\u00D3NG"
        $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnClose)

        $form.AcceptButton = $btnClose
        $form.CancelButton = $btnClose
        $form.Add_Shown({ $form.Activate(); $btnClose.Focus() })

        $form.ShowDialog() | Out-Null
        $form.Dispose()
        return $true
    } catch {
        return $false
    }
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "   KIEM TRA KET QUA CAI DAT THUC TE & BOOT THU TRONG QEMU" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

$bcdOk = $false
$sbState = "unknown"
$efiFilesOk = $false
$missingMedia = 0
$qemuOk = $false
$failReason = ""
$grubGuid = $null

$BaseDir = "C:\Grub4EFI_QEMU"
$MiniDir = Join-Path $BaseDir "qemu-uefi-mini"
$EspDir  = Join-Path $BaseDir "esp"

try {
    # === PHẦN 1: KIỂM TRA UEFI NVRAM / BCD THẬT ===
    Write-Host "`n[1/4] Kiem tra muc khoi dong trong UEFI NVRAM (bcdedit)..." -ForegroundColor Yellow
    $fwText = (& bcdedit /enum firmware | Out-String)
    $blocks = $fwText -split "(\r?\n){2,}"
    $grubBlock = $blocks | Where-Object { $_ -match "\\EFI\\grub\\grub4efi\.efi" -or $_ -match "Grub4EFI" } | Select-Object -First 1

    if ($grubBlock) {
        $bcdOk = $true
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
        $failReason = "Chua tim thay muc boot Grub4EFI trong UEFI NVRAM (bcdedit). Hay chay Muc 1 truoc."
    }

    # === PHẦN 2: KIỂM TRA SECURE BOOT ===
    Write-Host "`n[2/4] Kiem tra trang thai Secure Boot..." -ForegroundColor Yellow
    try {
        if (Confirm-SecureBootUEFI) {
            $sbState = "on"
            Write-Host "  [CANH BAO] Secure Boot dang BAT! May that se chan Grub4EFI tru khi tat Secure Boot trong BIOS." -ForegroundColor Yellow
        } else {
            $sbState = "off"
            Write-Host "  [PASS] Secure Boot dang TAT - Tuong thich 100% voi Grub4EFI." -ForegroundColor Green
        }
    } catch {
        $sbState = "unknown"
        Write-Host "  [INFO] Khong doc duoc trang thai Secure Boot." -ForegroundColor Gray
    }

    # === PHẦN 3: KIỂM TRA FILE THẬT TRÊN PHÂN VÙNG EFI & QUÉT FILE ISO/WIM/VHD TRONG MENU.LST ===
    Write-Host "`n[3/4] Kiem tra file that tren phan vung EFI & duong dan trong menu.lst..." -ForegroundColor Yellow
    [System.IO.Directory]::CreateDirectory($BaseDir) | Out-Null
    if (Test-Path $EspDir) { Remove-Item $EspDir -Recurse -Force }
    [System.IO.Directory]::CreateDirectory("$EspDir\EFI\BOOT") | Out-Null
    [System.IO.Directory]::CreateDirectory("$EspDir\EFI\grub") | Out-Null

    $hasEfiBin = $false
    $hasMenuFile = $false
    $efi = Mount-ActiveEfi
    try {
        $realEfiFile = "$($efi.Drive)\EFI\grub\grub4efi.efi"
        $realMenuLst = "$($efi.Drive)\EFI\grub\menu.lst"

        if ([System.IO.File]::Exists($realEfiFile)) {
            $hasEfiBin = $true
            $efiKB = [math]::Round((Get-Item $realEfiFile).Length / 1KB, 1)
            Write-Host "  [PASS] Co file that: $realEfiFile ($efiKB KB)" -ForegroundColor Green
            [System.IO.File]::Copy($realEfiFile, "$EspDir\EFI\BOOT\BOOTX64.EFI", $true)
        } else {
            Write-Host "  [FAIL] Khong thay file $realEfiFile!" -ForegroundColor Red
        }

        if ([System.IO.File]::Exists($realMenuLst)) {
            $hasMenuFile = $true
            $menuContent = [System.IO.File]::ReadAllText($realMenuLst)
            Write-Host "  [PASS] Co file that: $realMenuLst" -ForegroundColor Green
            [System.IO.File]::Copy($realMenuLst, "$EspDir\EFI\grub\menu.lst", $true)
            [System.IO.File]::Copy($realMenuLst, "$EspDir\EFI\BOOT\menu.lst", $true)

            Write-Host "`n  --- NOI DUNG MENU.LST DANG CAI TREN MAY ---" -ForegroundColor DarkCyan
            Write-Host $menuContent -ForegroundColor Gray
            Write-Host "  -------------------------------------------" -ForegroundColor DarkCyan

            $allDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') })
            $matches = [regex]::Matches($menuContent, "find\s+--set-root(?:\s+--\S+)*\s+([^\r\n]+)")
            foreach ($mt in $matches) {
                $relPath = $mt.Groups[1].Value.Trim().Trim('"')
                $winRel  = $relPath -replace '/', '\'
                $foundAt = @()
                foreach ($drv in $allDrives) {
                    if ([System.IO.File]::Exists("$drv$winRel")) { $foundAt += "$drv$winRel" }
                }
                if ($foundAt.Count -gt 0) {
                    Write-Host "  [PASS] File ton tai tren may: $relPath -> Tim thay tai $($foundAt -join ', ')" -ForegroundColor Green
                } else {
                    $missingMedia++
                    Write-Host "  [CANH BAO] Khong thay file '$relPath' tren bat ky o dia nao! Khi boot chon muc nay se bao loi 'File not found'." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  [FAIL] Khong thay file $realMenuLst!" -ForegroundColor Red
        }
    } finally {
        Dismount-ActiveEfi $efi
    }

    $efiFilesOk = ($hasEfiBin -and $hasMenuFile)
    if (-not $efiFilesOk -and [string]::IsNullOrEmpty($failReason)) {
        $failReason = "Thieu file grub4efi.efi hoac menu.lst tren phan vung EFI."
    }

    if (-not ($bcdOk -and $efiFilesOk)) {
        Write-Host "`n[KET LUAN] Cau hinh chua day du, hay sua cac muc [FAIL] o tren truoc khi boot thu." -ForegroundColor Red
        return
    }

    # === PHẦN 4: CHẠY THỬ CHÍNH BỘ GRUB4EFI + MENU.LST THẬT TRONG QEMU UEFI MINI ===
    Write-Host "`n[4/4] Chay thu chinh grub4efi.efi va menu.lst vua cai trong may ao QEMU UEFI..." -ForegroundColor Yellow
    $qemuExe = Find-QemuBinary $MiniDir

    if (-not $qemuExe) {
        Install-MiniQemuPortable -baseDir $BaseDir -miniDir $MiniDir
        $qemuExe = Find-QemuBinary $MiniDir
    }

    if (-not $qemuExe) { throw "Khong tim thay qemu-system-x86_64.exe va firmware UEFI sau khi giai nen!" }
    $ovmfPath = Find-OvmfFirmware $qemuExe

    Write-Host "  [OK] Su dung QEMU: $qemuExe" -ForegroundColor Green
    Write-Host "  [DANG MO QEMU] Hien thi chinh xac giao dien Grub4EFI & menu.lst that cua may ban..." -ForegroundColor Magenta

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
        $qemuProc = Start-Process -FilePath $qemuExe -ArgumentList ($qemuArgs -join " ") -Wait -PassThru
        if ($qemuProc.ExitCode -eq 0) {
            $qemuOk = $true
            Write-Host "`n[HOAN TAT] May ao QEMU da chay va dong binh thuong!" -ForegroundColor Green
        } else {
            $failReason = "QEMU thoat voi ma loi: $($qemuProc.ExitCode)"
            Write-Host "`n[LOI] $failReason" -ForegroundColor Red
        }
    } finally {
        Pop-Location
    }
} catch {
    $failReason = $_.Exception.Message
    Write-Host "[LOI] $failReason" -ForegroundColor Red
} finally {
    # Tự động xóa sạch toàn bộ file & thư mục tạm sau khi chạy thử
    $cleanedAll = Clear-AllTempFiles -baseDir $BaseDir
    $overallSuccess = ($bcdOk -and $efiFilesOk -and $qemuOk -and [string]::IsNullOrEmpty($failReason))

    $shown = Show-ResultDialog `
        -Success $overallSuccess `
        -BcdOk $bcdOk `
        -SecureBootState $sbState `
        -EfiFilesOk $efiFilesOk `
        -MissingMediaCount $missingMedia `
        -QemuOk $qemuOk `
        -CleanedAll $cleanedAll `
        -ErrorDetail $failReason `
        -GrubGuid $grubGuid

    if (-not $shown) {
        Read-Host "`nNhan Enter de hoan tat" | Out-Null
    }
}