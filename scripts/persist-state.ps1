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

$manifest = @()
$i = 0
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { Write-Log "Lewati (tidak ada): $p"; continue }
    $i++
    $name = "item{0}" -f $i
    $dest = Join-Path $staging $name
    if ((Get-Item $p).PSIsContainer) {
        # /E semua subfolder, /NFL /NDL senyap, /R:1 /W:1 toleran file terkunci
        robocopy $p $dest /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    } else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item $p (Join-Path $dest (Split-Path $p -Leaf)) -Force
    }
    $manifest += [PSCustomObject]@{ staging = $name; target = $p }
    Write-Log "State: $p -> $name"
}
if ($manifest.Count -eq 0) { Write-Warn "Tidak ada path state yang bisa disimpan."; return }
(ConvertTo-Json -Depth 5 -InputObject @($manifest)) | Set-Content -Path (Join-Path $staging "manifest.json") -Encoding UTF8

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

# --- Upload ke Release tetap ---
$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh -and $env:GITHUB_REPOSITORY) {
    if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $env:GITHUB_TOKEN }
    gh release view rdpfread-state-latest --repo $env:GITHUB_REPOSITORY 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        gh release create rdpfread-state-latest --repo $env:GITHUB_REPOSITORY --title "RDPfread State (latest)" --notes "Arsip state sesi RDPfread - dikelola otomatis." 2>$null | Out-Null
    }
    gh release upload rdpfread-state-latest $finalFile --clobber --repo $env:GITHUB_REPOSITORY 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Log "State terunggah ke Release rdpfread-state-latest." }
    else { Write-Warn "Upload Release gagal - state lokal tetap ada sebagai artifact." }
} else { Write-Warn "gh/token tidak tersedia - upload Release dilewati." }
