# setup-windows.ps1 - tweak khas Windows untuk sesi RDP yang nyaman:
#  + power plan High Performance, matikan sleep/hibernate (VM tidak tidur di tengah sesi)
#  + Explorer: tampilkan ekstensi file & file tersembunyi (lewat hive Default User,
#    jadi berlaku untuk user RDP saat pertama login)
#  + long paths aktif
#  + redirection RDP eksplisit: clipboard, drive, dan audio boleh dipakai klien
#  + policy Windows Installer dilonggarkan (DisableMSI=0) - image runner GitHub
#    memblokir install .msi dari sesi interaktif ("The system administrator has
#    set policies to prevent this installation", temuan Run pertama v1.0.0)
#  + shortcut Public Desktop: folder C:\RDPData + file info koneksi
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:windows"
. (Join-Path $PSScriptRoot "lib-common.ps1")

# --- Power: High Performance + tanpa sleep ---
try {
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null  # High Performance GUID
    powercfg /change standby-timeout-ac 0 2>$null | Out-Null
    powercfg /change hibernate-timeout-ac 0 2>$null | Out-Null
    powercfg /hibernate off 2>$null | Out-Null
    Write-Log "Power plan: High Performance, sleep/hibernate off."
} catch { Write-Warn ("Power plan gagal diset: " + $_.Exception.Message) }

# --- Long paths ---
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord
    Write-Log "Long paths aktif."
} catch { }

# --- Explorer untuk user baru (Default User hive) ---
$hiveLoaded = $false
try {
    reg load "HKU\RDPfreadDefault" "C:\Users\Default\NTUSER.DAT" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $hiveLoaded = $true
        # Pakai path provider Registry:: - drive HKU: tidak tersedia secara
        # default di PowerShell, jadi HKU:\... selalu gagal (bug v1.0.0-1.0.3).
        $adv = "Registry::HKEY_USERS\RDPfreadDefault\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path $adv)) { New-Item -Path $adv -Force | Out-Null }
        Set-ItemProperty -Path $adv -Name "HideFileExt" -Value 0 -Type DWord
        Set-ItemProperty -Path $adv -Name "Hidden" -Value 1 -Type DWord
        Set-ItemProperty -Path $adv -Name "ShowSuperHidden" -Value 0 -Type DWord
        Write-Log "Explorer Default User: ekstensi file & file tersembunyi ditampilkan."
    } else { Write-Warn "Hive Default User tidak bisa dimuat - tweak Explorer dilewati." }
} catch { Write-Warn ("Tweak Explorer gagal: " + $_.Exception.Message) }
finally {
    if ($hiveLoaded) { [gc]::Collect(); reg unload "HKU\RDPfreadDefault" 2>$null | Out-Null }
}

# --- Windows Installer: izinkan install .msi dari sesi desktop ---
# Catatan keamanan: yang dilonggarkan hanya DisableMSI/DisableUserInstalls.
# AlwaysInstallElevated SENGAJA tidak diaktifkan (itu setara memberi admin ke
# semua proses user dan dianggap lubang keamanan oleh Microsoft).
try {
    $instKey = "HKLM:\Software\Policies\Microsoft\Windows\Installer"
    if (-not (Test-Path $instKey)) { New-Item -Path $instKey -Force | Out-Null }
    Set-ItemProperty -Path $instKey -Name "DisableMSI" -Value 0 -Type DWord
    Set-ItemProperty -Path $instKey -Name "DisableUserInstalls" -Value 0 -Type DWord
    Write-Log "Policy Windows Installer dilonggarkan (DisableMSI=0) - install .msi dari desktop diizinkan."
} catch { Write-Warn ("Set policy Installer gagal: " + $_.Exception.Message) }

# --- Redirection RDP: clipboard / drive / audio diizinkan dari klien ---
try {
    $tsKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path $tsKey)) { New-Item -Path $tsKey -Force | Out-Null }
    Set-ItemProperty -Path $tsKey -Name "fDisableClip" -Value 0 -Type DWord
    Set-ItemProperty -Path $tsKey -Name "fDisableCdm" -Value 0 -Type DWord
    Set-ItemProperty -Path $tsKey -Name "fDisablePNPRedir" -Value 0 -Type DWord
    Write-Log "Redirection clipboard/drive/PnP diizinkan (tetap hanya dari tailnet karena firewall)."
} catch { Write-Warn ("Set redirection gagal: " + $_.Exception.Message) }

# --- Shortcut di Public Desktop (muncul di desktop semua user) ---
try {
    $shell = New-Object -ComObject WScript.Shell
    $pubDesktop = "C:\Users\Public\Desktop"
    $lnk = $shell.CreateShortcut((Join-Path $pubDesktop "RDPData (folder persisten).lnk"))
    $lnk.TargetPath = "C:\RDPData"
    $lnk.Description = "Folder kerja persisten RDPfread - file di sini ikut disimpan antar sesi"
    $lnk.Save()
    Write-Log "Shortcut RDPData dibuat di Public Desktop."
} catch { Write-Warn ("Shortcut gagal dibuat: " + $_.Exception.Message) }

Update-Status @{ windows_tweaks = $true }
Write-Log "Tweak Windows selesai."
