# make-rdp-file.ps1 - hasilkan file koneksi rdpfread.rdp siap klik.
# File .rdp berisi alamat + username + preferensi sesi (fullscreen 1920x1080,
# clipboard & drive redirection, audio) - TANPA password (format .rdp tidak
# menyimpan password dengan aman; mstsc/Windows App akan menanyakannya).
# Hasil ditulis ke out\connection\ (di-upload sebagai artifact oleh workflow)
# dan salinannya ke C:\RDPData.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:rdpfile"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$ip = Get-StatusValue "tailscale_ip"
$user = Get-StatusValue "rdp_user"
if ([string]::IsNullOrWhiteSpace([string]$ip)) { Write-Warn "IP Tailscale belum ada - file .rdp dilewati."; return }
if ([string]::IsNullOrWhiteSpace([string]$user)) { $user = "fread" }

$content = @"
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
winposstr:s:0,1,0,0,1280,800
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
disable full window drag:i:0
disable menu anims:i:0
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:$ip
username:s:$user
prompt for credentials:i:1
authentication level:i:2
enablecredsspsupport:i:1
redirectclipboard:i:1
redirectprinters:i:0
redirectcomports:i:0
redirectsmartcards:i:0
redirectdrives:i:1
drivestoredirect:s:*
redirectposdevices:i:0
autoreconnection enabled:i:1
"@

$outDir = Join-Path (Get-WorkspacePath) "out\connection"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$dest = Join-Path $outDir "rdpfread.rdp"
$content | Set-Content -Path $dest -Encoding ASCII
try { Copy-Item $dest "C:\RDPData\rdpfread.rdp" -Force -ErrorAction SilentlyContinue } catch { }
Write-Log "File koneksi dibuat: out\connection\rdpfread.rdp (address $ip, user $user, tanpa password)."
