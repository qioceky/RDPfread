# setup-ssh.ps1 - OPSIONAL (input akses_ssh=ya): OpenSSH Server bawaan Windows.
# Memberi jalur terminal ke Windows selain RDP grafis - berguna dari Termux/HP.
# Login memakai akun Windows yang sama (user RDP + password secret RDP_PASSWORD),
# shell default PowerShell, dan port 22 dibatasi firewall hanya dari tailnet.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:ssh"
. (Join-Path $PSScriptRoot "lib-common.ps1")

if ($env:AKSES_SSH -ne "ya") {
    Write-Log "akses_ssh tidak aktif - OpenSSH dilewati."
    Update-Status @{ ssh_enabled = $false }
    return
}

Write-Log "Memasang OpenSSH Server (Windows Capability)..."
try {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop
    if ($cap.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Write-Log "OpenSSH Server terpasang."
} catch {
    Write-Warn ("Install OpenSSH gagal: " + $_.Exception.Message + " - sesi RDP tetap jalan.")
    Update-Status @{ ssh_enabled = $false }
    return
}

try { Start-Service sshd -ErrorAction SilentlyContinue } catch { }
try { Set-Service -Name sshd -StartupType Automatic } catch { }

# Shell default SSH = Windows PowerShell (selalu ada di image runner)
try {
    $psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $psPath -Type String
} catch { }

# Firewall: SSH hanya dari tailnet
Get-NetFirewallRule -DisplayName "RDPfread SSH (Tailscale only)" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "RDPfread SSH (Tailscale only)" -Direction Inbound -Protocol TCP `
    -LocalPort 22 -RemoteAddress "100.64.0.0/10" -Action Allow -Profile Any | Out-Null
# Rule bawaan OpenSSH membuka dari semua alamat - matikan demi konsistensi tailnet-only
try { Disable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue } catch { }

Update-Status @{ ssh_enabled = $true }
Write-Log "SSH aktif di port 22 (hanya tailnet). Login: ssh <user>@<IP Tailscale>, password = secret RDP_PASSWORD."
