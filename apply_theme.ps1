$ErrorActionPreference = "Stop"

# Tự động nâng quyền Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $tmp = Join-Path $env:TEMP "g4e_theme_$(Get-Random).ps1"
    [System.IO.File]::WriteAllText($tmp, $MyInvocation.MyCommand.Definition, [System.Text.Encoding]::UTF8)
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`"" -Verb RunAs
    return
}

if ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -like "g4e_theme_*.ps1") {
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
    if ($allEsps.Count -eq 0) { throw "Khong tim thay phan vung EFI!" }

    $targetEsp = $null; $targetVolGuid = $null
    foreach ($p in $allEsps) {
        $vGuid = ($p.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
        if (-not $vGuid) {
            $vObj = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($vObj -and $vObj.UniqueId) { $vGuid = $vObj.UniqueId }
        }
        $ntPath = if ($vGuid) { [Win32VolHelper]::GetNtPath($vGuid) } else { "" }
        if ($bootDevice -and $ntPath -and ($ntPath -ieq $bootDevice)) { $targetEsp = $p; $targetVolGuid = $vGuid; break }
    }
    if (-not $targetEsp) {
        $osDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
        $targetEsp = $allEsps | Sort-Object -Property @{Expression={$_.IsSystem};Descending=$true}, @{Expression={$_.DiskNumber -eq $osDisk};Descending=$true} | Select-Object -First 1
        $targetVolGuid = ($targetEsp.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' } | Select-Object -First 1)
    }

    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1).ToUpper() })
    $free = @('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M') | Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $free) { throw "Khong con ky tu o dia trong de mount EFI!" }
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
    throw "Khong the mount phan vung EFI!"
}

function Dismount-ActiveEfi($efiInfo) {
    if (-not $efiInfo -or -not $efiInfo.MountedByUs -or -not $efiInfo.Drive) { return }
    if ($efiInfo.Method -eq "mountvol") {
        Start-Process -FilePath "mountvol.exe" -ArgumentList "$($efiInfo.Drive) /D" -Wait -NoNewWindow | Out-Null
    } elseif ($efiInfo.Method -eq "diskpart") {
        Invoke-DiskpartScript "select disk $($efiInfo.Disk)`r`nselect partition $($efiInfo.Part)`r`nremove letter=$($efiInfo.Letter)`r`n" | Out-Null
    }
}

function New-GrubWallpaper([string]$outJpg, [hashtable]$palette) {
    Add-Type -AssemblyName System.Drawing
    $w = 1024; $h = 768
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $palette.BgTop, $palette.BgBot, 45.0)
        $g.FillRectangle($bgBrush, $rect)
        $bgBrush.Dispose()

        foreach ($glow in @(
            @{ X = -120; Y = -120; W = 680; H = 680; C = $palette.Glow1 },
            @{ X = 520;  Y = 260;  W = 640; H = 640; C = $palette.Glow2 }
        )) {
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse($glow.X, $glow.Y, $glow.W, $glow.H)
            $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
            $pgb.CenterColor = $glow.C
            $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $glow.C.R, $glow.C.G, $glow.C.B))
            $g.FillPath($pgb, $path)
            $pgb.Dispose(); $path.Dispose()
        }

        $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(14, 255, 255, 255), 1)
        for ($x = 0; $x -lt $w; $x += 48) { $g.DrawLine($gridPen, $x, 0, $x, $h) }
        for ($y = 0; $y -lt $h; $y += 48) { $g.DrawLine($gridPen, 0, $y, $w, $y) }
        $gridPen.Dispose()

        $topPen = New-Object System.Drawing.Pen($palette.Accent, 3)
        $g.DrawLine($topPen, 0, 1, $w, 1)
        $topPen.Dispose()

        $divPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(65, $palette.Accent.R, $palette.Accent.G, $palette.Accent.B), 1)
        $g.DrawLine($divPen, 126, 175, 898, 175)
        $g.DrawLine($divPen, 126, 675, 898, 675)
        $divPen.Dispose()

        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]92)
        $bmp.Save($outJpg, $codec, $encParams)
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}

$themes = @{
    "1" = @{
        Name      = "Cyber Dark Blue"
        BgTop     = [System.Drawing.Color]::FromArgb(2, 6, 23)
        BgBot     = [System.Drawing.Color]::FromArgb(15, 23, 42)
        Glow1     = [System.Drawing.Color]::FromArgb(75, 14, 165, 233)
        Glow2     = [System.Drawing.Color]::FromArgb(65, 99, 102, 241)
        Accent    = [System.Drawing.Color]::FromArgb(56, 189, 248)
        Normal    = "0xE2E8F0"
        Highlight = "0x000284C700FFFFFF"
        Help      = "0x94A3B8"
        Heading   = "0x38BDF8"
        Border    = "0x38BDF8"
        Timer     = "0xFACC15"
    }
    "2" = @{
        Name      = "Emerald Tech"
        BgTop     = [System.Drawing.Color]::FromArgb(2, 20, 18)
        BgBot     = [System.Drawing.Color]::FromArgb(6, 42, 36)
        Glow1     = [System.Drawing.Color]::FromArgb(75, 16, 185, 129)
        Glow2     = [System.Drawing.Color]::FromArgb(60, 20, 184, 166)
        Accent    = [System.Drawing.Color]::FromArgb(52, 211, 153)
        Normal    = "0xECFDF5"
        Highlight = "0x0005966900FFFFFF"
        Help      = "0xA7F3D0"
        Heading   = "0x34D399"
        Border    = "0x10B981"
        Timer     = "0xFDE047"
    }
    "3" = @{
        Name      = "Midnight Violet"
        BgTop     = [System.Drawing.Color]::FromArgb(15, 7, 32)
        BgBot     = [System.Drawing.Color]::FromArgb(30, 16, 58)
        Glow1     = [System.Drawing.Color]::FromArgb(80, 168, 85, 247)
        Glow2     = [System.Drawing.Color]::FromArgb(65, 236, 72, 153)
        Accent    = [System.Drawing.Color]::FromArgb(192, 132, 252)
        Normal    = "0xF3E8FF"
        Highlight = "0x007C3AED00FFFFFF"
        Help      = "0xD8B4FE"
        Heading   = "0xE879F9"
        Border    = "0xA855F7"
        Timer     = "0xFDE047"
    }
}

$onlyBg = ($env:G4E_ONLY_BG -eq "1")
$choice = $env:G4E_THEME

if (-not $onlyBg -and ($choice -notin @("1","2","3"))) {
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "   CAI DAT GIAO DIEN DEP MAT (THEME) CHO GRUB4EFI" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  1. Cyber Dark Blue (Xanh duong cong nghe - Khuyen dung)" -ForegroundColor White
    Write-Host "  2. Emerald Tech    (Xanh ngoc thanh lich)" -ForegroundColor Green
    Write-Host "  3. Midnight Violet (Tim khong gian noi bat)" -ForegroundColor Magenta
    $choice = Read-Host "`nChon giao dien (1/2/3, mac dinh 1)"
}
if ($choice -notin @("1","2","3")) { $choice = "1" }
$t = $themes[$choice]

$efi = Mount-ActiveEfi
try {
    $grubDir = "$($efi.Drive)\EFI\grub"
    $menuPath = "$grubDir\menu.lst"
    $bgPath = "$grubDir\bg.jpg"

    if (-not [System.IO.Directory]::Exists($grubDir)) {
        throw "Khong thay thu muc $grubDir! Hay cai Grub4EFI o Muc 1 truoc."
    }

    Write-Host "`n[THEME] Dang tao anh nen $($t.Name) -> $bgPath..." -ForegroundColor Cyan
    New-GrubWallpaper -outJpg $bgPath -palette $t
    $bgKB = [math]::Round((Get-Item $bgPath).Length / 1KB, 1)
    Write-Host "  [OK] Da luu hinh nen thanh cong ($bgKB KB)." -ForegroundColor Green

    if (-not $onlyBg) {
        $entriesBody = @"
title  [1]  Khoi dong Windows OS
find --set-root /EFI/Microsoft/Boot/bootmgfw.efi
chainloader /EFI/Microsoft/Boot/bootmgfw.efi
"@
        if ([System.IO.File]::Exists($menuPath)) {
            [System.IO.File]::Copy($menuPath, "$menuPath.bak", $true)
            $oldContent = [System.IO.File]::ReadAllText($menuPath)
            $m = [regex]::Match($oldContent, "(?m)^\s*(?:title|iftitle)\b")
            if ($m.Success) { $entriesBody = $oldContent.Substring($m.Index).Trim() }
        }

        $header = @"
timeout 5
default 0

# === THEME: $($t.Name) ===
graphicsmode -1 1024 768
splashimage /EFI/grub/bg.jpg
color normal=$($t.Normal) highlight=$($t.Highlight) helptext=$($t.Help) heading=$($t.Heading) standard=0xCBD5E1 border=$($t.Border)
setmenu --lang=en --font-spacing=1:10 --highlight-full --ver-off --triangle-off --keyhelp-off
setmenu --box x=14 w=0 y=8 h=11 l=1
setmenu --help=14=0=20
setmenu --timeout=14=22=$($t.Timer)
setmenu --string==3=$($t.Heading)="GRUB4EFI   UEFI   BOOT   STUDIO"
setmenu --string==5=$($t.Help)="date&time=yyyy-MM-dd   HH:mm:ss"
setmenu --string==-2=$($t.Help)="[Up/Down] Chon   |   [Enter] Khoi dong   |   [E] Sua lenh   |   [C] Console"

"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($menuPath, $header + $entriesBody + "`r`n", $utf8NoBom)
        Write-Host "  [HOAN TAT] Da cap nhat $menuPath voi giao dien $($t.Name)!" -ForegroundColor Green
    }
} finally {
    Dismount-ActiveEfi $efi
    $env:G4E_ONLY_BG = $null
}

if (-not $onlyBg) {
    Read-Host "`nNhan Enter de dong" | Out-Null
}
