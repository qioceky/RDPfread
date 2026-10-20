# finalize.ps1 - penutup sesi: putuskan Tailscale, tandai status tidak aktif, notifikasi berhenti.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:finalize"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$ts = Get-TailscaleExe
if ($ts) {
    try { & $ts logout 2>$null | Out-Null; Write-Log "Tailscale logout." } catch { }
}
& (Join-Path $PSScriptRoot "publish-status.ps1") -Active false | Out-Null
$ip = Get-StatusValue "tailscale_ip"
& (Join-Path $PSScriptRoot "notify.ps1") -Event stopped -Message "RDPfread sesi berhenti (IP terakhir: $ip). State terakhir tersimpan di Release rdpfread-state-latest." | Out-Null
Write-Log "Finalize selesai."
