# debloat-windows.ps1 - debloat tingkat BERAT (v1.3.0; sejak v1.5.0 dipilih
# lewat input debloat untuk preset apa pun, dan otomatis untuk preset
# "optimize"). Tingkat lanjutannya: debloat-full.ps1 (input debloat=full).
# Berjalan sebagai step workflow tersendiri SETELAH preset terpasang dan
# SEBELUM logon pertama, di atas debloat ringan optimize-storage.ps1.
# Tujuan: sesi RDP seringan & secepat mungkin di VM GitHub sekali pakai
# (4 vCPU / 16 GB / tanpa GPU). Semua langkah best effort + tercatat di
# status "debloat". Isi:
#   1) Buang AppX bloatware konsumen (Xbox, Copilot, Clipchamp, Teams
#      konsumen, Widgets, dll) - terpasang + provisioned. Paket kerangka
#      (VCLibs/UI.Xaml/.NET Native), DesktopAppInstaller (winget), Store,
#      Edge, Windows Security, Snipping Tool & Paint SENGAJA tidak disentuh.
#   2) OneDrive: hentikan + uninstall bila ada.
#   3) Service latar tambahan dimatikan (error reporting, Xbox Live,
#      sinkronisasi, Windows Update selama sesi, dll).
#   4) Defender: real-time monitoring dimatikan (VM sesi sekali pakai,
#      tailnet-only; gagal senyap bila Tamper Protection menahan).
#   5) Skema daya Ultimate Performance.
#   6) Efek visual = performa (hive Default User, berlaku untuk profil
#      baru) + Game DVR mati + aplikasi latar diblokir via policy.
#   7) Task terjadwal telemetri/kompatibilitas dimatikan.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:debloat"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$hasil = [ordered]@{ appx_dihapus = 0; service_dimatikan = 0; defender_rt_off = $false; ultimate_perf = $false; visual_perf = $false; onedrive = $false; task_dimatikan = 0; default_hive_ok = $true }

# ---------- 1) AppX bloatware ----------
$removeNames = @(
    "Microsoft.XboxApp", "Microsoft.GamingApp", "Microsoft.XboxGameOverlay",
    "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay", "Microsoft.Xbox.TCUI",
    "Microsoft.YourPhone", "Microsoft.GetHelp", "Microsoft.Getstarted",
    "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People",
    "Microsoft.Todos", "Microsoft.BingNews", "Microsoft.BingWeather",
    "Microsoft.WindowsFeedbackHub", "Microsoft.Clipchamp",
    "MicrosoftTeams", "Microsoft.Copilot", "Microsoft.Windows.Copilot",
    "MicrosoftCorporationII.MicrosoftFamily", "Microsoft.Office.OneNote",
    "Microsoft.OutlookForWindows", "Microsoft.PowerAutomateDesktop",
    "Microsoft.Windows.DevHome", "Microsoft.MicrosoftOfficeHub",
    "MicrosoftWindows.Client.WebExperience", "Microsoft.SkypeApp",
    "Microsoft.ZuneMusic", "Microsoft.ZuneVideo",
    "Microsoft.MixedReality.Portal", "Microsoft.WindowsMaps"
)
try {
    foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
        if ($removeNames -contains $pkg.Name) {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop; $hasil.appx_dihapus++; Write-Log "AppX dihapus: $($pkg.Name)" }
            catch { try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue; $hasil.appx_dihapus++ } catch { } }
        }
    }
    foreach ($pp in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
        if ($removeNames -contains $pp.DisplayName) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue | Out-Null; Write-Log "AppX provisioned dihapus: $($pp.DisplayName)" } catch { }
        }
    }
    Write-Log "Debloat AppX selesai: $($hasil.appx_dihapus) paket terpasang dihapus."
} catch { Write-Warn ("Debloat AppX dilewati: " + $_.Exception.Message) }

# ---------- 2) OneDrive ----------
try {
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($setup in @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")) {
        if (Test-Path $setup) { Start-Process $setup "/uninstall" -Wait -ErrorAction SilentlyContinue; $hasil.onedrive = $true; Write-Log "OneDrive di-uninstall." }
    }
} catch { Write-Warn ("OneDrive dilewati: " + $_.Exception.Message) }

# ---------- 3) Service tambahan ----------
$svcExtra = @(
    "WerSvc", "RemoteRegistry",
    "XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc",
    "OneSyncSvc", "CDPSvc", "WalletService", "lfsvc", "bthserv",
    "WMPNetworkSvc", "PcaSvc", "wuauserv", "UsoSvc"
)
foreach ($svc in $svcExtra) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -ne "Stopped") { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        $hasil.service_dimatikan++
    } catch { }
}
Write-Log "Service tambahan dimatikan: $($hasil.service_dimatikan)."

# ---------- 4) Defender real-time ----------
try {
    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
        Set-MpPreference -MAPSReporting Disabled -ErrorAction SilentlyContinue
        Set-MpPreference -SubmitSamplesConsent NeverSend -ErrorAction SilentlyContinue
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        if ($pref -and $pref.DisableRealtimeMonitoring) { $hasil.defender_rt_off = $true; Write-Log "Defender real-time monitoring MATI (performa di atas proteksi - VM sesi sekali pakai)." }
        else { Write-Warn "Defender real-time masih aktif (Tamper Protection menahan?)." }
    }
} catch { Write-Warn ("Defender dilewati: " + $_.Exception.Message) }

# ---------- 5) Ultimate Performance ----------
try {
    $dup = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null | Out-String
    if ($dup -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})") {
        powercfg -setactive $Matches[1] 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $hasil.ultimate_perf = $true; Write-Log "Skema daya Ultimate Performance aktif." }
    }
} catch { Write-Warn ("Ultimate Performance dilewati: " + $_.Exception.Message) }

# ---------- 6) Efek visual & policy latar ----------
try {
    $polDvr = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    New-Item -Path $polDvr -Force | Out-Null
    Set-ItemProperty -Path $polDvr -Name AllowGameDVR -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $polBg = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
    New-Item -Path $polBg -Force | Out-Null
    Set-ItemProperty -Path $polBg -Name LetAppsRunInBackground -Value 2 -Type DWord -ErrorAction SilentlyContinue
} catch { }
try {
    $hiveName = "RDPfreadDefDebloat"
    $loaded = $false
    try {
        reg.exe load "HKU\$hiveName" "C:\Users\Default\NTUSER.DAT" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $loaded = $true
            $desk = "Registry::HKEY_USERS\$hiveName\Control Panel\Desktop"
            Set-ItemProperty -Path $desk -Name MenuShowDelay -Value "0" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $desk -Name DragFullWindows -Value "0" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $desk -Name Wallpaper -Value "" -ErrorAction SilentlyContinue
            $vf = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
            New-Item -Path $vf -Force | Out-Null
            Set-ItemProperty -Path $vf -Name VisualFXSetting -Value 2 -Type DWord -ErrorAction SilentlyContinue
            $adv = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            New-Item -Path $adv -Force | Out-Null
            Set-ItemProperty -Path $adv -Name TaskbarAnimations -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $adv -Name ListviewAlphaSelect -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $adv -Name ListviewShadow -Value 0 -Type DWord -ErrorAction SilentlyContinue
            $hasil.visual_perf = $true
            Write-Log "Efek visual profil baru = mode performa (animasi mati, tanpa wallpaper)."
        }
    } finally {
        if ($loaded) {
            # v1.5.2: pelepasan hive HARUS terverifikasi (pola setup-windows v1.5.1).
            $unloaded = $false
            for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                [System.GC]::Collect()
                reg.exe unload "HKU\$hiveName" 2>$null | Out-Null
                Start-Sleep -Seconds 2
                if (-not (Test-Path "Registry::HKEY_USERS\$hiveName")) { $unloaded = $true }
            }
            $fileLocked = $false
            try {
                $probe = [System.IO.File]::Open("C:\Users\Default\NTUSER.DAT", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                $probe.Close()
                $probe.Dispose()
            } catch { $fileLocked = $true }
            $hasil.default_hive_ok = ($unloaded -and -not $fileLocked)
            if (-not $hasil.default_hive_ok) { Write-Warn "Hive Default User GAGAL dilepas bersih setelah 3 percobaan (lihat status debloat.default_hive_ok)." }
        }
    }
} catch { Write-Warn ("Tweak visual dilewati: " + $_.Exception.Message) }

# ---------- 7) Task terjadwal telemetri/kompatibilitas ----------
$taskList = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\Feedback\Siuf\DmClient",
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)
foreach ($t in $taskList) {
    schtasks.exe /Change /TN $t /DISABLE 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $hasil.task_dimatikan++ }
}
$global:LASTEXITCODE = 0

Update-Status @{ debloat = [PSCustomObject]$hasil }
Write-Log ("Debloat selesai: appx={0} service={1} defender_rt_off={2} ultimate={3} visual={4} onedrive={5} task={6} hive_ok={7}" -f $hasil.appx_dihapus, $hasil.service_dimatikan, $hasil.defender_rt_off, $hasil.ultimate_perf, $hasil.visual_perf, $hasil.onedrive, $hasil.task_dimatikan, $hasil.default_hive_ok)
