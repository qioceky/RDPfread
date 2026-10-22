# setup-games.ps1 - paket game untuk preset "game" (v1.2.0).
# Semua langkah best effort (WARN saja bila gagal) dan hanya dari sumber resmi:
#   1) Prasyarat game lawas: VC++ Redistributable x86+x64 (Microsoft) + DirectX
#      End-User Runtime (Microsoft).
#   2) Mesa3D (pal1000/mesa-dist-win, GitHub) - OpenGL software (llvmpipe) untuk
#      VM tanpa GPU; DLL disuntikkan ke runtime Java (JDK 21 & JRE 8 Temurin)
#      dan runtime bawaan Minecraft Launcher bila ada.
#   3) Minecraft Java: launcher resmi Mojang (MSI) + options.txt ramah RDP di
#      profil user RDP. PrismLauncher + JDK/JRE dipasang setup-preset (winget).
#   4) GTA San Andreas / SA-MP: game TIDAK disediakan (harus salinan milik user
#      di C:\RDPData\GTASA atau C:\Games\GTASA). Bila ditemukan, dipasangi:
#      Ultimate ASI Loader (ThirteenAG), SilentPatch SA (CookiePLMonster),
#      dgVoodoo2 (dege-diosg), dan dicoba installer SA-MP resmi (files.sa-mp.com).
#      Bila tidak ditemukan, installer SA-MP diunduh ke C:\RDPData\Games-Setup
#      (ikut state) + file petunjuk ditulis.
#   5) Mouse: akselerasi dimatikan (hive Default User + user RDP bila profilnya
#      sudah ada) agar bidikan 1:1 untuk FPS/SA-MP/ETS2.
# Catatan: folder GTASA SENGAJA dikecualikan dari state (persist-state.ps1)
# karena ukuran game (+/-4,7 GB) melewati batas asset Release GitHub (2 GB).
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:game"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$user = Get-StatusValue "rdp_user"
if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:RDP_USER }
$work = Join-Path (Get-WorkspacePath) "out\games"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null
$result = [ordered]@{ prasyarat = $false; mesa = $false; minecraft_launcher = $false; gtasa = $false; samp = "tidak"; patch_gtasa = $false }

function Save-File([string]$Url, [string]$Dest) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 900 -Headers @{ "User-Agent" = "RDPfread" }
        return (Test-Path $Dest)
    } catch { Write-Warn ("Unduh gagal ($Url): " + $_.Exception.Message); return $false }
}
function Get-GhAssetUrl([string]$Repo, [string]$Pattern, [int]$Scan = 5) {
    try {
        $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=$Scan" -Headers @{ "User-Agent" = "RDPfread"; Accept = "application/vnd.github+json" } -TimeoutSec 30
        foreach ($rel in @($rels)) {
            foreach ($a in @($rel.assets)) { if ($a.name -match $Pattern) { return $a.browser_download_url } }
        }
    } catch { Write-Warn ("Query release $Repo gagal: " + $_.Exception.Message) }
    return $null
}
function Expand-Any([string]$Archive, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    if ($Archive -like "*.7z") {
        $sz = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if (-not $sz) { $c = "C:\Program Files\7-Zip\7z.exe"; if (Test-Path $c) { $sz = $c } }
        if ($sz) { & $sz x $Archive "-o$Dest" -y | Out-Null; return ($LASTEXITCODE -eq 0) }
        Write-Warn "7z tidak tersedia untuk mengekstrak $Archive"; return $false
    }
    try { Expand-Archive $Archive $Dest -Force; return $true }
    catch { tar.exe -xf $Archive -C $Dest; return ($LASTEXITCODE -eq 0) }
}

# ---------- 1) Prasyarat ----------
try {
    $vcOk = $true
    foreach ($arch in @("x86", "x64")) {
        $f = Join-Path $work "vc_redist.$arch.exe"
        if (Save-File "https://aka.ms/vs/17/release/vc_redist.$arch.exe" $f) {
            Start-Process $f -ArgumentList "/install", "/quiet", "/norestart" -Wait -ErrorAction SilentlyContinue
            Write-Log "VC++ Redistributable $arch terpasang/diperbarui."
        } else { $vcOk = $false }
    }
    $dx = Join-Path $work "dxwebsetup.exe"
    if (Save-File "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe" $dx) {
        Start-Process $dx -ArgumentList "/Q" -Wait -ErrorAction SilentlyContinue
        Write-Log "DirectX End-User Runtime dijalankan."
    }
    $result.prasyarat = $vcOk
} catch { Write-Warn ("Prasyarat game dilewati: " + $_.Exception.Message) }

# ---------- 2) Mesa3D untuk Java ----------
try {
    $mesaUrl = Get-GhAssetUrl "pal1000/mesa-dist-win" "release-msvc\.7z$" 1
    if ($mesaUrl) {
        $mz = Join-Path $work "mesa.7z"
        if (Save-File $mesaUrl $mz) {
            $mx = Join-Path $work "mesa"
            if (Expand-Any $mz $mx) {
                $x64 = Get-ChildItem $mx -Recurse -Directory -Filter "x64" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($x64) {
                    $dlls = @("opengl32.dll", "libgallium_wgl.dll", "libglapi.dll", "dxil.dll")
                    $javaBins = @()
                    foreach ($root in @("C:\Program Files\Eclipse Adoptium", "C:\Program Files\Java")) {
                        if (Test-Path $root) { $javaBins += Get-ChildItem $root -Recurse -Directory -Filter "bin" -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Name -match "^(jdk|jre)" } | ForEach-Object { $_.FullName } }
                    }
                    $mcRuntime = "C:\Users\$user\AppData\Roaming\.minecraft\runtime"
                    if (Test-Path $mcRuntime) { $javaBins += Get-ChildItem $mcRuntime -Recurse -Directory -Filter "bin" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } }
                    foreach ($bin in $javaBins) {
                        foreach ($d in $dlls) {
                            $srcDll = Join-Path $x64.FullName $d
                            if (Test-Path $srcDll) { Copy-Item $srcDll (Join-Path $bin $d) -Force -ErrorAction SilentlyContinue }
                        }
                        Write-Log "Mesa3D disuntikkan ke Java: $bin"
                    }
                    if ($javaBins.Count -gt 0) { $result.mesa = $true }
                    else { Write-Warn "Runtime Java tidak ditemukan - Mesa3D tidak disuntikkan (JDK/JRE dari preset belum terpasang?)." }
                }
            }
        }
    } else { Write-Warn "Asset Mesa3D tidak ditemukan di release terbaru mesa-dist-win." }
} catch { Write-Warn ("Mesa3D dilewati: " + $_.Exception.Message) }

# ---------- 3) Minecraft Java: launcher resmi + options.txt ----------
try {
    $msi = Join-Path $work "MinecraftInstaller.msi"
    if (Save-File "https://launcher.mojang.com/download/MinecraftInstaller.msi" $msi) {
        $p = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/quiet", "/norestart" -Wait -PassThru -ErrorAction SilentlyContinue
        if ($p -and $p.ExitCode -eq 0) { $result.minecraft_launcher = $true; Write-Log "Minecraft Launcher resmi terpasang." }
        else { Write-Warn "Minecraft Launcher MSI selesai dengan kode $($p.ExitCode) - bisa dipasang manual dari $msi." }
    }
    $mcDir = "C:\Users\$user\AppData\Roaming\.minecraft"
    $optFile = Join-Path $mcDir "options.txt"
    if (-not (Test-Path $optFile)) {
        New-Item -ItemType Directory -Path $mcDir -Force | Out-Null
        @(
            "renderDistance:6", "simulationDistance:6", "maxFps:120", "enableVsync:false",
            "fancyGraphics:false", "renderClouds:false", "particles:2", "entityShadows:false",
            "mipmapLevels:0", "biomeBlendRadius:0", "ao:0", "guiScale:2"
        ) | Set-Content -Path $optFile -Encoding ASCII
        Write-Log "options.txt Minecraft ramah RDP ditulis (render distance 6, grafis fast)."
    }
} catch { Write-Warn ("Minecraft Launcher dilewati: " + $_.Exception.Message) }

# ---------- 4) GTA SA / SA-MP ----------
try {
    $gtaDir = $null
    foreach ($cand in @("C:\RDPData\GTASA", "C:\Games\GTASA", "C:\Program Files (x86)\Rockstar Games\GTA San Andreas", "C:\Program Files\Rockstar Games\GTA San Andreas")) {
        if (Test-Path (Join-Path $cand "gta_sa.exe")) { $gtaDir = $cand; break }
    }
    $setupDir = "C:\RDPData\Games-Setup"
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
    # Installer SA-MP resmi - coba beberapa kandidat, unduh sekali ke Games-Setup.
    $sampExe = Join-Path $setupDir "sa-mp-0.3.7-install.exe"
    if (-not (Test-Path $sampExe)) {
        foreach ($u in @("https://files.sa-mp.com/sa-mp-0.3.7-R5-1-install.exe", "https://files.sa-mp.com/sa-mp-0.3.7-R4-install.exe")) {
            if (Save-File $u $sampExe) { break }
        }
    }
    if (-not $gtaDir) {
        @(
            "GTA San Andreas belum ditemukan.",
            "",
            "Taruh salinan GTA SA milikmu (ada gta_sa.exe) ke folder ini:",
            "  C:\RDPData\GTASA",
            "Folder GTASA tidak ikut state (ukuran game +/-4,7 GB melewati batas",
            "Release GitHub 2 GB) - salin ulang tiap sesi, ATAU pakai C:\Games\GTASA.",
            "Setelah game tersalin, jalankan lagi sesi preset game: SA-MP, SilentPatch,",
            "ASI Loader & dgVoodoo2 akan dipasang otomatis ke folder game-mu.",
            "Installer SA-MP (bila berhasil diunduh) ada di C:\RDPData\Games-Setup."
        ) | Set-Content -Path (Join-Path $setupDir "BACA-DULU-GTASA.txt") -Encoding UTF8
        Write-Warn "GTA SA tidak ditemukan - petunjuk ditulis ke $setupDir\BACA-DULU-GTASA.txt (installer SA-MP distage di folder yang sama)."
    } else {
        $result.gtasa = $true
        Write-Log "GTA SA ditemukan di $gtaDir - memasang patch..."
        $patched = $true
        # ASI Loader (dinput8.dll x86)
        $asiUrl = Get-GhAssetUrl "ThirteenAG/Ultimate-ASI-Loader" "^Ultimate-ASI-Loader-NoPDB\.zip$" 1
        if ($asiUrl) {
            $az = Join-Path $work "asi.zip"
            if ((Save-File $asiUrl $az) -and (Expand-Any $az (Join-Path $work "asi"))) {
                $dll = Get-ChildItem (Join-Path $work "asi") -Recurse -Filter "dinput8.dll" | Select-Object -First 1
                if ($dll) { Copy-Item $dll.FullName (Join-Path $gtaDir "dinput8.dll") -Force; Write-Log "ASI Loader terpasang." } else { $patched = $false }
            } else { $patched = $false }
        } else { $patched = $false }
        # SilentPatch SA
        $spUrl = Get-GhAssetUrl "CookiePLMonster/SilentPatch" "^SilentPatchSA\.zip$" 10
        if ($spUrl) {
            $sz2 = Join-Path $work "sp.zip"
            if ((Save-File $spUrl $sz2) -and (Expand-Any $sz2 (Join-Path $work "sp"))) {
                Get-ChildItem (Join-Path $work "sp") -Recurse -File | Where-Object { $_.Extension -in ".asi", ".ini" } | ForEach-Object { Copy-Item $_.FullName (Join-Path $gtaDir $_.Name) -Force }
                Write-Log "SilentPatch SA terpasang."
            } else { $patched = $false }
        } else { $patched = $false }
        # dgVoodoo2 (DDraw/D3D wrapper untuk game DirectX lawas)
        $dgUrl = Get-GhAssetUrl "dege-diosg/dgVoodoo2" "^dgVoodoo2_\d+_\d+\.zip$" 1
        if ($dgUrl) {
            $dz = Join-Path $work "dg.zip"
            if ((Save-File $dgUrl $dz) -and (Expand-Any $dz (Join-Path $work "dg"))) {
                $msx = Get-ChildItem (Join-Path $work "dg") -Recurse -Directory -Filter "x86" | Where-Object { $_.Parent.Name -eq "MS" } | Select-Object -First 1
                if ($msx) { foreach ($f in @("DDraw.dll", "D3DImm.dll", "D3D8.dll", "D3D9.dll")) { $s = Join-Path $msx.FullName $f; if (Test-Path $s) { Copy-Item $s (Join-Path $gtaDir $f) -Force } } }
                $conf = Get-ChildItem (Join-Path $work "dg") -Recurse -Filter "dgVoodoo.conf" | Select-Object -First 1
                if ($conf) {
                    $txt = Get-Content $conf.FullName -Raw
                    $txt = $txt -replace "(?m)^(\s*dgVoodooWatermark\s*=)\s*\S+", "`$1 false"
                    $txt = $txt -replace "(?m)^(\s*Resolution\s*=).*$", "`$1 1024x768"
                    Set-Content -Path (Join-Path $gtaDir "dgVoodoo.conf") -Value $txt -Encoding ASCII
                }
                Write-Log "dgVoodoo2 terpasang (watermark mati, resolusi awal 1024x768)."
            } else { $patched = $false }
        } else { $patched = $false }
        $result.patch_gtasa = $patched
        # SA-MP: coba pasang senyap ke folder game; verifikasi samp.exe.
        if (Test-Path $sampExe) {
            try { Start-Process $sampExe -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue } catch { }
            if (Test-Path (Join-Path $gtaDir "samp.exe")) { $result.samp = "terpasang"; Write-Log "SA-MP terpasang di folder game." }
            else { $result.samp = "manual"; Write-Warn "SA-MP belum terpasang otomatis - jalankan manual installer di $sampExe dari dalam RDP dan arahkan ke $gtaDir." }
        } else { $result.samp = "unduh-gagal"; Write-Warn "Installer SA-MP tidak berhasil diunduh dari server resmi sesi ini." }
    }
} catch { Write-Warn ("Paket GTA SA/SA-MP dilewati: " + $_.Exception.Message) }

# ---------- 5) Mouse tanpa akselerasi ----------
try {
    $hiveName = "RDPfreadDefGame"
    $loaded = $false
    try {
        reg.exe load "HKU\$hiveName" "C:\Users\Default\NTUSER.DAT" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $loaded = $true
            $mp = "Registry::HKEY_USERS\$hiveName\Control Panel\Mouse"
            New-Item -Path $mp -Force | Out-Null
            Set-ItemProperty -Path $mp -Name MouseSpeed -Value "0" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $mp -Name MouseThreshold1 -Value "0" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $mp -Name MouseThreshold2 -Value "0" -ErrorAction SilentlyContinue
        }
    } finally { if ($loaded) { reg.exe unload "HKU\$hiveName" 2>$null | Out-Null } }
    Write-Log "Akselerasi mouse dimatikan untuk profil baru (Default User)."
} catch { Write-Log "Tweak mouse dilewati (best effort)." }

Update-Status @{ games = [PSCustomObject]$result }
Write-Log ("Paket game selesai: prasyarat={0} mesa={1} mc-launcher={2} gtasa={3} samp={4} patch={5}" -f $result.prasyarat, $result.mesa, $result.minecraft_launcher, $result.gtasa, $result.samp, $result.patch_gtasa)
