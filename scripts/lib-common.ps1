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
