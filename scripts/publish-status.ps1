# publish-status.ps1 - publikasi status ke branch orphan "status":
#   rdp-status.json (mesin) + STATUS.md (dashboard manusia).
# Pemakaian: publish-status.ps1 [-Active true|false]
param([string]$Active = "")
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:status"
. (Join-Path $PSScriptRoot "lib-common.ps1")

if ($Active -eq "true")  { Update-Status @{ active = $true } }
if ($Active -eq "false") { Update-Status @{ active = $false } }

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    Write-Log "Token/repo tidak ada - publish status dilewati."
    return
}

Ensure-OutDir
$s = Read-Status
function V { param([string]$N) if ($s.PSObject.Properties.Name -contains $N -and $s.$N -ne $null) { return (Format-StatusValue $s.$N) } return "-" }
function VT { param([string]$N) if ($s.tools -and ($s.tools.PSObject.Properties.Name -contains $N)) { return [string]$s.tools.$N } return "-" }

$md = @"
# RDPfread Status

_Diperbarui: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) UTC_

| Field | Nilai |
|---|---|
| Aktif | $(V "active") |
| RDP | ``mstsc`` ke ``$(V "tailscale_ip")`` - user ``$(V "rdp_user")`` |
| SSH aktif | $(V "ssh_enabled") |
| MagicDNS | $(V "tailscale_dns") |
| Hostname | $(V "hostname") |
| OS | $(V "os") |
| CPU / RAM / Disk bebas | $(V "cpu_threads") thread / $(V "ram_gb") GB / $(V "disk_free_gb") GB |
| Preset / Timezone | $(V "preset") / $(V "timezone") |
| Tools | node $(VT "node"), python $(VT "python"), git $(VT "git") |
| Mulai | $(V "started_at") |
| Berakhir | $(V "expires_at") |
| Run | [$(V "run_number")]($(V "run_url")) |
"@

$work = Join-Path $env:TEMP ("rdpfread-status-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    Copy-Item (Get-StatusPath) (Join-Path $work "rdp-status.json") -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $work "rdp-status.json"))) { "{}" | Set-Content (Join-Path $work "rdp-status.json") }
    $md | Set-Content -Path (Join-Path $work "STATUS.md") -Encoding UTF8

    $git = Get-GitExe
    if (-not $git) { Write-Warn "git tidak ditemukan (path standar maupun PATH) - publish status dilewati."; return }
    Push-Location $work
    & $git init -q 2>$null
    & $git config user.email "rdpfread@users.noreply.github.com"
    & $git config user.name "RDPfread Bot"
    & $git add rdp-status.json STATUS.md 2>$null
    & $git commit -qm ("status: " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) 2>$null
    if ($LASTEXITCODE -eq 0) {
        $url = "https://x-access-token:{0}@github.com/{1}.git" -f $token, $env:GITHUB_REPOSITORY
        & $git push -q --force $url HEAD:status 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Log "Status terpublikasi ke branch status." }
        else { Write-Warn "Push branch status gagal - dilewati." }
    } else { Write-Log "Tidak ada perubahan status." }
    Pop-Location
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
