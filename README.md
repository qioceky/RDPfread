# RDPfread — RDP Windows 6 Jam Pro

RDP **Windows** gratis yang dijalankan oleh **GitHub Actions** dan diakses lewat **Remote Desktop melalui Tailscale privat**. RDPfread adalah project RDP runner mandiri — pasangan Windows dari [QVPS](https://github.com/qioceky/qvps-runner) (Linux/SSH). Versi 1.0 ini adalah perapihan total dari versi awal satu file: sekarang modular, aman, dan terstruktur seperti QVPS. Daftar peningkatannya ada di [UPGRADES.md](UPGRADES.md), panduan langkah demi langkah di [PANDUAN.md](PANDUAN.md).

> ⚠️ **Gunakan repository PRIVATE.** State sesi (isi `C:\RDPData`, Desktop & Documents user) disimpan ke Release & artifact repo agar pekerjaanmu tetap ada antar sesi. Di repo publik, siapa pun bisa mengunduhnya. Repo versi awal project ini masih publik — ubah ke Private sebelum memakai versi ini.

---

## ✨ Fitur unggulan

| Fitur | Keterangan |
|---|---|
| 🎛️ **Preset software** | Pilih saat Run: `minimal` / `web` (Node LTS + Python) / `dev` (web + Git + VS Code) / `full` (dev + PowerShell 7 + Windows Terminal + Chrome) / `desktop` (full + PowerToys + VLC + LibreOffice + OBS Studio) |
| 🪟 **Tweak khas Windows** | Power plan High Performance (tanpa sleep), Explorer menampilkan ekstensi & file tersembunyi, long paths aktif, clipboard/drive/audio redirection RDP, shortcut `RDPData` di desktop |
| 🖱️ **File `.rdp` siap klik** | Artifact `rdpfread-connection` berisi `rdpfread.rdp` (IP + user + fullscreen) — unduh, klik dua kali, masukkan password, langsung terhubung |
| 🔑 **SSH ke Windows (opsional)** | Input `akses_ssh=ya` memasang OpenSSH Server bawaan Windows: `ssh fread@100.x.x.x` dengan password yang sama, shell PowerShell, tetap hanya dari tailnet |
| 🔐 **Password dari Secret** | Password user RDP dibaca dari secret `RDP_PASSWORD` — tidak ada password tertulis di file repo |
| 🔒 **RDP hanya dari tailnet** | Rule firewall bawaan yang terbuka dimatikan; RDP (3389) hanya menerima dari `100.64.0.0/10` (jaringan Tailscale), NLA aktif |
| 💾 **State persisten** | `C:\RDPData` + Desktop & Documents user disimpan tiap 15 menit + di akhir sesi ke Release `rdpfread-state-latest`; daftar path bisa diubah di `config/backup-paths.txt` |
| 🔑 **State terenkripsi (opsional)** | Secret `STATE_ENCRYPTION_KEY` — arsip state dienkripsi AES-256 (openssl) sebelum upload |
| 🔔 **Notifikasi** | Telegram / Discord / webhook umum: saat RDP siap, mau berakhir, handover, dan berhenti |
| 🌏 **Timezone bisa dipilih** | Input workflow (default `Asia/Jakarta`), dipetakan otomatis ke timezone Windows |
| 📊 **Dashboard status** | Branch `status` berisi `rdp-status.json` (schema v2) **dan** `STATUS.md` yang enak dibaca |
| 🧙 **Setup wizard** | `setup-wizard.ps1` (Windows) / `setup-wizard.sh` (Linux/Termux) — siapkan repo + secrets + run pertama via `gh` |
| 📈 **Heartbeat resource** | Log keepalive menampilkan CPU, RAM, dan disk tiap 5 menit |
| 🔁 **Auto-renew** | Sesi berikutnya di-dispatch ±20 menit sebelum habis; state ikut pindah |

---

## 1. Cara kerja singkat

Setiap Run workflow, GitHub menyiapkan satu VM Windows sementara (ephemeral):

1. `cleanup-actions.ps1` menghapus run lama (sisakan 10).
2. `setup-rdp.ps1` membuat user RDP + password dari secret, mengaktifkan RDP (NLA), timezone, dan folder kerja `C:\RDPData`.
3. `restore-state.ps1` memulihkan state sesi sebelumnya dari Release `rdpfread-state-latest` per `manifest.json`.
4. `setup-akses.ps1` memasang Tailscale resmi, menyambung ke tailnet-mu, lalu membatasi firewall RDP hanya dari tailnet.
5. `setup-windows.ps1` menerapkan tweak khas Windows; `setup-ssh.ps1` memasang OpenSSH Server bila diminta; `setup-preset.ps1` memasang software sesuai pilihanmu (winget, fallback Chocolatey).
6. `publish-status.ps1` menulis dashboard ke branch `status`; `notify.ps1` mengirim notifikasi "siap"; `make-rdp-file.ps1` membuat file koneksi `.rdp` siap klik (di-upload sebagai artifact).
7. `keepalive.ps1` menjaga sesi: health-check tiap menit, checkpoint state tiap 15 menit, handover 20 menit sebelum habis, auto-stop 3 menit sebelum batas 6 jam GitHub.

## 2. Prasyarat

- Repository ini diset **Private**.
- Akun Tailscale + **auth key** (`tskey-auth-...`) dari <https://login.tailscale.com/admin/settings/keys>.
- Aplikasi Tailscale terpasang & login di HP/PC kamu, di tailnet yang sama.
- Aplikasi Remote Desktop: Windows bawaan (`mstsc`), atau **Windows App / Microsoft Remote Desktop** di Android/iOS.
- GitHub Actions aktif di repo.

## 3. Secrets

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Wajib? | Isi |
|---|---|---|
| `RDP_PASSWORD` | ✅ | Password user RDP. Min. 8 karakter, kuat & unik. |
| `TAILSCALE_AUTH_KEY` | ✅ | Auth key Tailscale (`tskey-auth-...`). |
| `STATE_ENCRYPTION_KEY` | — | Passphrase enkripsi arsip state (AES-256). **Jangan hilang** — tanpa ini state terenkripsi tidak bisa dipulihkan. |
| `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | — | Notifikasi Telegram. |
| `DISCORD_WEBHOOK_URL` | — | Notifikasi Discord. |
| `NOTIFY_WEBHOOK_URL` | — | Webhook JSON umum (`{"text": "...", "event": "..."}`). |
| `CLEANUP_TOKEN` | — | PAT scope `repo`/`actions` untuk menghapus run lama (fallback `GITHUB_TOKEN`). |

> Cara cepat: jalankan `setup-wizard.ps1` di Windows atau `bash setup-wizard.sh` di Linux/Termux (butuh `gh` yang sudah login).

## 4. Menjalankan sesi

1. Tab **Actions → RDPfread — RDP Windows 6 Jam Pro → Run workflow**.
2. Pilih runner, preset, timezone, dan durasi (default 342 menit).
3. Tunggu step *Setup akses Tailscale* selesai; IP muncul di log, Summary run, notifikasi, dan branch `status`.
4. Connect dari perangkat yang login ke tailnet yang sama:
   - **Windows:** `mstsc` → Computer = `100.x.x.x`, user = `fread` (atau yang kamu pilih), password = `RDP_PASSWORD`. Cara tercepat: unduh artifact **`rdpfread-connection`** dari run itu, klik dua kali file `rdpfread.rdp`-nya.
   - **Android/iOS:** Windows App / Microsoft Remote Desktop → tambah PC `100.x.x.x` dengan user yang sama.
   - **Terminal (bila `akses_ssh=ya`):** `ssh fread@100.x.x.x`, password sama — shell PowerShell.
5. Simpan semua file kerjamu di **`C:\RDPData`** — hanya folder itu (+ Desktop & Documents user) yang persisten antar sesi.

## 5. Berhenti & perpanjangan

- **Auto-stop:** 3 menit sebelum `expires_at`. Batas keras job GitHub: 360 menit.
- **Perpanjangan otomatis** (`perpanjang_otomatis=ya`): sesi berikutnya di-dispatch ±20 menit sebelum habis dan memulihkan state.
- **Berhenti total:** Cancel run yang sedang berjalan **dan** semua run yang masih antre di tab Actions.
- **Catatan IP/hostname:** nama node Tailscale memakai pola `rdpfread-<nomor run>` agar konsisten antar sesi. Karena nomor run selalu naik, nama/IP node bisa berbeda antar sesi bila auth key bersifat ephemeral — IP terbaru selalu ada di branch `status`.

## 6. Struktur repository

```
.github/workflows/
  rdp.yml            # sesi RDP utama
  validate.yml       # validasi YAML + parse PowerShell + PSScriptAnalyzer
scripts/
  lib-common.ps1       # logger, status JSON, hostname, helper Tailscale
  cleanup-actions.ps1  # hapus run lama
  setup-rdp.ps1        # user/password RDP, NLA, timezone, folder kerja
  restore-state.ps1    # pulihkan state (tar.gz, terenkripsi opsional)
  setup-akses.ps1      # Tailscale resmi + firewall RDP khusus tailnet
  setup-windows.ps1    # tweak Windows: power, Explorer, long paths, shortcut
  setup-ssh.ps1        # OpenSSH Server Windows opsional (hanya tailnet)
  make-rdp-file.ps1    # file koneksi .rdp siap klik (artifact)
  setup-preset.ps1     # preset software (winget/choco)
  publish-status.ps1   # branch status: rdp-status.json + STATUS.md
  notify.ps1           # Telegram / Discord / webhook
  keepalive.ps1        # heartbeat resource, checkpoint, handover, auto-stop
  persist-state.ps1    # simpan state (staging + manifest, enkripsi opsional)
  finalize.ps1         # logout Tailscale + notifikasi berhenti
config/
  backup-paths.txt   # folder yang ikut disimpan ke state
setup-wizard.ps1     # wizard setup lokal (Windows) via gh CLI
setup-wizard.sh      # wizard setup lokal (Linux/Termux) via gh CLI
```

## 7. Keamanan & batasan

- RDP hanya dari tailnet (`100.64.0.0/10`) dengan NLA; runner tidak punya inbound publik untuk RDP.
- Password & auth key hanya hidup sebagai Secrets — tidak ditulis ke log, status, atau arsip state.
- Installer Tailscale diambil dari sumber resmi `pkgs.tailscale.com`; preset memakai winget/Chocolatey bawaan image runner. Tidak ada script eksternal acak yang diunduh/dijalankan.
- Runner GitHub-hosted bersifat ephemeral dan dibatasi 6 jam per job; tidak ada jaminan bebas suspend dari GitHub — gunakan untuk pekerjaan yang wajar (dev, belajar, testing), bukan mining / proxy publik / layanan produksi.
- Batas artifact mengikuti plan GitHub (Free 500 MB); arsip state di atas ±1,9 GB dilewati untuk Release.
- Gunakan auth key Tailscale yang bisa dicabut (reusable + ephemeral lebih aman), dan cabut bila perangkat hilang.
