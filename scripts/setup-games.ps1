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
#   5) Game gratis ringan (URL unduh langsung terpin - TANPA query API
#      GitHub yang kena rate-limit 403 dari IP Azure): Mindustry, Luanti,
#      GZDoom+Freedoom, OpenTTD, SuperTuxKart, Battle for Wesnoth. Game
#      portable ke C:\Games, installer senyap ke Program Files, shortcut
#      di Desktop publik. Jalan sebagai STEP WORKFLOW TERSENDIRI (v1.2.1).
#   6) Mouse: akselerasi dimatikan (hive Default User + user RDP bila profilnya
#      sudah ada) agar bidikan 1:1 untuk FPS/SA-MP/ETS2.
# Perubahan v1.2.1: Mesa3D memakai URL terpin 26.2.4 (API hanya cadangan);
# options.txt Minecraft didaftarkan ke staging merge profil (ditulis
# merge-profile.ps1 di profil asli saat logon) - tidak lagi ditulis
# langsung ke C:\Users\<user>; unduhan SA-MP dari files.sa-mp.com dibuang
# (DNS domain itu mati, terkonfirmasi 2026-10-22) - installer lokal user
# di C:\RDPData\Games-Setup tetap dipakai bila ada.
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
$result = [ordered]@{ prasyarat = $false; mesa = $false; minecraft_launcher = $false; gtasa = $false; samp = "tidak"; patch_gtasa = $false; mindustry = $false; luanti = $false; gzdoom = $false; openttd = $false; supertuxkart = $false; wesnoth = $false }

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
    $mz = Join-Path $work "mesa.7z"
    # URL langsung terpin lebih dulu: query API GitHub tanpa token dari IP
    # egress Azure kena rate-limit 403 (terbukti di sesi rdpfread-9). API
    # hanya cadangan bila unduhan terpin gagal.
    $mesaOk = Save-File "https://github.com/pal1000/mesa-dist-win/releases/download/26.2.4/mesa3d-26.2.4-release-msvc.7z" $mz
    if (-not $mesaOk) {
        $mesaUrl = Get-GhAssetUrl "pal1000/mesa-dist-win" "release-msvc\.7z$" 1
        if ($mesaUrl) { $mesaOk = Save-File $mesaUrl $mz }
    }
    if ($mesaOk) {
        if (Test-Path $mz) {
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
    } else { Write-Warn "Unduhan Mesa3D gagal (URL terpin + cadangan API)." }
} catch { Write-Warn ("Mesa3D dilewati: " + $_.Exception.Message) }

# ---------- 3) Minecraft Java: launcher resmi + options.txt ----------
try {
    $msi = Join-Path $work "MinecraftInstaller.msi"
    if (Save-File "https://launcher.mojang.com/download/MinecraftInstaller.msi" $msi) {
        $p = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/quiet", "/norestart" -Wait -PassThru -ErrorAction SilentlyContinue
        if ($p -and $p.ExitCode -eq 0) { $result.minecraft_launcher = $true; Write-Log "Minecraft Launcher resmi terpasang." }
        else { Write-Warn "Minecraft Launcher MSI selesai dengan kode $($p.ExitCode) - bisa dipasang manual dari $msi." }
    }
    # options.txt TIDAK ditulis langsung ke C:\Users\<user> (v1.2.1):
    # profil asli bisa bersuffix dan folder buatan pra-logon bisa yatim.
    # Daftarkan ke staging merge - merge-profile.ps1 menulisnya ke profil
    # asli saat logon pertama.
    try {
        $stageRoot = "C:\RDPData\.profil-restore"
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $mmf = Join-Path $stageRoot "merge-manifest.json"
        $existing = @()
        if (Test-Path $mmf) { try { $existing = @(Get-Content $mmf -Raw | ConvertFrom-Json) } catch { $existing = @() } }
        if (-not ($existing | Where-Object { $_.kind -eq "minecraft_options" })) {
            $existing += [PSCustomObject]@{ staging = ""; rel = ""; kind = "minecraft_options" }
            (ConvertTo-Json -Depth 5 -InputObject @($existing)) | Set-Content -Path $mmf -Encoding UTF8
        }
        # Pastikan merge-profile.ps1 + RunOnce tersedia juga bila restore
        # tidak membuat staging (mis. sesi pertama tanpa state profil).
        $mergeSrc = Join-Path $PSScriptRoot "merge-profile.ps1"
        if (Test-Path $mergeSrc) { Copy-Item $mergeSrc (Join-Path $stageRoot "merge-profile.ps1") -Force -ErrorAction SilentlyContinue }
        reg.exe query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v RDPfreadProfileMerge 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$stageRoot\merge-profile.ps1`""
            reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v RDPfreadProfileMerge /t REG_SZ /d $cmd /f | Out-Null
        }
        Write-Log "options.txt Minecraft dijadwalkan via merge profil (ditulis di profil asli saat logon pertama)."
    } catch { Write-Warn ("Pendaftaran options.txt dilewati: " + $_.Exception.Message) }
} catch { Write-Warn ("Minecraft Launcher dilewati: " + $_.Exception.Message) }

# ---------- 4) GTA SA / SA-MP ----------
try {
    $gtaDir = $null
    foreach ($cand in @("C:\RDPData\GTASA", "C:\Games\GTASA", "C:\Program Files (x86)\Rockstar Games\GTA San Andreas", "C:\Program Files\Rockstar Games\GTA San Andreas")) {
        if (Test-Path (Join-Path $cand "gta_sa.exe")) { $gtaDir = $cand; break }
    }
    $setupDir = "C:\RDPData\Games-Setup"
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
    # Installer SA-MP: situs resmi files.sa-mp.com TIDAK lagi bisa dijangkau
    # (DNS mati - terkonfirmasi dari dalam VM & jaringan luar, 2026-10-22),
    # jadi tidak dicoba diunduh lagi (v1.2.1). Bila user menaruh installer
    # sendiri di Games-Setup dengan nama ini, dipakai otomatis.
    $sampExe = Join-Path $setupDir "sa-mp-0.3.7-install.exe"
    if (-not $gtaDir) {
        @(
            "GTA San Andreas belum ditemukan.",
            "",
            "Taruh salinan GTA SA milikmu (ada gta_sa.exe) ke folder ini:",
            "  C:\RDPData\GTASA",
            "Folder GTASA tidak ikut state (ukuran game +/-4,7 GB melewati batas",
            "Release GitHub 2 GB) - salin ulang tiap sesi, ATAU pakai C:\Games\GTASA.",
            "Setelah game tersalin, jalankan lagi sesi preset game: SilentPatch,",
            "ASI Loader & dgVoodoo2 akan dipasang otomatis ke folder game-mu.",
            "Catatan SA-MP: situs resmi files.sa-mp.com sedang mati. Bila kamu",
            "punya installer SA-MP sendiri, taruh sebagai sa-mp-0.3.7-install.exe",
            "di C:\RDPData\Games-Setup - sesi berikutnya memasangnya otomatis."
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
        } else { $result.samp = "manual"; Write-Warn "Installer SA-MP tidak ada di Games-Setup - taruh sa-mp-0.3.7-install.exe di $setupDir untuk pemasangan otomatis." }
    }
} catch { Write-Warn ("Paket GTA SA/SA-MP dilewati: " + $_.Exception.Message) }

# ---------- 6) Game gratis ringan (URL terpin, sumber resmi) ----------
# Semua URL unduh LANGSUNG (tanpa query API GitHub - pelajaran rate-limit
# 403 sesi rdpfread-9), terverifikasi 2026-10-22. Portable -> C:\Games,
# installer -> Program Files (senyap, dibatasi waktu), shortcut di
# Desktop publik supaya terlihat di profil user mana pun.
function New-GameShortcut([string]$Name, [string]$Target, [string]$Args = "", [string]$WorkDir = "") {
    try {
        if (-not (Test-Path $Target)) { return $false }
        $desk = "C:\Users\Public\Desktop"
        New-Item -ItemType Directory -Path $desk -Force | Out-Null
        $lnk = Join-Path $desk "$Name.lnk"
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $Target
        if ($Args) { $sc.Arguments = $Args }
        if ($WorkDir) { $sc.WorkingDirectory = $WorkDir } else { $sc.WorkingDirectory = Split-Path $Target -Parent }
        $sc.IconLocation = $Target
        $sc.Save()
        return (Test-Path $lnk)
    } catch { return $false }
}
function Find-Exe([string]$Root, [string]$Name) {
    if (-not (Test-Path $Root)) { return $null }
    $f = Get-ChildItem $Root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}
function Install-Silent([string]$File, [int]$TimeoutSec = 600) {
    try {
        $pr = Start-Process $File -ArgumentList "/S" -PassThru -ErrorAction Stop
        if (-not $pr.WaitForExit($TimeoutSec * 1000)) {
            Write-Warn "Installer $File melewati batas $TimeoutSec detik - dihentikan."
            try { $pr.Kill() } catch { }
            return $false
        }
        return $true
    } catch { Write-Warn ("Installer $File gagal jalan: " + $_.Exception.Message); return $false }
}
$gamesRoot = "C:\Games"
New-Item -ItemType Directory -Path $gamesRoot -Force | Out-Null
# Mindustry - jar resmi (Anuken/Mindustry), jalan di JDK 21 preset.
try {
    $dir = Join-Path $gamesRoot "Mindustry"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $jar = Join-Path $dir "Mindustry.jar"
    if ((Test-Path $jar) -or (Save-File "https://github.com/Anuken/Mindustry/releases/download/v160.7/Mindustry.jar" $jar)) {
        $javaw = Find-Exe "C:\Program Files\Eclipse Adoptium" "javaw.exe"
        if ($javaw -and (New-GameShortcut "Mindustry" $javaw "-jar `"$jar`"" $dir)) { $result.mindustry = $true; Write-Log "Mindustry terpasang (jar resmi + shortcut)." }
        else { Write-Warn "Mindustry: javaw/shortcut tidak siap." }
    }
} catch { Write-Warn ("Mindustry dilewati: " + $_.Exception.Message) }
# Luanti (Minetest) - portable zip resmi (luanti-org/luanti).
try {
    $dir = Join-Path $gamesRoot "Luanti"
    $zf = Join-Path $work "luanti.zip"
    $exe = Find-Exe $dir "luanti.exe"
    if (-not $exe -and (Save-File "https://github.com/luanti-org/luanti/releases/download/5.17.0/luanti-5.17.0-win64.zip" $zf) -and (Expand-Any $zf $dir)) { $exe = Find-Exe $dir "luanti.exe" }
    if ($exe -and (New-GameShortcut "Luanti" $exe)) { $result.luanti = $true; Write-Log "Luanti terpasang." }
} catch { Write-Warn ("Luanti dilewati: " + $_.Exception.Message) }
# GZDoom + Freedoom - portable zip resmi (ZDoom/gzdoom + freedoom/freedoom).
try {
    $dir = Join-Path $gamesRoot "GZDoom"
    $zf = Join-Path $work "gzdoom.zip"
    $exe = Find-Exe $dir "gzdoom.exe"
    if (-not $exe -and (Save-File "https://github.com/ZDoom/gzdoom/releases/download/g4.14.2/gzdoom-4-14-2-windows.zip" $zf) -and (Expand-Any $zf $dir)) { $exe = Find-Exe $dir "gzdoom.exe" }
    if ($exe) {
        $gzDir = Split-Path $exe -Parent
        $wad = Join-Path $gzDir "freedoom2.wad"
        if (-not (Test-Path $wad)) {
            $fz = Join-Path $work "freedoom.zip"
            if ((Save-File "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip" $fz) -and (Expand-Any $fz (Join-Path $work "freedoom"))) {
                Get-ChildItem (Join-Path $work "freedoom") -Recurse -Filter "freedoom*.wad" | ForEach-Object { Copy-Item $_.FullName $gzDir -Force }
            }
        }
        if ((Test-Path $wad) -and (New-GameShortcut "GZDoom (Freedoom)" $exe "-iwad freedoom2.wad" $gzDir)) { $result.gzdoom = $true; Write-Log "GZDoom + Freedoom terpasang." }
    }
} catch { Write-Warn ("GZDoom dilewati: " + $_.Exception.Message) }
# OpenTTD - installer resmi dari CDN OpenTTD.
try {
    $exe = Find-Exe "C:\Program Files\OpenTTD" "openttd.exe"
    if (-not $exe) {
        $f = Join-Path $work "openttd.exe"
        if ((Save-File "https://cdn.openttd.org/openttd-releases/15.3/openttd-15.3-windows-win64.exe" $f) -and (Install-Silent $f)) { $exe = Find-Exe "C:\Program Files\OpenTTD" "openttd.exe" }
    }
    if ($exe -and (New-GameShortcut "OpenTTD" $exe)) { $result.openttd = $true; Write-Log "OpenTTD terpasang." }
} catch { Write-Warn ("OpenTTD dilewati: " + $_.Exception.Message) }
# SuperTuxKart - installer resmi (supertuxkart/stk-code).
try {
    $exe = Find-Exe "C:\Program Files\SuperTuxKart" "supertuxkart.exe"
    if (-not $exe) {
        $f = Join-Path $work "stk.exe"
        if ((Save-File "https://github.com/supertuxkart/stk-code/releases/download/1.5/SuperTuxKart-1.5-installer-x86_64.exe" $f) -and (Install-Silent $f 900)) { $exe = Find-Exe "C:\Program Files" "supertuxkart.exe" }
    }
    if ($exe -and (New-GameShortcut "SuperTuxKart" $exe)) { $result.supertuxkart = $true; Write-Log "SuperTuxKart terpasang." }
} catch { Write-Warn ("SuperTuxKart dilewati: " + $_.Exception.Message) }
# Battle for Wesnoth - installer resmi (SourceForge proyek wesnoth).
try {
    $exe = Find-Exe "C:\Program Files" "wesnoth.exe"
    if (-not $exe) {
        $f = Join-Path $work "wesnoth.exe"
        if ((Save-File "https://downloads.sourceforge.net/project/wesnoth/wesnoth-1.18/wesnoth-1.18.8/wesnoth-1.18.8-win64.exe" $f) -and (Install-Silent $f 900)) { $exe = Find-Exe "C:\Program Files" "wesnoth.exe" }
    }
    if ($exe -and (New-GameShortcut "Battle for Wesnoth" $exe)) { $result.wesnoth = $true; Write-Log "Battle for Wesnoth terpasang." }
} catch { Write-Warn ("Wesnoth dilewati: " + $_.Exception.Message) }

# ---------- 7) Mouse tanpa akselerasi ----------
# v1.5.2: pelepasan hive HARUS terverifikasi (pola yang sama dengan
# setup-windows v1.5.1). Edit hive ini hanya ada di jalur game dan TIDAK
# ikut dikeraskan v1.5.1 — tersangka terkuat kegagalan ProfSvc #23/#24/#25
# (gagal meski default_hive_ok=True). $gamesHiveOk = $true berarti tidak ada
# hive terkunci yang ditinggalkan script ini (termasuk bila hive gagal dimuat).
$gamesHiveOk = $true
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
    } finally {
        if ($loaded) {
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
            $gamesHiveOk = ($unloaded -and -not $fileLocked)
            if (-not $gamesHiveOk) { Write-Warn "Hive Default User GAGAL dilepas bersih setelah 3 percobaan (lihat status games_default_hive_ok)." }
        }
    }
    if ($loaded) { if ($gamesHiveOk) { Write-Log "Akselerasi mouse dimatikan untuk profil baru (Default User)." } }
    else { Write-Log "Hive Default User tidak bisa dimuat - tweak mouse dilewati." }
} catch { Write-Log "Tweak mouse dilewati (best effort)." }

Update-Status @{ games = [PSCustomObject]$result; games_default_hive_ok = $gamesHiveOk }
Write-Log ("Paket game selesai: prasyarat={0} mesa={1} mc-launcher={2} gtasa={3} samp={4} patch={5}" -f $result.prasyarat, $result.mesa, $result.minecraft_launcher, $result.gtasa, $result.samp, $result.patch_gtasa)
Write-Log ("Game tambahan: mindustry={0} luanti={1} gzdoom={2} openttd={3} supertuxkart={4} wesnoth={5}" -f $result.mindustry, $result.luanti, $result.gzdoom, $result.openttd, $result.supertuxkart, $result.wesnoth)
