# persist-state.ps1 - simpan state sesi ke Release "rdpfread-state-latest" + out/state (artifact).
# Isi state: path-path dari config/backup-paths.txt, disalin ke staging + manifest.json
# yang memetakan staging -> path asal, lalu di-tar.gz (dan dienkripsi AES-256 bila
# STATE_ENCRYPTION_KEY diisi dan openssl tersedia). Batas aman arsip: +/-1,9 GB.
param([switch]$Checkpoint)
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:persist"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$ws = Get-WorkspacePath
$outState = Join-Path $ws "out\state"
if (-not (Test-Path $outState)) { New-Item -ItemType Directory -Path $outState -Force | Out-Null }
$staging = Join-Path $outState "staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# --- Kumpulkan path dari config ---
$user = Get-StatusValue "rdp_user"
if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:RDP_USER }
$configFile = Join-Path $ws "config\backup-paths.txt"
$paths = @()
if (Test-Path $configFile) {
    foreach ($line in Get-Content $configFile) {
        $p = $line.Trim()
        if ($p -eq "" -or $p.StartsWith("#")) { continue }
        $p = $p -replace "%RDP_USER%", $user
        $paths += [Environment]::ExpandEnvironmentVariables($p)
    }
}
if ($paths.Count -eq 0) { $paths = @("C:\RDPData") }

# Profil asli user bisa bersuffix (mis. fread.runnervmX) - baca dari jalur
# asli (resolver ProfileList), tapi manifest tetap mencatat target kanonis
# C:\Users\<user> supaya restore/merge seragam (v1.2.1).
$canonProfile = "C:\Users\$user"
$realProfile = Get-ProfileDirForUser $user
if ($realProfile -and $realProfile -ne $canonProfile) { Write-Log "Profil asli user terdeteksi: $realProfile (kanonis: $canonProfile)" }

$manifest = @()
$i = 0
foreach ($p in $paths) {
    $srcPath = $p
    if ($realProfile -and $p.StartsWith($canonProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        $srcPath = $realProfile + $p.Substring($canonProfile.Length)
    }
    if (-not (Test-Path $srcPath)) { Write-Log "Lewati (tidak ada): $srcPath"; continue }
    $i++
    $name = "item{0}" -f $i
    $dest = Join-Path $staging $name
    if ((Get-Item $srcPath).PSIsContainer) {
        # /E semua subfolder, /NFL /NDL senyap, /R:1 /W:1 toleran file terkunci,
        # /XJ lewati junction (hindari loop di AppData), /XD kecualikan folder
        # cache browser/profile (besar, tidak berguna antar sesi) dan folder
        # GTASA (game +/-4,7 GB melewati batas asset Release GitHub 2 GB -
        # lihat setup-games.ps1; tanpa pengecualian ini seluruh state gagal
        # terunggah untuk user preset game).
        robocopy $srcPath $dest /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 /XD Cache "Code Cache" GPUCache DawnCache GrShaderCache ShaderCache "Service Worker" "C:\RDPData\GTASA" "C:\RDPData\.profil-restore" | Out-Null
        # Exit code robocopy 0-7 = sukses; >=8 baru error. Reset supaya tidak
        # terbaca sebagai kegagalan step oleh runner Actions.
        if ($LASTEXITCODE -ge 8) { Write-Warn "robocopy melaporkan error ($LASTEXITCODE) untuk $srcPath" }
        $global:LASTEXITCODE = 0
    } else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item $srcPath (Join-Path $dest (Split-Path $p -Leaf)) -Force
    }
    $manifest += [PSCustomObject]@{ staging = $name; target = $p; kind = "path" }
    Write-Log "State: $p -> $name"
}
if ($manifest.Count -eq 0) { Write-Warn "Tidak ada path state yang bisa disimpan."; return }

# --- Kunci DPAPI + vault kredensial user RDP (best effort, v1.1.0) ---
# Cookie & password tersimpan Chrome/Edge dienkripsi DPAPI user; master key-nya
# ada di AppData\Roaming\Microsoft\Protect\<SID>. Karena username + password RDP
# sama di semua sesi (dari secret), master key yang dipulihkan ke folder SID baru
# di VM berikutnya tetap bisa membuka kunci browser - user tidak perlu login
# ulang situs-situs tiap estafet. Folder staging khusus, dipulihkan restore-state
# dengan translasi SID (kind = "dpapi").
try {
    $profRoot = $realProfile
    if (-not $profRoot) { $profRoot = $canonProfile }
    $protect = Join-Path $profRoot "AppData\Roaming\Microsoft\Protect"
    if (Test-Path $protect) {
        $sidDirs = @(Get-ChildItem $protect -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "S-1-*" })
        $credHist = Join-Path $protect "CREDHIST"
        if ($sidDirs.Count -gt 0 -or (Test-Path $credHist)) {
            $dpDest = Join-Path $staging "dpapi-protect"
            $keysDest = Join-Path $dpDest "keys"
            New-Item -ItemType Directory -Path $keysDest -Force | Out-Null
            foreach ($sd in $sidDirs) { Copy-Item (Join-Path $sd.FullName "*") $keysDest -Force -ErrorAction SilentlyContinue }
            if (Test-Path $credHist) { Copy-Item $credHist (Join-Path $dpDest "CREDHIST") -Force -ErrorAction SilentlyContinue }
            $hasKeys = (@(Get-ChildItem $keysDest -File -Force -ErrorAction SilentlyContinue).Count -gt 0) -or (Test-Path (Join-Path $dpDest "CREDHIST"))
            if ($hasKeys) {
                $manifest += [PSCustomObject]@{ staging = "dpapi-protect"; target = "DPAPI_PROTECT"; kind = "dpapi" }
                Write-Log "State: kunci DPAPI user ikut disimpan (kontinuitas login browser)."
            } else { Remove-Item $dpDest -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($cred in @(@("AppData\Local\Microsoft\Credentials", "dpapi-cred-local"), @("AppData\Roaming\Microsoft\Credentials", "dpapi-cred-roaming"))) {
        $cp = Join-Path $profRoot $cred[0]
        if (Test-Path $cp) {
            $cd = Join-Path $staging $cred[1]
            robocopy $cp $cd /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-Warn "robocopy melaporkan error ($LASTEXITCODE) untuk $cp" }
            $global:LASTEXITCODE = 0
            if (Test-Path $cd) { $manifest += [PSCustomObject]@{ staging = $cred[1]; target = (Join-Path $canonProfile $cred[0]); kind = "path" } }
        }
    }
} catch { Write-Warn ("Backup DPAPI/kredensial dilewati: " + $_.Exception.Message) }

(ConvertTo-Json -Depth 5 -InputObject @($manifest)) | Set-Content -Path (Join-Path $staging "manifest.json") -Encoding UTF8

# --- Fingerprint isi staging (untuk skip checkpoint bila tak ada perubahan) ---
function Get-StagingFingerprint([string]$Root) {
    $files = @(Get-ChildItem $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    $sb = [System.Text.StringBuilder]::new()
    $total = 0L
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length)
        [void]$sb.AppendLine("$rel|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)")
        $total += $f.Length
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace("-", "").ToLower()
    return "$($files.Count):${total}:$hash"
}
$fingerprint = Get-StagingFingerprint $staging

# Checkpoint: lewati arsip+upload bila isi state sama persis dengan yang sudah
# terunggah (fingerprint terakhir disimpan sebagai asset kecil di Release).
if ($Checkpoint) {
    $ghFp = Get-GhExe
    if ($ghFp -and $env:GITHUB_REPOSITORY) {
        if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }
        $fpDir = Join-Path $outState "fpcheck"
        if (Test-Path $fpDir) { Remove-Item $fpDir -Recurse -Force }
        New-Item -ItemType Directory -Path $fpDir -Force | Out-Null
        & $ghFp release download rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --pattern "rdpfread-state.fingerprint" --dir $fpDir 2>$null | Out-Null
        $fpFile = Join-Path $fpDir "rdpfread-state.fingerprint"
        if (Test-Path $fpFile) {
            $remoteFp = (Get-Content $fpFile -Raw).Trim()
            if ($remoteFp -eq $fingerprint) {
                Write-Log "Checkpoint dilewati - tidak ada perubahan state sejak unggahan terakhir."
                Remove-Item $fpDir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item $staging -Recurse -Force
                return
            }
        }
        Remove-Item $fpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Arsipkan ---
$archive = Join-Path $outState "rdpfread-state.tar.gz"
if (Test-Path $archive) { Remove-Item $archive -Force }
tar.exe -czf $archive -C $staging .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $archive)) { Write-Warn "Pembuatan arsip tar gagal."; return }
Remove-Item $staging -Recurse -Force

# --- Enkripsi opsional (openssl AES-256, header Salted__) ---
$encrypted = $false
$finalFile = $archive
if ($env:STATE_ENCRYPTION_KEY) {
    $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $openssl) {
        $gitOssl = "C:\Program Files\Git\usr\bin\openssl.exe"
        if (Test-Path $gitOssl) { $openssl = $gitOssl } else { $openssl = $null }
    }
    if ($openssl) {
        $encFile = $archive + ".enc"
        & $openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in $archive -out $encFile
        if ($LASTEXITCODE -eq 0) { Remove-Item $archive -Force; $finalFile = $encFile; $encrypted = $true; Write-Log "State dienkripsi AES-256." }
        else { Write-Warn "Enkripsi gagal - state disimpan tanpa enkripsi." }
    } else { Write-Warn "openssl tidak ditemukan - state disimpan tanpa enkripsi." }
}

$bytes = (Get-Item $finalFile).Length
Update-Status @{ state = [PSCustomObject]@{ saved_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); bytes = $bytes; encrypted = $encrypted; checkpoint = [bool]$Checkpoint } }
Write-Log ("State tersimpan lokal: {0} ({1:N0} bytes, encrypted={2})" -f (Split-Path $finalFile -Leaf), $bytes, $encrypted)

if ($bytes -gt 1900MB) { Write-Warn "Arsip > 1,9 GB - upload Release dilewati (artifact tetap dicoba dari workflow)."; return }

# --- Guard anti-timpa state (v1.5.2) ---
# Pelajaran insiden ProfSvc 2026-10-25: sesi yang tak pernah login menimpa
# state bagus (±105 MB) dengan arsip nyaris kosong (±1,5 KB) lewat checkpoint
# maupun finalize. Lewati upload bila SEMUA kondisi ini benar: (a) tidak ada
# profil user sungguhan di VM ini (belum pernah login), (b) asset Release yang
# ada jauh lebih besar dari arsip baru (remote > 10 MB, baru < 1 MB).
# Fail-open: bila ukuran remote tidak bisa dibaca, perilaku lama (upload).
# Fingerprint lama ikut dipertahankan (tidak diunggah) supaya checkpoint
# berikutnya tetap membandingkan dengan state yang benar.
try {
    $profileExists = $false
    if ($realProfile -and (Test-Path $realProfile)) { $profileExists = $true }
    elseif (Test-Path $canonProfile) { $profileExists = $true }
    if (-not $profileExists) {
        $ghQ = Get-GhExe
        if ($ghQ -and $env:GITHUB_REPOSITORY) {
            # gh memakai token runner (GITHUB_TOKEN) secara otomatis; tidak perlu set GH_TOKEN di sini.
            $sizeOut = & $ghQ release view rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --json assets --jq '.assets[] | select(.name | startswith("rdpfread-state.tar.gz")) | .size' 2>$null | Out-String
            $remoteSize = 0L
            foreach ($line in ($sizeOut -split "`n")) {
                $v = 0L
                if ([long]::TryParse($line.Trim(), [ref]$v) -and $v -gt $remoteSize) { $remoteSize = $v }
            }
            if ($remoteSize -gt 10MB -and $bytes -lt 1MB) {
                Write-Warn ("Guard anti-timpa: upload dilewati - tidak ada profil user (belum login) dan arsip baru {0:N0} bytes jauh lebih kecil dari asset Release {1:N0} bytes. State lama dipertahankan; state lokal tetap ada sebagai artifact." -f $bytes, $remoteSize)
                return
            }
        }
    }
} catch { Write-Warn ("Guard anti-timpa gagal dibaca (fail-open, upload tetap jalan): " + $_.Exception.Message) }

# --- Upload ke Release tetap ---
$gh = Get-GhExe
if ($gh -and $env:GITHUB_REPOSITORY) {
    if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }
    & $gh release view rdpfread-state-latest --repo $env:GITHUB_REPOSITORY 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & $gh release create rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --title "RDPfread State (latest)" --notes "Arsip state sesi RDPfread - dikelola otomatis." 2>$null | Out-Null
    }
    & $gh release upload rdpfread-state-latest $finalFile --clobber --repo $env:GITHUB_REPOSITORY 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "State terunggah ke Release rdpfread-state-latest."
        # Simpan fingerprint unggahan ini untuk skip-checkpoint berikutnya.
        $fpOut = Join-Path $outState "rdpfread-state.fingerprint"
        Set-Content -Path $fpOut -Value $fingerprint -Encoding ASCII
        & $gh release upload rdpfread-state-latest $fpOut --clobber --repo $env:GITHUB_REPOSITORY 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "Upload fingerprint gagal - skip-checkpoint mungkin tidak aktif sesi ini." }
    }
    else { Write-Warn "Upload Release gagal - state lokal tetap ada sebagai artifact." }
} else { Write-Warn "gh/token tidak tersedia - upload Release dilewati." }
