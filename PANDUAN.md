# PANDUAN — RDPfread langkah demi langkah

## A. Buat Tailscale Auth Key
1. Login ke <https://login.tailscale.com/admin/settings/keys>
2. **Generate auth key** — disarankan: *Reusable* = ON, *Ephemeral* = ON, expiry 90 hari.
3. Salin key-nya (`tskey-auth-...`). Key ini jadi secret `TAILSCALE_AUTH_KEY`.
4. Install aplikasi Tailscale di HP/PC dan login dengan akun yang sama.

## B. Siapkan Repository (WAJIB Private)
Repo RDPfread yang lama masih **publik** — sebelum memakai versi ini:
1. Buka repo → **Settings → General → Danger Zone → Change repository visibility → Make private**.
2. Upload/push file-file versi 1.0 ini ke repo (atau jalankan wizard di langkah C yang bisa push untukmu).

## C. Isi Secrets
Cara cepat: `.\setup-wizard.ps1` di Windows, atau `bash setup-wizard.sh` di Linux/Termux (butuh `gh` login).
Cara manual: repo → **Settings → Secrets and variables → Actions → New repository secret**, buat minimal:
- `RDP_PASSWORD` — min. 8 karakter, kuat & unik.
- `TAILSCALE_AUTH_KEY` — dari langkah A.
Opsional: `STATE_ENCRYPTION_KEY`, `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, `DISCORD_WEBHOOK_URL`.

Untuk notifikasi Telegram: buat bot via @BotFather → dapat token; kirim pesan ke bot-mu, lalu buka `https://api.telegram.org/bot<TOKEN>/getUpdates` untuk melihat `chat_id`.

## D. Jalankan
1. Tab **Actions → RDPfread — RDP Windows 6 Jam Pro → Run workflow**.
2. Untuk pemakaian umum: runner `windows-2022`, preset `minimal`, timezone `Asia/Jakarta`, perpanjang `ya`.
   - Butuh Node/Python → preset `web`.
   - Butuh Git + VS Code → preset `dev`.
   - Butuh semuanya + browser → preset `full`.
   - Mau buat harian/kantor yang ringan (Firefox, LibreOffice pengganti Word/Excel, PDF) → preset `ringan`.
   - Mau desktop Windows lengkap (PowerToys, VLC, LibreOffice, OBS) → preset `desktop`.
   - Mau main game ringan → preset `game` (Minecraft Java + Prism, 6 game gratis ringan — Mindustry, Luanti, GZDoom+Freedoom, OpenTTD, SuperTuxKart, Battle for Wesnoth — dan GTA SA/SA-MP). Catatan game: VM tidak punya GPU (render software) — game ringan/2D/era 2004 yang realistis. GTA SA-nya dari salinan milikmu sendiri: taruh di `C:\RDPData\GTASA` (ada `gta_sa.exe`), lalu jalankan sesi preset `game` berikutnya — patch-nya (ASI Loader, SilentPatch, dgVoodoo2) dipasang otomatis; installer SA-MP taruh manual di `C:\RDPData\Games-Setup` (situs resminya sedang mati). Sejak v1.2.1 isi profilmu (Desktop, .minecraft, dll) digabungkan ke profil asli saat login pertama — tunggu ±1 menit setelah masuk desktop bila file restore belum muncul. Folder game tidak ikut state (terlalu besar untuk batas Release GitHub), tapi world Minecraft & instance PrismLauncher ikut tersimpan.
   - Mau bisa masuk lewat terminal juga (dari Termux) → set `akses_ssh` = `ya`.
   - `optimasi` biarkan `ya` (default): disk runner dibersihkan & service latar non-esensial dimatikan supaya sesi lebih lega; set `tidak` hanya bila ada service bawaan yang kamu perlukan.
3. Klik **Run workflow**, tunggu ±3–6 menit sampai step *Setup akses Tailscale* selesai.

## E. Connect
IP ada di: Summary run (blok **RDP SIAP**), notifikasi Telegram/Discord (bila aktif), atau branch `status` → `STATUS.md`.

- **Windows:** tekan Win+R → `mstsc` → Computer: `100.x.x.x` → user `fread` → password = secret `RDP_PASSWORD`. Atau unduh artifact **rdpfread-connection** dari halaman run → klik dua kali `rdpfread.rdp` → tinggal isi password.
- **Android/iOS:** buka **Windows App** (dulu Microsoft Remote Desktop) → **+ → Add PC** → PC name `100.x.x.x` → user `fread`.
- **Terminal (bila `akses_ssh=ya` saat Run):** `ssh fread@100.x.x.x` — password sama, shell-nya PowerShell.
- Pastikan Tailscale di HP/PC kamu **aktif** — tanpa itu IP `100.x.x.x` tidak akan terjangkau.

Di dalam RDP: simpan semua pekerjaan di **`C:\RDPData`**. Yang ikut tersimpan antar sesi: `C:\RDPData`, Desktop, Documents, Downloads, Pictures, Videos, Music, dan profil browser (Chrome/Edge/Firefox — termasuk sesi login, berkat kunci DPAPI yang ikut dipulihkan). Folder di luar daftar `config/backup-paths.txt` akan hilang saat sesi berganti.

## F. Menghentikan
- **Sesi ini saja**: biarkan — ia berhenti sendiri 3 menit sebelum batas.
- **Total (tanpa estafet)**: Actions → cancel run yang berjalan **dan** cancel semua run yang masih *Queued*.
- Data tetap aman di Release `rdpfread-state-latest` untuk sesi berikutnya, kecuali kamu menghapus release itu.

## G. Troubleshooting
| Gejala | Cek |
|---|---|
| Workflow gagal di *Setup akses Tailscale* | Auth key kedaluwarsa/dicabut, atau device butuh approval di admin console Tailscale. |
| RDP timeout / IP tidak terjangkau | HP/PC belum login Tailscale di tailnet yang sama, atau IP berubah — cek `STATUS.md` terbaru di branch `status`. |
| Password ditolak | Pastikan secret `RDP_PASSWORD` benar (min. 8) dan username sesuai input Run (`fread` secara default). |
| Sertifikat RDP diperingatkan | Wajar untuk runner ephemeral — sertifikatnya self-signed milik VM sementara; pastikan IP-nya benar dari `STATUS.md` sebelum lanjut. |
| State tidak kembali | Release `rdpfread-state-latest` terhapus, arsip > ±1,9 GB, path tidak ada di `config/backup-paths.txt`, atau `STATE_ENCRYPTION_KEY` berubah sejak state disimpan. |
| Preset gagal memasang aplikasi | Cek log step *Pasang preset software* — winget/choco di image runner kadang berubah; sesi RDP sendiri tetap bisa dipakai. |
| Renewal tidak jalan | Ada run lain mengantre (concurrency group sama) atau run induk di-cancel — cek tab Actions. |
