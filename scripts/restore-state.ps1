# restore-state.ps1 - pulihkan state dari Release "rdpfread-state-latest".
# Arsip dibuka ke staging, lalu tiap item disalin balik ke path asalnya per manifest.json.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:restore"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$ws = Get-WorkspacePath
$dl = Join-Path $ws "out\download"
if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
New-Item -ItemType Directory -Path $dl -Force | Out-Null

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh -or -not $env:GITHUB_REPOSITORY) { Write-Log "gh/repo tidak tersedia - restore dilewati."; return }
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }

gh release download rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --pattern "rdpfread-state*" --dir $dl 2>$null | Out-Null
$file = Get-ChildItem $dl -File -ErrorAction SilentlyContinue | Select-Object -First 1
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
foreach ($entry in $manifest) {
    $src = Join-Path $staging $entry.staging
    $dst = [Environment]::ExpandEnvironmentVariables([string]$entry.target)
    if (-not (Test-Path $src)) { continue }
    # Item berupa folder staging yang mewakili folder target, atau berisi 1 file.
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
Write-Log "Restore state selesai."
$global:LASTEXITCODE = 0
