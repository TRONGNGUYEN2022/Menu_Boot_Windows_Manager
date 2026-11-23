$ErrorActionPreference = "Stop"

function Get-TargetDataDrive([string]$preferred) {
    if ($preferred -and $preferred -ine "AUTO") {
        $drv = $preferred.Trim().TrimEnd('\')
        if ($drv -notmatch ':$') { $drv += ':' }
        $info = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.Name.TrimEnd('\') -ieq $drv } | Select-Object -First 1
        if ($info) { return $drv }
    }

    $fixed = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.TotalSize -ge 2GB -and ($_.DriveFormat -in @('NTFS', 'FAT32', 'exFAT'))
    })
    if ($fixed.Count -eq 0) { return $env:SystemDrive }

    $nonOs = @($fixed | Where-Object { $_.Name.TrimEnd('\') -ine $env:SystemDrive } | Sort-Object AvailableFreeSpace -Descending)
    if ($nonOs.Count -gt 0) { return $nonOs[0].Name.TrimEnd('\') }
    return ($fixed | Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1).Name.TrimEnd('\')
}

function Copy-FileWithProgress([string]$src, [string]$dst) {
    $dstDir = Split-Path $dst -Parent
    if (-not [System.IO.Directory]::Exists($dstDir)) {
        [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
    }
    $total = (Get-Item $src).Length
    $inStream  = [System.IO.File]::OpenRead($src)
    $outStream = [System.IO.File]::Create($dst)
    try {
        $buf = New-Object byte[] (4MB)
        $copied = [int64]0
        $nextMilestone = 25
        Write-Host "  [DANG COPY] $src -> $dst ($([math]::Round($total/1MB, 1)) MB)..." -ForegroundColor Cyan
        while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $outStream.Write($buf, 0, $read)
            $copied += $read
            if ($total -gt 0) {
                $pct = [int](($copied * 100) / $total)
                if ($pct -ge $nextMilestone -or $pct -eq 100) {
                    Write-Host "    ... $pct% ($([math]::Round($copied/1MB, 1)) / $([math]::Round($total/1MB, 1)) MB)" -ForegroundColor Gray
                    while ($nextMilestone -le $pct) { $nextMilestone += 25 }
                }
            }
        }
        Write-Host "  [XONG] Da copy thanh cong toi $dst" -ForegroundColor Green
    } finally {
        $outStream.Dispose()
        $inStream.Dispose()
    }
}

function Find-SourceFileOnDisk([string]$fileName, [string]$excludePath) {
    $searchDirs = New-Object System.Collections.Generic.List[string]
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    foreach ($sub in @("Downloads", "Desktop", "Documents")) {
        $p = Join-Path $userProfile $sub
        if ([System.IO.Directory]::Exists($p)) { $searchDirs.Add($p) }
    }

    $skipNames = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'PerfLogs')
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady -and ($d.DriveType -in @('Fixed', 'Removable'))) {
            $root = $d.Name
            $searchDirs.Add($root)
            try {
                foreach ($subDir in [System.IO.Directory]::GetDirectories($root)) {
                    $leaf = Split-Path $subDir -Leaf
                    if ($leaf -notin $skipNames -and -not $leaf.StartsWith('$')) {
                        $searchDirs.Add($subDir)
                    }
                }
            } catch { }
        }
    }

    foreach ($dir in ($searchDirs | Select-Object -Unique)) {
        $candidate = Join-Path $dir $fileName
        if ([System.IO.File]::Exists($candidate) -and ($candidate -ine $excludePath)) {
            return $candidate
        }
    }
    return $null
}

function Prompt-PickSourceFile([string]$expectedName, [string]$destPath) {
    $ext = [System.IO.Path]::GetExtension($expectedName).ToLower()
    $filter = switch ($ext) {
        ".iso"  { "ISO Image (*.iso)|*.iso|All Files (*.*)|*.*" }
        ".wim"  { "WIM Image (*.wim)|*.wim|All Files (*.*)|*.*" }
        ".vhd"  { "VHD/VHDX Disk (*.vhd;*.vhdx)|*.vhd;*.vhdx|All Files (*.*)|*.*" }
        ".vhdx" { "VHD/VHDX Disk (*.vhd;*.vhdx)|*.vhd;*.vhdx|All Files (*.*)|*.*" }
        default { "Boot Image (*.iso;*.wim;*.vhd;*.vhdx)|*.iso;*.wim;*.vhd;*.vhdx|All Files (*.*)|*.*" }
    }

    if ([System.Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
        $owner = $null
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = "Chon file '$expectedName' de copy sang $destPath"
            $dlg.Filter = $filter
            $dlg.FileName = $expectedName
            $dlg.Multiselect = $false
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                return $dlg.FileName
            }
            return $null
        } catch {
        } finally {
            if ($owner) { $owner.Dispose() }
        }
    }

    $manual = Read-Host "  Keo tha file '$expectedName' vao day roi nhan Enter (de trong de bo qua)"
    if ($manual) {
        $clean = $manual.Trim().Trim('"')
        if ([System.IO.File]::Exists($clean)) { return $clean }
    }
    return $null
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "   CHUAN BI THU MUC ISO / WIM / VHD & DONG BO FILE BOOT" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

$targetDrive = Get-TargetDataDrive $env:G4E_DATA_DRIVE
foreach ($folderName in @("ISO", "WIM", "VHD")) {
    $fullDir = "$targetDrive\$folderName"
    if (-not [System.IO.Directory]::Exists($fullDir)) {
        [System.IO.Directory]::CreateDirectory($fullDir) | Out-Null
        Write-Host "  [TAO MOI] $fullDir" -ForegroundColor Green
    } else {
        Write-Host "  [SAN SANG] $fullDir" -ForegroundColor DarkGreen
    }
}

if (-not $env:G4E_MENU) {
    Write-Host "  [INFO] Khong co noi dung menu.lst can dong bo file." -ForegroundColor Gray
    return
}

try {
    $menuText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($env:G4E_MENU))
} catch {
    Write-Host "  [CANH BAO] Khong giai ma duoc G4E_MENU: $($_.Exception.Message)" -ForegroundColor Yellow
    return
}

$allReadyDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') })
$relPaths = New-Object System.Collections.Generic.List[string]
foreach ($mt in [regex]::Matches($menuText, "find\s+--set-root(?:\s+--\S+)*\s+([^\r\n]+)")) {
    $p = $mt.Groups[1].Value.Trim().Trim('"')
    if ($p -match "^/(ISO|WIM|VHD)/" -and -not $relPaths.Contains($p)) {
        $relPaths.Add($p)
    }
}

if ($relPaths.Count -eq 0) {
    Write-Host "  [INFO] Menu hien tai khong chua file ISO/WIM/VHD nao can copy." -ForegroundColor Gray
    return
}

foreach ($relPath in $relPaths) {
    $winRel = $relPath -replace '/', '\'
    $alreadyAt = $null
    foreach ($drv in $allReadyDrives) {
        if ([System.IO.File]::Exists("$drv$winRel")) {
            $alreadyAt = "$drv$winRel"
            break
        }
    }

    if ($alreadyAt) {
        Write-Host "  [DA CO SAN] $relPath -> Tim thay tai $alreadyAt (bo qua copy)" -ForegroundColor Green
        continue
    }

    $destPath = "$targetDrive$winRel"
    $fileName = Split-Path $winRel -Leaf
    Write-Host "`n  [CHUA THAY] $relPath chua co trong thu muc ISO/WIM/VHD tren cac o dia." -ForegroundColor Yellow
    $foundSrc = Find-SourceFileOnDisk -fileName $fileName -excludePath $destPath

    if ($foundSrc) {
        Write-Host "  [TIM THAY NGUON] $foundSrc" -ForegroundColor Green
        Copy-FileWithProgress -src $foundSrc -dst $destPath
    } else {
        Write-Host "  [CHON FILE] Mo hop thoai chon file nguon cho '$fileName'..." -ForegroundColor Cyan
        $picked = Prompt-PickSourceFile -expectedName $fileName -destPath $destPath
        if ($picked) {
            if ($picked -ieq $destPath) {
                Write-Host "  [OK] File da o dung vi tri $destPath" -ForegroundColor Green
            } else {
                Copy-FileWithProgress -src $picked -dst $destPath
            }
        } else {
            Write-Host "  [BO QUA] Ban chua chon file nguon cho '$fileName'. Hay copy thu cong vao $destPath sau." -ForegroundColor Yellow
        }
    }
}
