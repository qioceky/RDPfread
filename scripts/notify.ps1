# notify.ps1 - kirim notifikasi ke Telegram / Discord / webhook umum.
# Pemakaian: notify.ps1 -Event ready -Message "..."
# Secrets opsional: TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID, DISCORD_WEBHOOK_URL, NOTIFY_WEBHOOK_URL.
# Kegagalan notifikasi tidak pernah menggagalkan sesi.
param(
    [Parameter(Mandatory = $true)][string]$Event,
    [Parameter(Mandatory = $true)][string]$Message
)
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:notify"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$plain = ($Message -replace "<[^>]+>", "")

if ($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID) {
    try {
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $Message; parse_mode = "HTML" }
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" -Method Post -Body $body | Out-Null
        Write-Log "Notifikasi Telegram terkirim ($Event)."
    } catch { Write-Warn ("Telegram gagal: " + $_.Exception.Message) }
}
if ($env:DISCORD_WEBHOOK_URL) {
    try {
        $json = @{ content = $plain } | ConvertTo-Json
        Invoke-RestMethod -Uri $env:DISCORD_WEBHOOK_URL -Method Post -ContentType "application/json" -Body $json | Out-Null
        Write-Log "Notifikasi Discord terkirim ($Event)."
    } catch { Write-Warn ("Discord gagal: " + $_.Exception.Message) }
}
if ($env:NOTIFY_WEBHOOK_URL) {
    try {
        $json = @{ text = $plain; event = $Event } | ConvertTo-Json
        Invoke-RestMethod -Uri $env:NOTIFY_WEBHOOK_URL -Method Post -ContentType "application/json" -Body $json | Out-Null
        Write-Log "Notifikasi webhook terkirim ($Event)."
    } catch { Write-Warn ("Webhook gagal: " + $_.Exception.Message) }
}
