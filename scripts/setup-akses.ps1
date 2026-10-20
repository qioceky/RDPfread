# setup-akses.ps1 - pasang Tailscale resmi, sambungkan ke tailnet user,
# ambil IP 100.x, dan batasi firewall RDP HANYA dari jaringan Tailscale (100.64.0.0/10).
$ErrorActionPreference = "Stop"
$script:RdpTag = "RDPfread:akses"
. (Join-Path $PSScriptRoot "lib-common.ps1")

if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_AUTH_KEY)) {
    throw "Secret TAILSCALE_AUTH_KEY belum diisi. Buat di https://login.tailscale.com/admin/settings/keys lalu isi di Settings repo."
}

# --- Install Tailscale dari sumber resmi bila belum ada ---
$ts = Get-TailscaleExe
if (-not $ts) {
    $msi = Join-Path $env:TEMP "tailscale-setup-latest-amd64.msi"
    Write-Log "Mengunduh installer resmi Tailscale..."
    Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile $msi
    $proc = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/quiet", "/norestart" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Install Tailscale gagal (exit $($proc.ExitCode))." }
    $ts = Get-TailscaleExe
    if (-not $ts) { throw "tailscale.exe tidak ditemukan setelah install." }
}
Write-Log "Tailscale terpasang: $ts"
try { Start-Service -Name Tailscale -ErrorAction SilentlyContinue } catch { }

# --- Sambungkan ke tailnet ---
$hostname = Get-RdpHostname
Write-Log "Menghubungkan ke tailnet sebagai $hostname ..."
& $ts up --authkey $env:TAILSCALE_AUTH_KEY --hostname $hostname --accept-dns=false --timeout=60s
if ($LASTEXITCODE -ne 0) {
    Write-Warn "tailscale up gagal, coba sekali lagi..."
    Start-Sleep -Seconds 5
    & $ts up --authkey $env:TAILSCALE_AUTH_KEY --hostname $hostname --accept-dns=false --timeout=60s
    if ($LASTEXITCODE -ne 0) { throw "tailscale up tetap gagal - cek auth key / approval device di admin Tailscale." }
}

# --- Tunggu IP Tailscale ---
$ip = $null
for ($i = 0; $i -lt 30 -and -not $ip; $i++) {
    $out = & $ts ip -4 2>$null | Select-Object -First 1
    if ($out -match "^\d+\.\d+\.\d+\.\d+$") { $ip = $out.Trim() }
    if (-not $ip) { Start-Sleep -Seconds 2 }
}
if (-not $ip) { throw "IP Tailscale tidak kunjung muncul." }

$dns = ""
try {
    $st = & $ts status --json | ConvertFrom-Json
    if ($st.Self.DNSName) { $dns = $st.Self.DNSName.TrimEnd(".") }
} catch { }

Update-Status @{ tailscale_ip = $ip; tailscale_dns = $dns; hostname = $hostname }
Write-Log "Terhubung. IP Tailscale: $ip  DNS: $dns"

# --- Firewall: RDP hanya dari tailnet ---
# Matikan rule Remote Desktop bawaan yang membuka dari semua alamat,
# ganti dengan rule khusus RDPfread yang dibatasi 100.64.0.0/10 (CGNAT Tailscale).
try { Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue } catch { }
Get-NetFirewallRule -DisplayName "RDPfread RDP (Tailscale only)" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "RDPfread RDP (Tailscale only)" -Direction Inbound -Protocol TCP `
    -LocalPort 3389 -RemoteAddress "100.64.0.0/10" -Action Allow -Profile Any | Out-Null
Write-Log "Firewall RDP dibatasi hanya dari 100.64.0.0/10 (tailnet)."

# --- File info koneksi di folder kerja + Public Desktop ---
$user = Get-StatusValue "rdp_user"
$expires = Get-StatusValue "expires_at"
$info = @"
RDPfread - info koneksi
=======================
Komputer / IP : $ip
MagicDNS      : $dns
User          : $user
Password      : sama dengan secret RDP_PASSWORD di repo
Port          : 3389
Berakhir (UTC): $expires

Cara connect:
- Windows : buka Remote Desktop Connection (mstsc) > Computer = $ip
- Android/iOS: aplikasi Microsoft Remote Desktop / Windows App > PC name = $ip
- Pastikan aplikasi Tailscale di HP/PC kamu aktif & login tailnet yang sama.

Simpan file kerjamu di C:\RDPData - folder itu yang ikut disimpan antar sesi.
"@
$info | Set-Content -Path "C:\RDPData\rdpfread-info.txt" -Encoding UTF8
try { $info | Set-Content -Path "C:\Users\Public\Desktop\RDPfread Info.txt" -Encoding UTF8 } catch { }

Add-Summary "## RDP SIAP`n`n- IP Tailscale: ``$ip```n- User: ``$user```n- Connect: ``mstsc`` / Microsoft Remote Desktop ke ``$ip`` (password = secret RDP_PASSWORD)`n- Berakhir (UTC): $expires`n"
Write-Log "Info koneksi ditulis ke C:\RDPData\rdpfread-info.txt"
