# setup-preset.ps1 - pasang software sesuai input preset workflow.
#   minimal : (tidak ada tambahan)
#   ringan  : Firefox + LibreOffice + SumatraPDF + 7-Zip + Notepad++ + PowerShell 7
#             (kebutuhan kantor/harian serba ringan, tanpa toolchain dev)
#   web     : Node.js LTS + Python 3.12
#   dev     : web + Git + VS Code
#   full    : dev + PowerShell 7 + Windows Terminal + Chrome + 7-Zip + Notepad++
#   desktop : full + PowerToys + VLC + LibreOffice + OBS Studio (pengalaman desktop Windows penuh)
#   game    : ringan + JDK 21 & JRE 8 (Temurin) + PrismLauncher, lalu setup-games.ps1
#             (Mesa3D OpenGL software, launcher Minecraft resmi, paket SA-MP/GTA SA)
# Installer lewat winget (bawaan image Windows GitHub), fallback Chocolatey.
$ErrorActionPreference = "Continue"
$script:RdpTag = "RDPfread:preset"
. (Join-Path $PSScriptRoot "lib-common.ps1")

$preset = $env:PRESET
if ([string]::IsNullOrWhiteSpace($preset)) { $preset = "minimal" }
Write-Log "Preset: $preset"

$catalog = @{
    "OpenJS.NodeJS.LTS"          = @{ Name = "Node.js LTS"; Choco = "nodejs-lts" }
    "Python.Python.3.12"         = @{ Name = "Python 3.12"; Choco = "python312" }
    "Git.Git"                    = @{ Name = "Git";         Choco = "git" }
    "Microsoft.VisualStudioCode" = @{ Name = "VS Code";     Choco = "vscode" }
    "Google.Chrome"              = @{ Name = "Chrome";      Choco = "googlechrome" }
    "7zip.7zip"                  = @{ Name = "7-Zip";       Choco = "7zip" }
    "Notepad++.Notepad++"        = @{ Name = "Notepad++";   Choco = "notepadplusplus" }
    "Microsoft.PowerShell"       = @{ Name = "PowerShell 7"; Choco = "powershell-core" }
    "Microsoft.WindowsTerminal" = @{ Name = "Windows Terminal"; Choco = "microsoft-windows-terminal" }
    "Microsoft.PowerToys"        = @{ Name = "PowerToys";   Choco = "powertoys" }
    "VideoLAN.VLC"               = @{ Name = "VLC";         Choco = "vlc" }
    "LibreOffice.LibreOffice"    = @{ Name = "LibreOffice"; Choco = "libreoffice-fresh" }
    "OBSProject.OBSStudio"       = @{ Name = "OBS Studio";  Choco = "obs-studio" }
    "Mozilla.Firefox"            = @{ Name = "Firefox";     Choco = "firefox" }
    "SumatraPDF.SumatraPDF"      = @{ Name = "SumatraPDF";  Choco = "sumatrapdf" }
    "EclipseAdoptium.Temurin.21.JDK" = @{ Name = "JDK 21 Temurin"; Choco = "temurin21" }
    "EclipseAdoptium.Temurin.8.JRE"  = @{ Name = "JRE 8 Temurin";  Choco = "temurin8" }
    "PrismLauncher.PrismLauncher"    = @{ Name = "PrismLauncher";  Choco = "prismlauncher" }
}
$plan = @{
    "minimal" = @()
    "ringan"  = @("Mozilla.Firefox", "LibreOffice.LibreOffice", "SumatraPDF.SumatraPDF", "7zip.7zip", "Notepad++.Notepad++", "Microsoft.PowerShell")
    "web"     = @("OpenJS.NodeJS.LTS", "Python.Python.3.12")
    "dev"     = @("OpenJS.NodeJS.LTS", "Python.Python.3.12", "Git.Git", "Microsoft.VisualStudioCode")
    "full"    = @("OpenJS.NodeJS.LTS", "Python.Python.3.12", "Git.Git", "Microsoft.VisualStudioCode", "Microsoft.PowerShell", "Microsoft.WindowsTerminal", "Google.Chrome", "7zip.7zip", "Notepad++.Notepad++")
    "desktop" = @("OpenJS.NodeJS.LTS", "Python.Python.3.12", "Git.Git", "Microsoft.VisualStudioCode", "Microsoft.PowerShell", "Microsoft.WindowsTerminal", "Google.Chrome", "7zip.7zip", "Notepad++.Notepad++", "Microsoft.PowerToys", "VideoLAN.VLC", "LibreOffice.LibreOffice", "OBSProject.OBSStudio")
    "game"    = @("Mozilla.Firefox", "7zip.7zip", "Microsoft.PowerShell", "EclipseAdoptium.Temurin.21.JDK", "EclipseAdoptium.Temurin.8.JRE", "PrismLauncher.PrismLauncher")
}
if (-not $plan.ContainsKey($preset)) { Write-Warn "Preset tidak dikenal: $preset - diperlakukan sebagai minimal."; $preset = "minimal" }

$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$hasChoco  = [bool](Get-Command choco  -ErrorAction SilentlyContinue)
Write-Log "winget=$hasWinget choco=$hasChoco"

foreach ($id in $plan[$preset]) {
    $item = $catalog[$id]
    $ok = $false
    if ($hasWinget) {
        Write-Log "Install $($item.Name) via winget ($id)..."
        winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) { $ok = $true }  # 0 atau "sudah terpasang"
    }
    if (-not $ok -and $hasChoco) {
        Write-Log "Install $($item.Name) via choco ($($item.Choco))..."
        choco install $item.Choco -y --no-progress 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true }
    }
    if ($ok) { Write-Log "$($item.Name) OK." } else { Write-Warn "$($item.Name) gagal dipasang - dilewati." }
}

# Refresh PATH untuk sesi ini lalu catat versi tools ke status
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
function ToolVer { param([string]$Cmd) $c = Get-Command $Cmd -ErrorAction SilentlyContinue; if ($c) { try { return ((& $Cmd --version 2>$null | Select-Object -First 1) -as [string]).Trim() } catch { return "" } } return "" }
$tools = [PSCustomObject]@{
    node   = ToolVer "node"
    python = ToolVer "python"
    git    = ToolVer "git"
    code   = ToolVer "code"
}
Update-Status @{ tools = $tools }
Write-Log ("Tools: node={0} python={1} git={2} code={3}" -f $tools.node, $tools.python, $tools.git, $tools.code)

# Preset game: setup-games.ps1 berjalan sebagai step workflow TERSENDIRI
# (v1.2.1) supaya kegagalannya terlihat jelas, tidak tertelan step ini.
# Di sini cukup verifikasi paket inti game benar-benar terpasang.
if ($preset -eq "game") {
    $javaExe = Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    $prismExe = Get-ChildItem "C:\Program Files" -Recurse -Filter "prismlauncher.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    Update-Status @{ game_pkgs = [PSCustomObject]@{ java = [bool]$javaExe; prism = [bool]$prismExe } }
    if ($javaExe) { Write-Log "Verifikasi preset game: Java OK ($($javaExe.FullName))." } else { Write-Warn "Verifikasi preset game: Java TIDAK ditemukan - Mesa/Minecraft tidak akan bekerja." }
    if ($prismExe) { Write-Log "Verifikasi preset game: PrismLauncher OK." } else { Write-Warn "Verifikasi preset game: PrismLauncher TIDAK ditemukan." }
}
