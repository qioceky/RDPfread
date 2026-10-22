# restore-state.ps1 - pulihkan state dari Release "rdpfread-state-latest".
# Arsip dibuka ke staging, lalu tiap item disalin balik ke path asalnya per manifest.json.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:restore"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$ws = Get-WorkspacePath
$dl = Join-Path $ws "out\download"
if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
New-Item -ItemType Directory -Path $dl -Force | Out-Null

$gh = Get-GhExe
if (-not $gh -or -not $env:GITHUB_REPOSITORY) { Write-Log "gh/repo tidak tersedia - restore dilewati."; $global:LASTEXITCODE = 0; return }
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }

& $gh release download rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --pattern "rdpfread-state*" --dir $dl 2>$null | Out-Null
# Utamakan arsip tar.gz(.enc); asset fingerprint kecil tidak boleh terpilih.
$file = Get-ChildItem $dl -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "rdpfread-state.tar.gz*" } | Select-Object -First 1
if (-not $file) { $file = Get-ChildItem $dl -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "rdpfread-state.fingerprint" } | Select-Object -First 1 }
if (-not $file) { Write-Log "Belum ada state tersimpan - sesi mulai dari bersih."; $global:LASTEXITCODE = 0; return }
Write-Log ("State ditemukan: {0} ({1:N0} bytes)" -f $file.Name, $file.Length)

# --- Dekripsi bila perlu ---
$archive = $file.FullName
if ($archive.EndsWith(".enc")) {
    $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $openssl) { $g = "C:\Program Files\Git\usr\bin\openssl.exe"; if (Test-Path $g) { $openssl = $g } }
    if (-not $openssl -or -not $env:STATE_ENCRYPTION_KEY) { Write-Warn "State terenkripsi tapi openssl/key tidak ada - restore dilewati."; return }
    $dec = Join-Path $dl "rdpfread-state.tar.gz"
    & $openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in $archive -out $dec
    if ($LASTEXITCODE -ne 0) { Write-Warn "Dekripsi gagal (STATE_ENCRYPTION_KEY berubah?) - restore dilewati."; $global:LASTEXITCODE = 0; return }
    $archive = $dec
}

# --- Ekstrak & kembalikan per manifest ---
$staging = Join-Path $dl "staging"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
tar.exe -xzf $archive -C $staging
if ($LASTEXITCODE -ne 0) { Write-Warn "Ekstrak arsip gagal - restore dilewati."; $global:LASTEXITCODE = 0; return }
$manifestFile = Join-Path $staging "manifest.json"
if (-not (Test-Path $manifestFile)) { Write-Warn "manifest.json tidak ada di arsip - restore dilewati."; return }
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
$u = Get-StatusValue "rdp_user"
if ([string]::IsNullOrWhiteSpace($u)) { $u = $env:RDP_USER }
$canonProfile = "C:\Users\$u"
$stageRoot = Get-ProfileStagingRoot
$mergeEntries = @()
foreach ($entry in $manifest) {
    $src = Join-Path $staging $entry.staging
    if (-not (Test-Path $src)) { continue }
    if ($entry.kind -eq "dpapi") {
        # DPAPI tidak lagi ditulis langsung ke C:\Users\<user>: profil asli
        # bisa bersuffix & folder buatan pra-logon yatim (v1.2.1). Ikut
        # staging - merge-profile.ps1 menaruhnya ke folder SID user yang
        # sebenarnya saat logon pertama.
        $mergeEntries += [PSCustomObject]@{ staging = [string]$entry.staging; rel = ""; kind = "dpapi" }
        continue
    }
    $dst = [Environment]::ExpandEnvironmentVariables([string]$entry.target)
    if ($u -and $dst.StartsWith($canonProfile + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        # Item profil: tampung di staging, JANGAN buat folder profil sebelum
        # logon (Windows bisa menolaknya & membuat profil bersuffix).
        $rel = $dst.Substring($canonProfile.Length + 1)
        $mergeEntries += [PSCustomObject]@{ staging = [string]$entry.staging; rel = $rel; kind = "path" }
        continue
    }
    # Item non-profil (mis. C:\RDPData): salin langsung seperti biasa.
    $items = Get-ChildItem $src -Force -ErrorAction SilentlyContinue
    if ($items.Count -eq 1 -and -not $items[0].PSIsContainer -and -not (Test-Path $dst -PathType Container)) {
        $parent = Split-Path $dst -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item $items[0].FullName $dst -Force
    } else {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        # Exit code robocopy 0-7 = sukses (1 = ada file tersalin); >=8 baru error.
        if ($LASTEXITCODE -ge 8) { Write-Warn "robocopy melaporkan error ($LASTEXITCODE) untuk $dst" }
        $global:LASTEXITCODE = 0
    }
    Write-Log "Dipulihkan: $dst"
}
# --- Stage item profil untuk digabung saat logon pertama ---
if ($mergeEntries.Count -gt 0) {
    try {
        if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        foreach ($me in $mergeEntries) {
            $s2 = Join-Path $staging $me.staging
            if ($me.staging -and (Test-Path $s2)) {
                robocopy $s2 (Join-Path $stageRoot $me.staging) /E /XJ /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
                $global:LASTEXITCODE = 0
            }
        }
        (ConvertTo-Json -Depth 5 -InputObject @($mergeEntries)) | Set-Content -Path (Join-Path $stageRoot "merge-manifest.json") -Encoding UTF8
        Copy-Item (Join-Path $PSScriptRoot "merge-profile.ps1") (Join-Path $stageRoot "merge-profile.ps1") -Force
        $runOnceCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$stageRoot\merge-profile.ps1`""
        reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v RDPfreadProfileMerge /t REG_SZ /d $runOnceCmd /f | Out-Null
        Write-Log ("{0} item profil ditampung di staging - digabung ke profil asli saat logon pertama user." -f $mergeEntries.Count)
        Update-Status @{ profile_merge = "menunggu-logon" }
    } catch { Write-Warn ("Penampungan item profil gagal: " + $_.Exception.Message) }
}
Write-Log "Restore state selesai."
$global:LASTEXITCODE = 0
