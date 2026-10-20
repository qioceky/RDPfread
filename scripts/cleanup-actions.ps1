# cleanup-actions.ps1 - hapus run workflow lama (sisakan KEEP_RUNS terakhir, default 10)
# agar tab Actions tetap rapi. Token: CLEANUP_TOKEN (PAT) atau GITHUB_TOKEN bawaan.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:cleanup"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$token = $env:CLEANUP_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:GITHUB_TOKEN }
if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    Write-Log "Token/repo tidak ada - cleanup dilewati."
    return
}
$keep = 10
if ($env:KEEP_RUNS -match "^\d+$") { $keep = [int]$env:KEEP_RUNS }
$headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28"; "User-Agent" = "RDPfread" }
$api = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"
try {
    $resp = Invoke-RestMethod -Uri "$api/actions/workflows/rdp.yml/runs?per_page=100&status=completed" -Headers $headers
    $ids = @($resp.workflow_runs | ForEach-Object { $_.id })
    $toDelete = $ids | Select-Object -Skip $keep
    $count = 0
    foreach ($id in $toDelete) {
        if ([string]$id -eq $env:GITHUB_RUN_ID) { continue }
        try { Invoke-RestMethod -Uri "$api/actions/runs/$id" -Method Delete -Headers $headers | Out-Null; $count++ } catch { }
    }
    Write-Log "Cleanup selesai: $count run lama dihapus (disisakan $keep)."
} catch { Write-Warn ("Cleanup gagal: " + $_.Exception.Message) }
