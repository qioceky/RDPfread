# setup-rdp.ps1 - setup dasar Windows: user RDP, password dari secret, RDP aktif,
# timezone, folder kerja C:\RDPData, dan status awal (started_at / expires_at).
$ErrorActionPreference = "Stop"
$script:RdpTag = "RDPfread:setup"
. (Join-Path $PSScriptRoot "lib-common.ps1")

# --- Validasi secret wajib ---
$pw = $env:RDP_PASSWORD
if ([string]::IsNullOrWhiteSpace($pw) -or $pw.Length -lt 8) {
    throw "Secret RDP_PASSWORD belum diisi atau kurang dari 8 karakter. Isi di Settings > Secrets and variables > Actions."
}

# --- Username ---
$user = $env:RDP_USER
if ([string]::IsNullOrWhiteSpace($user)) { $user = "fread" }
if ($user -notmatch "^[A-Za-z0-9._-]{1,20}$") { throw "Username RDP tidak valid: $user" }

# --- Timezone: nama IANA (input workflow) -> ID timezone Windows ---
$tzMap = @{
    "Asia/Jakarta"       = "SE Asia Standard Time"
    "Asia/Singapore"     = "Singapore Standard Time"
    "Asia/Tokyo"         = "Tokyo Standard Time"
    "UTC"                = "UTC"
    "Europe/London"      = "GMT Standard Time"
    "America/New_York"   = "Eastern Standard Time"
}
$tzName = $env:TZ_NAME
if ([string]::IsNullOrWhiteSpace($tzName)) { $tzName = "Asia/Jakarta" }
if ($tzMap.ContainsKey($tzName)) {
    try { Set-TimeZone -Id $tzMap[$tzName]; Write-Log ("Timezone diset: {0} ({1})" -f $tzName, $tzMap[$tzName]) }
    catch { Write-Warn ("Gagal set timezone: " + $_.Exception.Message) }
} else { Write-Warn ("Timezone tidak dikenal, dilewati: " + $tzName) }

# --- Buat / perbarui user RDP ---
$securePw = ConvertTo-SecureString $pw -AsPlainText -Force
$existing = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if ($existing) {
    Set-LocalUser -Name $user -Password $securePw -PasswordNeverExpires $true
    Enable-LocalUser -Name $user
    Write-Log "User $user sudah ada - password diperbarui dari secret."
} else {
    New-LocalUser -Name $user -Password $securePw -AccountNeverExpires -PasswordNeverExpires `
        -Description "RDPfread RDP user" | Out-Null
    Write-Log "User $user dibuat."
}
foreach ($grp in @("Administrators", "Remote Desktop Users")) {
    try { Add-LocalGroupMember -Group $grp -Member $user -ErrorAction SilentlyContinue } catch { }
}
Write-Log "User $user masuk grup Administrators + Remote Desktop Users."

# --- Aktifkan Remote Desktop (NLA wajib, lebih aman) ---
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
try { Start-Service -Name TermService -ErrorAction SilentlyContinue } catch { }
Write-Log "Remote Desktop aktif (port 3389, NLA on). Firewall dibatasi ke tailnet di setup-akses."

# --- Folder kerja persisten ---
$dataDir = "C:\RDPData"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
try { icacls $dataDir /grant "${user}:(OI)(CI)M" | Out-Null } catch { }
Write-Log "Folder kerja persisten: $dataDir (ikut disimpan ke state antar sesi)."

# --- Status awal ---
$dur = 342
if ($env:DUR -match "^\d+$") { $dur = [int]$env:DUR }
$now = (Get-Date).ToUniversalTime()
$os = Get-CimInstance Win32_OperatingSystem
$diskFreeGb = 0
try { $diskFreeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 1) } catch { }
Update-Status @{
    schema      = 2
    project     = "RDPfread"
    active      = $true
    rdp_user    = $user
    os          = $os.Caption
    cpu_threads = [int]$env:NUMBER_OF_PROCESSORS
    ram_gb      = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    disk_free_gb = $diskFreeGb
    preset      = $(if ($env:PRESET) { $env:PRESET } else { "minimal" })
    optimasi    = $(if ($env:OPTIMASI) { $env:OPTIMASI } else { "ya" })
    timezone    = $tzName
    started_at  = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
    expires_at  = $now.AddMinutes($dur).ToString("yyyy-MM-ddTHH:mm:ssZ")
    run_number  = $env:GITHUB_RUN_NUMBER
    run_url     = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
}
Write-Log ("Sesi dimulai {0} UTC, berakhir {1} UTC (durasi {2} menit)." -f $now.ToString("HH:mm"), $now.AddMinutes($dur).ToString("HH:mm"), $dur)
