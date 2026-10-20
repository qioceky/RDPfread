# keepalive.ps1 - jaga sesi hidup sampai batas waktu:
#  + heartbeat resource (CPU/RAM/disk + IP Tailscale) tiap 5 menit, publish status
#  + pastikan service RDP & Tailscale tetap jalan, reconnect Tailscale bila putus
#  + checkpoint state tiap 15 menit
#  + notifikasi "expiring" 30 menit sebelum habis
#  + handover: dispatch sesi berikutnya 20 menit sebelum habis (bila perpanjang otomatis)
#  + berhenti sendiri 3 menit sebelum expires_at (batas keras job GitHub 360 menit)
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:keepalive"
. (Join-Path $PSScriptRoot "lib-common.ps1")
$here = $PSScriptRoot

# Baca expires_at sebagai UTC murni (lihat ConvertTo-UtcDateTime di lib-common -
# jangan pakai [DateTime]::Parse + ToUniversalTime: hasilnya bergeser seoffset
# timezone lokal VM dan pernah mematikan sesi dalam 0 detik di v1.0.0).
$exp = Get-StatusUtc "expires_at"
$started = Get-StatusUtc "started_at"
$nowUtc = (Get-Date).ToUniversalTime()
if (-not $exp -or $exp -le $nowUtc) {
    # Pengaman anti-mati-seketika: hitung ulang dari started_at + durasi, atau dari sekarang.
    $durMin = 342
    if ($env:DUR -match "^\d+$") { $durMin = [int]$env:DUR }
    if ($started -and $started.AddMinutes($durMin) -gt $nowUtc) {
        $exp = $started.AddMinutes($durMin)
        Write-Warn "expires_at terbaca tidak wajar - dihitung ulang dari started_at + $durMin menit."
    } else {
        $exp = $nowUtc.AddMinutes($durMin)
        Write-Warn "expires_at tidak terbaca - memakai sekarang + $durMin menit."
    }
}
$leadMin = 20
if ($env:HANDOVER_LEAD_MIN -match "^\d+$") { $leadMin = [int]$env:HANDOVER_LEAD_MIN }
$stop = $exp.AddMinutes(-3)
Write-Log ("Sesi aktif sampai {0} UTC (checkpoint 15 mnt, handover {1} mnt sebelum habis)." -f $exp.ToString("yyyy-MM-dd HH:mm"), $leadMin)

function Send-DispatchNext {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -or [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { return $false }
    $headers = @{ Authorization = "Bearer $($env:GITHUB_TOKEN)"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28"; "User-Agent" = "RDPfread" }
    $inputs = @{
        durasi_menit        = $(if ($env:DUR) { $env:DUR } else { "342" })
        hostname            = $(if ($env:RDP_HOST) { $env:RDP_HOST } else { "rdpfread" })
        rdp_user            = $(if ($env:RDP_USER) { $env:RDP_USER } else { "fread" })
        runner              = $(if ($env:RUNNER_IMAGE) { $env:RUNNER_IMAGE } else { "windows-2022" })
        preset              = $(if ($env:PRESET) { $env:PRESET } else { "minimal" })
        akses_ssh           = $(if ($env:AKSES_SSH) { $env:AKSES_SSH } else { "tidak" })
        timezone            = $(if ($env:TZ_NAME) { $env:TZ_NAME } else { "Asia/Jakarta" })
        perpanjang_otomatis = $(if ($env:PERPANJANG_OTOMATIS) { $env:PERPANJANG_OTOMATIS } else { "ya" })
        renewal             = "ya"
    }
    $body = @{ ref = "main"; inputs = $inputs } | ConvertTo-Json -Depth 5
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/actions/workflows/rdp.yml/dispatches" -Method Post -Headers $headers -ContentType "application/json" -Body $body | Out-Null
        return $true
    } catch { Write-Warn ("Dispatch sesi berikutnya gagal: " + $_.Exception.Message); return $false }
}

$handed = $false
$notifiedExpiring = $false
$i = 0
while ((Get-Date).ToUniversalTime() -lt $stop) {
    Start-Sleep -Seconds 60
    $i++
    $now = (Get-Date).ToUniversalTime()
    $rem = [int][math]::Floor(($exp - $now).TotalMinutes)
    if ($rem -lt 0) { $rem = 0 }

    # Pastikan layanan inti hidup
    foreach ($svc in @("TermService", "Tailscale")) {
        try { $s = Get-Service -Name $svc -ErrorAction SilentlyContinue; if ($s -and $s.Status -ne "Running") { Start-Service -Name $svc -ErrorAction SilentlyContinue } } catch { }
    }

    if ($i % 5 -eq 0) {
        $ts = Get-TailscaleExe
        $tsIp = ""
        if ($ts) { $o = & $ts ip -4 2>$null | Select-Object -First 1; if ($o) { $tsIp = ([string]$o).Trim() } }
        $cpu = "?"
        try { $cpu = [string](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average } catch { }
        $os = Get-CimInstance Win32_OperatingSystem
        $ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        $ramTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $disk = Get-PSDrive C
        $diskPct = [math]::Round(($disk.Used / ($disk.Used + $disk.Free)) * 100, 0)
        Write-Log ("detak #{0} | sisa {1} mnt | CPU {2}% | RAM {3}/{4} GB | disk C {5}% terpakai | tailscale={6}" -f $i, $rem, $cpu, $ramUsed, $ramTot, $diskPct, $(if ($tsIp) { $tsIp } else { "terputus" }))
        if (-not $tsIp) {
            if (-not $ts) {
                # Bedakan "terputus" vs "binary hilang" supaya log bisa didiagnosis
                # (insiden 2026-10-20: tailscale.exe lenyap dari VM di tengah sesi).
                if (-not $script:warnedNoTsExe) { $script:warnedNoTsExe = $true; Write-Warn "tailscale.exe TIDAK DITEMUKAN di path standar - sesi tidak bisa dipulihkan dari dalam (dugaan insiden platform VM)." }
            } else {
                Write-Warn "Tailscale terputus - menyambung ulang..."
                # Node yang sudah terdaftar bisa reconnect TANPA auth key; key
                # hanya dipakai bila tersedia. Dulu reconnect ke-gate auth key
                # dan diam-diam tidak pernah jalan saat key tidak terbaca.
                if ($env:TAILSCALE_AUTH_KEY) { & $ts up --authkey $env:TAILSCALE_AUTH_KEY --hostname (Get-RdpHostname) --accept-dns=false --timeout=60s 2>$null | Out-Null }
                else { & $ts up --accept-dns=false --timeout=60s 2>$null | Out-Null }
            }
        }
        & (Join-Path $here "publish-status.ps1") | Out-Null
    }

    if (-not $notifiedExpiring -and $rem -le 30 -and $rem -gt $leadMin) {
        $notifiedExpiring = $true
        & (Join-Path $here "notify.ps1") -Event expiring -Message "RDPfread sesi berakhir dalam +/- $rem menit. Renewal otomatis: $($env:PERPANJANG_OTOMATIS)" | Out-Null
    }

    if ($i % 15 -eq 0) {
        Write-Log "Auto-checkpoint 15 menit..."
        & (Join-Path $here "persist-state.ps1") -Checkpoint | Out-Null
    }

    if (-not $handed -and $env:PERPANJANG_OTOMATIS -ne "tidak" -and $rem -le $leadMin) {
        Write-Log "Handover: simpan state + dispatch sesi berikutnya (sisa $rem mnt)..."
        & (Join-Path $here "persist-state.ps1") -Checkpoint | Out-Null
        if (Send-DispatchNext) {
            $handed = $true
            Update-Status @{ handover = [PSCustomObject]@{ status = "dispatched"; at = $now.ToString("yyyy-MM-ddTHH:mm:ssZ") } }
            & (Join-Path $here "notify.ps1") -Event handover -Message "RDPfread sesi berikutnya dijadwalkan (handover). State & IP Tailscale dipertahankan sejauh runner mengizinkan." | Out-Null
            Write-Log "Sesi berikutnya dijadwalkan."
        }
    }
}
Write-Log "Batas waktu tercapai - berhenti dengan aman."
