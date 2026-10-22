# optimize-storage.ps1 - storage boost + debloat ringan (v1.1.0, input optimasi).
# 1) Storage boost: bebaskan ruang disk runner yang sempit - toolcache bawaan
#    image (preset RDPfread memasang sendiri perkakasnya via winget/choco),
#    cache unduhan Windows Update, folder Temp, dan Recycle Bin.
# 2) Debloat ringan: matikan service latar yang tidak dipakai sesi RDP
#    (telemetri, indexing, Xbox, fax, demo retail) agar CPU/RAM lebih lega.
# Semua langkah best effort: kegagalan satu langkah hanya WARN, tidak pernah
# menggagalkan sesi.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:optimasi"
. (Join-Path $PSScriptRoot "lib-common.ps1")

function Get-FreeGb {
    try { return [math]::Round((Get-PSDrive C).Free / 1GB, 2) } catch { return -1 }
}

$freeBefore = Get-FreeGb
Write-Log "Optimasi mulai (disk bebas: $freeBefore GB)."

# --- Storage boost ---
$cleanDirs = @(
    "C:\hostedtoolcache",
    "C:\Windows\SoftwareDistribution\Download",
    "C:\Windows\Temp"
)
# Temp semua user (termasuk user RDP & runner)
try {
    foreach ($u in Get-ChildItem "C:\Users" -Directory -Force -ErrorAction SilentlyContinue) {
        $t = Join-Path $u.FullName "AppData\Local\Temp"
        if (Test-Path $t) { $cleanDirs += $t }
    }
} catch { }
foreach ($d in $cleanDirs) {
    try {
        if (Test-Path $d) {
            Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Dibersihkan: $d"
        }
    } catch { Write-Warn ("Bersih-bersih gagal untuk ${d}: " + $_.Exception.Message) }
}
try { Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue } catch { }

# --- Debloat ringan: service latar non-esensial ---
$services = @(
    "DiagTrack",        # telemetri Connected User Experiences
    "dmwappushservice", # telemetri WAP push
    "WSearch",          # Windows Search indexing (CPU/IO berat di VM baru)
    "SysMain",          # Superfetch - churn latar di VM sekali pakai
    "MapsBroker",       # peta offline
    "XblGameSave", "XblAuthManager", "XboxNetApiSvc", "XboxGipSvc", # Xbox
    "Fax",              # fax
    "RetailDemo"        # demo retail
)
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            if ($s.Status -eq "Running") { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "Service dimatikan: $svc"
        }
    } catch { Write-Warn ("Debloat service $svc dilewati: " + $_.Exception.Message) }
}
# Task telemetri/kompatibilitas latar
foreach ($task in @("\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
                    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser")) {
    try { Disable-ScheduledTask -TaskPath (Split-Path $task) -TaskName (Split-Path $task -Leaf) -ErrorAction SilentlyContinue | Out-Null } catch { }
}

$freeAfter = Get-FreeGb
$gain = if ($freeBefore -ge 0 -and $freeAfter -ge 0) { [math]::Round($freeAfter - $freeBefore, 2) } else { -1 }
Update-Status @{ optimasi_hasil = [PSCustomObject]@{ disk_free_before_gb = $freeBefore; disk_free_after_gb = $freeAfter; gained_gb = $gain } }
Write-Log "Optimasi selesai (disk bebas: $freeAfter GB, +$gain GB)."
