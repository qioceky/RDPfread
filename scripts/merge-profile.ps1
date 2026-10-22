# merge-profile.ps1 - dijalankan SEKALI saat logon pertama user RDP lewat
# RunOnce "RDPfreadProfileMerge" (didaftarkan restore-state.ps1, v1.2.1).
# Menggabungkan item profil dari staging C:\RDPData\.profil-restore ke profil
# ASLI user yang sedang login ($env:USERPROFILE - bisa bersuffix, mis.
# C:\Users\fread.runnervmX), termasuk:
#   - kind "path"             : folder profil (Desktop, Documents, profil
#                               browser, .minecraft, dll) per jalur relatif.
#   - kind "dpapi"            : master key DPAPI -> folder Protect\<SID sesi
#                               ini> + CREDHIST (translasi SID otomatis karena
#                               berjalan sebagai user itu sendiri).
#   - kind "minecraft_options": options.txt Minecraft ramah RDP (didaftarkan
#                               setup-games.ps1 untuk preset game).
# Script ini MANDIRI (tanpa lib-common) karena berjalan dari C:\RDPData,
# di luar workspace Actions. Log: merge-log.txt di folder staging yang sama.
$ErrorActionPreference = "Continue"
$root = "C:\RDPData\.profil-restore"
$logFile = Join-Path $root "merge-log.txt"
function MLog([string]$m) { try { Add-Content -Path $logFile -Value ("[{0} UTC] {1}" -f (Get-Date).ToUniversalTime().ToString("HH:mm:ss"), $m) -Encoding UTF8 } catch { } }

$mf = Join-Path $root "merge-manifest.json"
if (-not (Test-Path $mf)) { return }
try { $entries = @(Get-Content $mf -Raw | ConvertFrom-Json) } catch { MLog ("manifest tidak terbaca: " + $_.Exception.Message); return }
$prof = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($prof)) { MLog "USERPROFILE kosong - merge dibatalkan."; return }
MLog "Merge profil dimulai -> $prof ($($entries.Count) item)"
foreach ($e in $entries) {
    try {
        if ($e.kind -eq "dpapi") {
            $src = Join-Path $root $e.staging
            if (-not (Test-Path $src)) { continue }
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $protectRoot = Join-Path $prof "AppData\Roaming\Microsoft\Protect"
            $sidDest = Join-Path $protectRoot $sid
            New-Item -ItemType Directory -Path $sidDest -Force | Out-Null
            $keysSrc = Join-Path $src "keys"
            if (Test-Path $keysSrc) { Copy-Item (Join-Path $keysSrc "*") $sidDest -Force -ErrorAction SilentlyContinue }
            $ch = Join-Path $src "CREDHIST"
            if (Test-Path $ch) { Copy-Item $ch (Join-Path $protectRoot "CREDHIST") -Force -ErrorAction SilentlyContinue }
            MLog "DPAPI: master key digabung ke folder SID sesi ini ($sid)."
            continue
        }
        if ($e.kind -eq "minecraft_options") {
            $mcDir = Join-Path $prof "AppData\Roaming\.minecraft"
            $opt = Join-Path $mcDir "options.txt"
            if (-not (Test-Path $opt)) {
                New-Item -ItemType Directory -Path $mcDir -Force | Out-Null
                @(
                    "renderDistance:6", "simulationDistance:6", "maxFps:120", "enableVsync:false",
                    "fancyGraphics:false", "renderClouds:false", "particles:2", "entityShadows:false",
                    "mipmapLevels:0", "biomeBlendRadius:0", "ao:0", "guiScale:2"
                ) | Set-Content -Path $opt -Encoding ASCII
                MLog "Minecraft: options.txt ramah RDP ditulis di profil asli."
            }
            continue
        }
        # kind "path"
        $src = Join-Path $root $e.staging
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $prof $e.rel
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        robocopy $src $dst /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        MLog "Item digabung: $($e.rel)"
    } catch { MLog ("Item gagal (kind=$($e.kind), rel=$($e.rel)): " + $_.Exception.Message) }
}
try { Rename-Item $mf "merge-manifest.done.json" -Force } catch { }
MLog "Merge profil selesai."
