# setup-wizard.ps1 - wizard lokal untuk menyiapkan repo RDPfread.
# Jalankan di Windows (butuh GitHub CLI `gh` yang sudah login):
#   .\setup-wizard.ps1 [-Run]
# Yang dilakukan:
#   1) cek gh + login
#   2) tanya nama repo (default RDPfread) - dibuat PRIVATE dari folder ini bila belum ada
#   3) set secrets wajib (RDP_PASSWORD, TAILSCALE_AUTH_KEY) - input tersembunyi,
#      dikirim lewat `gh secret set` dari stdin, TIDAK pernah dicetak/disimpan ke file
#   4) tanya secrets opsional (STATE_ENCRYPTION_KEY, Telegram, Discord)
#   5) opsional: langsung Run workflow pertama (-Run atau jawab ya)
param([switch]$Run)
$ErrorActionPreference = "Stop"

function Say { param([string]$T) Write-Host "`n== $T ==" }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) belum terpasang. Install: https://cli.github.com" }
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "gh belum login. Jalankan: gh auth login" }
$ghUser = gh api user --jq .login
Write-Host "Login GitHub sebagai: $ghUser"

Say "Repository"
$name = Read-Host "Nama repo (default: RDPfread)"
if ([string]::IsNullOrWhiteSpace($name)) { $name = "RDPfread" }
$full = "$ghUser/$name"

gh repo view $full 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Repo $full sudah ada - memakai repo itu."
    Write-Host "PENTING: pastikan visibility-nya PRIVATE (Settings > General > Danger Zone > Change visibility), karena state sesi disimpan di Release repo."
} else {
    $ans = Read-Host "Buat repo PRIVATE baru `"$full`" dari folder ini dan push? [y/N]"
    if ($ans -match "^[yY]") {
        git init -q 2>$null
        git add -A 2>$null
        git commit -qm "RDPfread v1.0" 2>$null
        gh repo create $full --private --source=. --push
    } else {
        Write-Host "Dibatalkan. Buat repo-nya dulu, lalu jalankan wizard lagi."
        return
    }
}

function Set-SecretFromPrompt {
    param([string]$Name)
    $secure = Read-Host "Masukkan $Name (kosong = lewati)" -AsSecureString
    $plain = [System.Net.NetworkCredential]::new("", $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { Write-Host "  -> $Name dilewati."; return }
    $plain | gh secret set $Name --repo $full | Out-Null
    Write-Host "  -> $Name tersimpan sebagai secret."
}

Say "Secrets WAJIB"
Set-SecretFromPrompt "RDP_PASSWORD"
Set-SecretFromPrompt "TAILSCALE_AUTH_KEY"

Say "Secrets OPSIONAL (kosongkan bila tidak pakai)"
Set-SecretFromPrompt "STATE_ENCRYPTION_KEY"
Set-SecretFromPrompt "TELEGRAM_BOT_TOKEN"
Set-SecretFromPrompt "TELEGRAM_CHAT_ID"
Set-SecretFromPrompt "DISCORD_WEBHOOK_URL"

Say "Selesai"
Write-Host "Repo     : https://github.com/$full"
Write-Host "Jalankan : Actions -> 'RDPfread - RDP Windows 6 Jam Pro' -> Run workflow"
Write-Host "Atau     : gh workflow run rdp.yml --repo $full"

$doRun = $Run
if (-not $doRun) {
    $ans = Read-Host "Langsung Run workflow sekarang? [y/N]"
    if ($ans -match "^[yY]") { $doRun = $true }
}
if ($doRun) {
    gh workflow run rdp.yml --repo $full
    Write-Host "Workflow dijalankan. Pantau: gh run watch --repo $full / https://github.com/$full/actions"
}
