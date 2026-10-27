# lib-common.ps1 - helper bersama RDPfread. Di-dot-source, bukan dijalankan langsung.
# Menyediakan: log, workspace, status JSON, hostname Tailscale, summary.
$script:RdpTag = "RDPfread"

function Write-Log  { param([string]$Msg) Write-Host ("[{0} UTC][{1}] {2}" -f (Get-Date).ToUniversalTime().ToString("HH:mm:ss"), $script:RdpTag, $Msg) }
function Write-Warn { param([string]$Msg) Write-Log ("WARN: " + $Msg) }
function Write-ErrLog { param([string]$Msg) Write-Log ("ERROR: " + $Msg) }

function Get-WorkspacePath {
    if ($env:GITHUB_WORKSPACE) { return $env:GITHUB_WORKSPACE }
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
function Get-StatusPath { return (Join-Path (Get-WorkspacePath) "out\rdp-status.json") }
function Ensure-OutDir {
    $dir = Join-Path (Get-WorkspacePath) "out"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Read-Status {
    $p = Get-StatusPath
    if (Test-Path $p) {
        try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{}
}

function Set-Prop {
    param($Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties.Name -contains $Name) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Update-Status @{ key = value; ... } - merge dangkal ke rdp-status.json
function Update-Status {
    param([hashtable]$Patch)
    Ensure-OutDir
    $status = Read-Status
    foreach ($k in $Patch.Keys) { Set-Prop $status $k $Patch[$k] }
    ($status | ConvertTo-Json -Depth 10) | Set-Content -Path (Get-StatusPath) -Encoding UTF8
}

function Get-StatusValue {
    param([string]$Name)
    $s = Read-Status
    if ($s.PSObject.Properties.Name -contains $Name) { return $s.$Name }
    return $null
}

# PENTING (bug v1.0.0): ConvertFrom-Json di PowerShell 7 mengubah string tanggal ISO
# menjadi objek [DateTime] LOKAL (jam dinding dipertahankan, zona dibuang). Nilai
# expires_at kita adalah UTC - jadi nilai DateTime hasil baca harus dianggap UTC
# apa adanya (SpecifyKind Utc), BUKAN dikonversi dari zona lokal mesin. Tanpa ini,
# setelah timezone VM diganti ke Asia/Jakarta, jam berakhir bergeser -7 jam dan
# keepalive mengira sesi sudah habis.
function ConvertTo-UtcDateTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    try { return [DateTime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles) }
    catch { return $null }
}

function Get-StatusUtc {
    param([string]$Name)
    return (ConvertTo-UtcDateTime (Get-StatusValue $Name))
}

# Format nilai status untuk ditampilkan: DateTime hasil baca JSON ditampilkan
# kembali sebagai ISO UTC (bukan format lokal seperti 10/20/2026 ...).
function Format-StatusValue {
    param($Value)
    if ($null -eq $Value) { return "-" }
    if ($Value -is [DateTime]) { return $Value.ToString("yyyy-MM-ddTHH:mm:ssZ") }
    return [string]$Value
}

# Nama node Tailscale konsisten: <prefix>-<nomor run>, sama pola dengan QVPS.
function Get-RdpHostname {
    $base = ($env:RDP_HOST -replace "[^a-zA-Z0-9-]", "").ToLower().Trim("-")
    if ([string]::IsNullOrWhiteSpace($base)) { $base = "rdpfread" }
    if ($base.Length -gt 30) { $base = $base.Substring(0, 30).Trim("-") }
    $run = $env:GITHUB_RUN_NUMBER
    if ([string]::IsNullOrWhiteSpace($run)) { $run = "local" }
    return ("{0}-{1}" -f $base, $run)
}

function Add-Summary {
    param([string]$Text)
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text -Encoding UTF8
    }
}

function Get-TailscaleExe {
    $candidates = @(
        "C:\Program Files\Tailscale\tailscale.exe",
        "C:\Program Files (x86)\Tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Resolusi executable penting lewat path penuh dulu, PATH belakangan - pelajaran
# insiden 2026-10-20: di satu VM windows-2025, git/gh/tailscale mendadak tidak
# terlacak lewat PATH di tengah sesi (publish & upload state mati berjam-jam).
function Get-GitExe {
    $candidates = @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files\Git\bin\git.exe",
        "C:\Program Files (x86)\Git\cmd\git.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-GhExe {
    $candidates = @(
        "C:\Program Files\GitHub CLI\gh.exe",
        "C:\Program Files (x86)\GitHub CLI\gh.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# --- Profil user RDP (v1.2.1) ---
# Windows bisa memberi folder profil bersuffix (mis. C:\Users\fread.runnervmX)
# bila folder C:\Users\<user> sudah keburu ada sebelum logon pertama - folder
# buatan itu lalu yatim: isi restore tidak terlihat user, dan kerja user di
# profil asli tidak terbaca persist. Karena itu menulis ke profil SEBELUM
# logon dilarang: restore menampung item profil di staging
# (C:\RDPData\.profil-restore) dan merge-profile.ps1 menggabungkannya ke
# profil asli saat logon pertama. Untuk MEMBACA profil yang sudah terbentuk,
# selalu pakai resolver ini (membaca ProfileList), jangan menebak path.
function Get-RdpUserName {
    $u = Get-StatusValue "rdp_user"
    if ([string]::IsNullOrWhiteSpace($u)) { $u = $env:RDP_USER }
    return $u
}
function Get-ProfileDirForUser {
    param([string]$User)
    if ([string]::IsNullOrWhiteSpace($User)) { return $null }
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $key = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $p = (Get-ItemProperty -Path $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        if ($p) { return [Environment]::ExpandEnvironmentVariables([string]$p) }
    } catch { }
    return "C:\Users\$User"
}
function Get-ProfileStagingRoot { return "C:\RDPData\.profil-restore" }

# --- Pelepasan hive Default User terverifikasi (v1.5.4) ---
# Disatukan dari 4 skrip (setup-windows, setup-games, debloat-windows,
# debloat-full) yang sebelumnya masing-masing menduplikasi blok ~20 baris
# yang sama — duplikasi itulah yang membuat hardening v1.5.1 tertinggal di
# setup-games/debloat sampai v1.5.2. Perbaikan berikutnya cukup di sini.
# Mengembalikan $true bila mount hive benar-benar hilang DAN file
# NTUSER.DAT Default tidak terkunci (bisa dibuka eksklusif); $false bila
# gagal setelah 3 percobaan. Pelajaran insiden ProfSvc 2026-10-25: unload
# sekali + error disembunyikan pernah membuat NTUSER.DAT tetap terkunci,
# sehingga Windows gagal membuat profil baru.
function Invoke-VerifiedHiveUnload {
    param([string]$HiveName)
    $unloaded = $false
    for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        reg.exe unload "HKU\$HiveName" 2>$null | Out-Null
        Start-Sleep -Seconds 2
        if (-not (Test-Path "Registry::HKEY_USERS\$HiveName")) { $unloaded = $true }
    }
    $fileLocked = $false
    try {
        $probe = [System.IO.File]::Open("C:\Users\Default\NTUSER.DAT", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $probe.Close()
        $probe.Dispose()
    } catch { $fileLocked = $true }
    return ($unloaded -and -not $fileLocked)
}
