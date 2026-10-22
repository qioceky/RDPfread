# debloat-full.ps1 - debloat tingkat FULL (v1.5.0), lanjutan debloat-windows.ps1
# (tingkat "berat"). Jalan sebagai step workflow tersendiri bila input
# debloat = "full" (preset apa pun), SETELAH step debloat berat.
# Tingkat ini memang mengorbankan kenyamanan demi keringanan maksimal di
# VM sesi sekali pakai - semua langkah best effort + tercatat di status
# "debloat_full". Isi:
#   1) AppX lapis-2: Store, Photos, Camera, Alarms, Sound Recorder,
#      Calculator, Sticky Notes, Bing Search, Windows Terminal (AppX)
#      dibuang juga. Yang TETAP tidak disentuh: paket kerangka
#      (VCLibs/UI.Xaml/.NET Native), DesktopAppInstaller (winget), Edge,
#      Windows Security, Snipping Tool, Paint, komponen shell
#      (StartMenu/ShellExperienceHost/CBS).
#   2) Fitur opsional Windows dicabut (Media Player, XPS, Work Folders,
#      PowerShell V2, Math Recognizer, Steps Recorder, WordPad, Fax/Scan,
#      Wireless Display) - hanya yang statusnya terpasang.
#   3) Defender dinonaktifkan sejauh mungkin: policy DisableAntiSpyware/
#      DisableAntiVirus + semua toggle MpPreference + service WinDefend/
#      WdNisSvc/Sense dimatikan lewat registry (efek penuh biasanya baru
#      terasa setelah reboot; VM sesi tidak reboot - status melaporkan
#      apa adanya).
#   4) Service lapis-2: BITS, Delivery Optimization, Spooler (redirection
#      printer RDP ikut mati - disadari), Phone, biometrik, hotspot/ICS,
#      sensor, PushToInstall; service Store/AppX dijadikan Manual (bukan
#      Disabled) agar pemasangan AppX manual masih mungkin.
#   5) Policy konsumen & Edge: Consumer Features mati (tidak ada unduhan
#      aplikasi saran), widget/feeds mati, Spotlight & saran lock screen
#      mati untuk profil baru (hive Default User), Edge tanpa sidebar/
#      shopping/background mode.
#   6) DISM component cleanup (WinSxS) dengan batas waktu 10 menit.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:debloat-full"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$hasil = [ordered]@{ appx2_dihapus = 0; fitur_dihapus = 0; defender_full = $false; service_full = 0; edge_policy = $false; dism_cleanup = $false }

# ---------- 1) AppX lapis-2 ----------
$removeNames2 = @(
    "Microsoft.WindowsStore", "Microsoft.Windows.Photos",
    "Microsoft.WindowsCamera", "Microsoft.WindowsAlarms",
    "Microsoft.WindowsSoundRecorder", "Microsoft.WindowsCalculator",
    "Microsoft.MicrosoftStickyNotes", "Microsoft.BingSearch",
    "Microsoft.WindowsTerminal"
)
try {
    foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
        if ($removeNames2 -contains $pkg.Name) {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop; $hasil.appx2_dihapus++; Write-Log "AppX lapis-2 dihapus: $($pkg.Name)" }
            catch { try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue; $hasil.appx2_dihapus++ } catch { } }
        }
    }
    foreach ($pp in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
        if ($removeNames2 -contains $pp.DisplayName) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue | Out-Null; Write-Log "AppX lapis-2 provisioned dihapus: $($pp.DisplayName)" } catch { }
        }
    }
    Write-Log "Debloat FULL AppX selesai: $($hasil.appx2_dihapus) paket terpasang dihapus."
} catch { Write-Warn ("AppX lapis-2 dilewati: " + $_.Exception.Message) }

# ---------- 2) Fitur opsional ----------
$fiturList = @(
    "WindowsMediaPlayer", "MicrosoftXPSDocumentWriter",
    "Printing-XPSServices-Features", "WorkFolders-Client",
    "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2",
    "Internet-Explorer-Optional-amd64", "MediaPlayback"
)
foreach ($fname in $fiturList) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $fname -ErrorAction Stop
        if ($f -and $f.State -eq "Enabled") {
            Disable-WindowsOptionalFeature -Online -FeatureName $fname -Remove -NoRestart -ErrorAction Stop | Out-Null
            $hasil.fitur_dihapus++
            Write-Log "Fitur opsional dicabut: $fname"
        }
    } catch { }
}
$capList = @("MathRecognizer", "App.StepsRecorder", "Microsoft.Windows.WordPad", "Print.Fax.Scan", "App.WirelessDisplay.Connect", "OneCoreUAP.OneSync")
foreach ($capName in $capList) {
    try {
        $caps = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like "$capName*" -and $_.State -eq "Installed" })
        foreach ($cap in $caps) {
            try { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null; $hasil.fitur_dihapus++; Write-Log "Capability dicabut: $($cap.Name)" } catch { }
        }
    } catch { }
}
Write-Log "Fitur opsional/capability dicabut: $($hasil.fitur_dihapus)."

# ---------- 3) Defender nonaktif total (upaya maksimal) ----------
try {
    $defKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender"
    New-Item -Path $defKey -Force | Out-Null
    Set-ItemProperty -Path $defKey -Name DisableAntiSpyware -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $defKey -Name DisableAntiVirus -Value 1 -Type DWord -ErrorAction SilentlyContinue
    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableArchiveScanning $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableIntrusionPreventionSystem $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableEmailScanning $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction SilentlyContinue
        Set-MpPreference -CloudBlockLevel 0 -ErrorAction SilentlyContinue
    }
    foreach ($svcDef in @("WinDefend", "WdNisSvc", "Sense", "SecurityHealthService")) {
        $svcKey = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$svcDef"
        if (Test-Path $svcKey) { Set-ItemProperty -Path $svcKey -Name Start -Value 4 -Type DWord -ErrorAction SilentlyContinue }
        Stop-Service -Name $svcDef -Force -ErrorAction SilentlyContinue
    }
    $hasil.defender_full = $true
    Write-Log "Defender dinonaktifkan via policy + registry (efek penuh perlu reboot; status dilaporkan apa adanya)."
} catch { Write-Warn ("Defender full dilewati: " + $_.Exception.Message) }

# ---------- 4) Service lapis-2 ----------
$svcDisable = @(
    "BITS", "DoSvc", "Spooler", "PhoneSvc", "WbioSrvc",
    "SharedAccess", "icssvc", "SensorService", "SensrSvc", "TapiSrv",
    "PushToInstall", "WpnService", "WpnUserService",
    "PimIndexMaintenanceSvc", "UserDataSvc", "UnistoreSvc",
    "CDPUserSvc", "MessagingService", "wisvc", "diagnosticshub.standardcollector.service"
)
foreach ($svc in $svcDisable) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -ne "Stopped") { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        $hasil.service_full++
    } catch { }
}
foreach ($svc in @("AppXSvc", "ClipSVC", "InstallService", "TokenBroker")) {
    try { Set-Service -Name $svc -StartupType Manual -ErrorAction Stop } catch { }
}
Write-Log "Service lapis-2 dimatikan: $($hasil.service_full)."

# ---------- 5) Policy konsumen & Edge ----------
try {
    $sysKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    New-Item -Path $sysKey -Force | Out-Null
    Set-ItemProperty -Path $sysKey -Name DisableWindowsConsumerFeatures -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $sysKey -Name DisableTailoredExperiencesWithDiagnosticData -Value 1 -Type DWord -ErrorAction SilentlyContinue
    $feedsKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"
    New-Item -Path $feedsKey -Force | Out-Null
    Set-ItemProperty -Path $feedsKey -Name EnableFeeds -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $edgeKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge"
    New-Item -Path $edgeKey -Force | Out-Null
    Set-ItemProperty -Path $edgeKey -Name HubsSidebarEnabled -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $edgeKey -Name EdgeShoppingAssistantEnabled -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $edgeKey -Name BackgroundModeEnabled -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $edgeKey -Name StartupBoostEnabled -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $hasil.edge_policy = $true
    Write-Log "Policy konsumen (saran aplikasi/feeds) + Edge ramping diterapkan."
} catch { Write-Warn ("Policy konsumen/Edge dilewati: " + $_.Exception.Message) }
try {
    $hiveName = "RDPfreadDefFull"
    $loaded = $false
    try {
        reg.exe load "HKU\$hiveName" "C:\Users\Default\NTUSER.DAT" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $loaded = $true
            $cdm = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            New-Item -Path $cdm -Force | Out-Null
            foreach ($v in @("ContentDeliveryAllowed", "RotatingLockScreenEnabled", "RotatingLockScreenOverlayEnabled", "SubscribedContent-338387Enabled", "SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled", "SoftLandingEnabled")) {
                Set-ItemProperty -Path $cdm -Name $v -Value 0 -Type DWord -ErrorAction SilentlyContinue
            }
            Write-Log "Spotlight & konten saran lock screen dimatikan untuk profil baru."
        }
    } finally {
        if ($loaded) { [System.GC]::Collect(); reg.exe unload "HKU\$hiveName" 2>$null | Out-Null }
    }
} catch { Write-Warn ("Tweak ContentDeliveryManager dilewati: " + $_.Exception.Message) }

# ---------- 6) DISM component cleanup (batas 10 menit) ----------
try {
    $dism = Start-Process dism.exe -ArgumentList "/Online", "/Cleanup-Image", "/StartComponentCleanup" -PassThru -ErrorAction Stop
    if ($dism.WaitForExit(600000)) {
        if ($dism.ExitCode -eq 0) { $hasil.dism_cleanup = $true; Write-Log "DISM component cleanup selesai." }
        else { Write-Warn "DISM component cleanup selesai dengan kode $($dism.ExitCode)." }
    } else {
        Write-Warn "DISM component cleanup melewati 10 menit - dihentikan."
        try { $dism.Kill() } catch { }
    }
} catch { Write-Warn ("DISM cleanup dilewati: " + $_.Exception.Message) }

Update-Status @{ debloat_full = [PSCustomObject]$hasil }
Write-Log ("Debloat FULL selesai: appx2={0} fitur={1} defender_full={2} service={3} edge_policy={4} dism={5}" -f $hasil.appx2_dihapus, $hasil.fitur_dihapus, $hasil.defender_full, $hasil.service_full, $hasil.edge_policy, $hasil.dism_cleanup)
