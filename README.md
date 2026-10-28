# RDPfread — Sesi Remote 6 Jam Pro (Windows / Linux / macOS)

[![Sesi RDPfread](https://github.com/qioceky/RDPfread/actions/workflows/rdp.yml/badge.svg)](https://github.com/qioceky/RDPfread/actions/workflows/rdp.yml)
[![Validate](https://github.com/qioceky/RDPfread/actions/workflows/validate.yml/badge.svg)](https://github.com/qioceky/RDPfread/actions/workflows/validate.yml)
![Windows](https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black)
![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white)

**Versi 1.7.4** — daftar perubahan lengkap ada di [CHANGELOG.md](CHANGELOG.md), panduan langkah demi langkah di [PANDUAN.md](PANDUAN.md).

RDPfread mengubah satu runner **GitHub Actions** menjadi komputer remote pribadimu selama ±6 jam: pilih OS saat Run, sambungkan lewat **Tailscale privat**, kerja seperti di PC sendiri, lalu semua pekerjaanmu **tersimpan dan ikut pindah ke sesi berikutnya** secara otomatis. Satu workflow, tiga OS, tanpa server yang harus kamu rawat.

> ⚠️ **Keamanan state:** state sesi disimpan ke Release & artifact repo agar pekerjaanmu tetap ada antar sesi. Gunakan **repository PRIVATE**, ATAU repository publik **hanya bila** secret `STATE_ENCRYPTION_KEY` diisi sehingga arsip state selalu terenkripsi AES-256 sebelum diunggah — tanpa enkripsi, state di repo publik bisa diunduh siapa pun. Perlu diingat repo publik juga membuka log Actions & branch status (IP/hostname sesi terlihat); akses remote-nya sendiri tetap hanya bisa dari tailnet + password.

---

## Daftar isi

- [Pilih OS-mu](#pilih-os-mu)
- [Fitur unggulan](#fitur-unggulan)
- [Cara kerja singkat](#1-cara-kerja-singkat)
- [Mulai cepat](#mulai-cepat)
- [Prasyarat](#2-prasyarat)
- [Secrets](#3-secrets)
- [Menjalankan sesi](#4-menjalankan-sesi)
- [Berhenti dan perpanjangan](#5-berhenti-dan-perpanjangan)
- [Struktur repository](#6-struktur-repository)
- [Keamanan dan batasan](#7-keamanan-dan-batasan)
- [Status live](#status-live)
- [Rencana berikut](#rencana-berikut)
- [Lapor masalah](#lapor-masalah)

## 🖥️ Pilih OS-mu

Satu input `runner` saat Run workflow menentukan OS sesi. Estafet otomatis meneruskan pilihan ini, jadi sesi berikutnya tetap di OS yang sama sampai kamu dispatch manual dengan OS lain.

| OS | Runner | Akses | Port | State (asset terpisah, sama-sama terenkripsi) |
|---|---|---|---|---|
| **Windows Server** | `windows-2022`, `windows-2025`, `windows-latest` | RDP (+ SSH opsional) | 3389 (RDP), 22 (SSH bila `akses_ssh=ya`) | `rdpfread-state.tar.gz[.enc]` |
| **Linux** 🧪 | `ubuntu-24.04`, `ubuntu-22.04`, `ubuntu-latest` | RDP (desktop 🧪) / SSH | 3389 (RDP), 22 (SSH) | `rdpfread-state-linux.tar.gz[.enc]` |
| **macOS** ⚠️ | `macos-14`, `macos-15`, `macos-latest` | VNC + SSH (⚠️ display VNC belum jalan — uji 27 Okt 2026) | 5900 (VNC), 22 (SSH) | `rdpfread-state-macos.tar.gz[.enc]` |

Mode Linux diatur input `linux_mode`: `desktop` (XFCE4 + XRDP + SSH), `desktop-ringan` (desktop + Firefox + LibreOffice), `desktop-dev` (desktop + VS Code; Git/Node/Python sudah bawaan image), atau `polos` (SSH saja, paling ringan).

🧪 **Desktop Linux berstatus EKSPERIMENTAL (27 Okt 2026):** sesi desktop jalan (XFCE tampil, connect XRDP lolos), tapi delay terasa berat di link jarak jauh meski sudah dioptimasi (compositing nonaktif + warna 16-bit). Penyebab tersisa diduga latensi link + pipeline XRDP. Rekomendasi stabil tetap Windows. Mode `polos` (SSH saja) tidak terpengaruh.

Catatan macOS: macOS tidak punya RDP bawaan, jadi yang dipakai adalah **VNC (Screen Sharing)** — dari HP butuh aplikasi VNC (mis. RealVNC Viewer/AVNC), bukan klien RDP. Password VNC dibatasi **8 karakter** oleh protokol VNC legacy: bila `RDP_PASSWORD`-mu lebih panjang, login VNC memakai 8 karakter pertamanya (SSH memakai password penuh). **Hasil uji lapangan 27 Okt 2026: koneksi + autentikasi VNC lolos dan kursor tampil, tapi display hitam di AVNC maupun RealVNC meski sudah restart agen, allow-all-users, dan reset WindowServer — dukungan VNC macOS dinyatakan BELUM support sampai display terpecahkan; SSH macOS jalan normal.**

---

## ✨ Fitur unggulan

| Fitur | Keterangan |
|---|---|
| 🎛️ **Preset software (Windows)** | Pilih saat Run: `minimal` / `ringan` (Firefox + LibreOffice + SumatraPDF + 7-Zip + Notepad++ + PowerShell 7, buat harian/kantor) / `web` (Node LTS + Python) / `dev` (web + Git + VS Code) / `full` (dev + PowerShell 7 + Windows Terminal + Chrome) / `desktop` (full + PowerToys + VLC + LibreOffice + OBS Studio) / `game` (lihat di bawah) / `optimize` (nol software + debloat berat, sesi seringan mungkin) |
| 🎮 **Preset game (Windows)** | PrismLauncher + JDK 21/JRE 8 + **Mesa3D** (OpenGL software untuk VM tanpa GPU) + launcher Minecraft resmi + `options.txt` ramah RDP + 6 game gratis ringan: **Mindustry, Luanti, GZDoom+Freedoom, OpenTTD, SuperTuxKart, Battle for Wesnoth** (shortcut di Desktop); untuk GTA SA milikmu sendiri: ASI Loader + SilentPatch + dgVoodoo2 dipasang otomatis (game-nya tidak disediakan; installer SA-MP taruh manual di `C:\RDPData\Games-Setup`). World Minecraft & instance Prism ikut tersimpan di state; folder GTA SA tidak (batas Release 2 GB) |
| 🧹 **Debloat bertingkat (Windows)** | Input `debloat`: `berat` (AppX bloatware dibuang, Defender RT mati, Ultimate Performance) atau `full` (tambah: Store & AppX lapis-2 dibuang, fitur opsional dicabut, Defender dinonaktifkan total, DISM cleanup) — untuk preset apa pun; preset `optimize` otomatis minimal `berat` |
| 🎞️ **Target 120 FPS (Windows)** | Input `fps=120` menaikkan plafon frame RDP Windows (`DWMFRAMEINTERVAL=8` ms); Minecraft memang sudah 120 FPS. Linux/macOS tidak terpengaruh |
| 🪟 **Tweak khas Windows** | Power plan High Performance (tanpa sleep), Explorer menampilkan ekstensi & file tersembunyi, long paths aktif, clipboard/drive/audio redirection RDP, policy installer `.msi` dilonggarkan (image runner memblokirnya secara default), shortcut `RDPData` di desktop |
| 🖱️ **File `.rdp` siap klik (Windows)** | Artifact `rdpfread-connection` berisi `rdpfread.rdp` (IP + user + fullscreen) — unduh, klik dua kali, masukkan password, langsung terhubung |
| 🔑 **SSH (Windows opsional, Linux/macOS bawaan)** | Windows: input `akses_ssh=ya` memasang OpenSSH Server bawaan (`ssh fread@100.x.x.x`, shell PowerShell). Linux & macOS: SSH selalu aktif di semua mode |
| 🔐 **Password dari Secret** | Password user remote dibaca dari secret `RDP_PASSWORD` — tidak ada password tertulis di file repo |
| 🔒 **Hanya dari tailnet** | Rule firewall bawaan yang terbuka dimatikan; RDP (3389) hanya menerima dari `100.64.0.0/10` (jaringan Tailscale), NLA aktif (Windows) |
| 💾 **State persisten** | Windows: `C:\RDPData` + folder profil user (Desktop, Documents, Downloads, Pictures, Videos, Music) + profil browser. Linux/macOS: home user (minus cache) + identitas Tailscale. Disimpan sebagai checkpoint cerdas (dilewati bila tidak ada perubahan) + di akhir sesi ke Release `rdpfread-state-latest`; daftar path Windows bisa diubah di `config/backup-paths.txt` |
| 🔑 **State terenkripsi (opsional)** | Secret `STATE_ENCRYPTION_KEY` — arsip state dienkripsi AES-256 (openssl) sebelum upload |
| 🌐 **Login browser berlanjut (Windows)** | Master key DPAPI user ikut disimpan & dipulihkan (translasi SID), jadi cookie & password tersimpan Chrome/Edge tetap terbuka di sesi berikutnya — tanpa login ulang |
| 🧹 **Optimasi storage (Windows, input `optimasi`)** | Bebaskan disk runner (toolcache/cache) + matikan service latar non-esensial (telemetri, indexing, Xbox) agar sesi lebih ringan |
| 🔔 **Notifikasi** | Telegram / Discord / webhook umum: saat sesi siap, mau berakhir, handover, dan berhenti |
| 🌏 **Timezone bisa dipilih** | Input workflow (default `Asia/Jakarta`), dipetakan otomatis ke timezone OS sesi |
| 📊 **Dashboard status** | Branch `status` berisi `rdp-status.json` (schema v2) **dan** `STATUS.md` yang enak dibaca |
| 🧙 **Setup wizard** | `setup-wizard.ps1` (Windows) / `setup-wizard.sh` (Linux/Termux) — siapkan repo + secrets + run pertama via `gh` |
| 📈 **Heartbeat resource (Windows)** | Log keepalive menampilkan CPU, RAM, dan disk tiap 5 menit |
| 🔁 **Auto-renew (estafet)** | Sesi berikutnya di-dispatch ±20 menit sebelum habis; state ikut pindah |

---

## 1. Cara kerja singkat

Setiap Run workflow, GitHub menyiapkan satu VM sementara (ephemeral). Alurnya sama untuk semua OS, hanya langkah setup yang berbeda per OS:

1. **Checkout + bersih-bersih** — repo di-checkout, run lama dihapus (sisakan 10).
2. **User + password** — user remote dibuat dengan password dari secret `RDP_PASSWORD`; timezone sesi diterapkan.
3. **Pulihkan state** — state sesi sebelumnya diunduh dari Release `rdpfread-state-latest` (asset sesuai OS) dan dipulihkan; bila belum ada, sesi mulai bersih.
4. **Tailscale** — Tailscale resmi dipasang dan disambungkan ke tailnet-mu (nama node berpola `rdpfread-<nomor run>`); akses remote dibatasi hanya dari tailnet.
5. **Setup per OS:**
   - **Windows:** tweak khas Windows → optimasi storage + debloat ringan (bila `optimasi=ya`) → OpenSSH Server (bila `akses_ssh=ya`) → preset software (winget, fallback Chocolatey) → paket game (bila preset `game`) → debloat berat/full (bila diminta).
   - **Linux:** SSH diaktifkan di semua mode → bila mode desktop, XFCE4 + XRDP dipasang (+ Firefox/LibreOffice untuk `desktop-ringan`, + VS Code untuk `desktop-dev`).
   - **macOS:** Remote Login (SSH) diaktifkan → Screen Sharing (VNC) diaktifkan via kickstart untuk user sesi.
6. **Publish status + notifikasi** — dashboard ditulis ke branch `status`, notifikasi "siap" dikirim, dan (Windows) file koneksi `.rdp` di-upload sebagai artifact.
7. **Keepalive** — sesi dijaga: detak tiap menit, publish status tiap 5 menit, checkpoint state tiap 15 menit, handover (dispatch sesi berikut + jeda acak 10–30 detik) 20 menit sebelum habis, auto-stop 3 menit sebelum batas 6 jam GitHub.
8. **Finalize** — state final disimpan, status dimatikan, notifikasi berhenti dikirim, Tailscale logout.

## 🚀 Mulai cepat

1. Isi secrets wajib (`RDP_PASSWORD`, `TAILSCALE_AUTH_KEY`) — tambah `STATE_ENCRYPTION_KEY` bila repo publik.
2. Tab **Actions → RDPfread — Sesi 6 Jam Pro (Windows/Linux/macOS) → Run workflow**, pilih OS, lalu **Run workflow**.
3. Tunggu notifikasi "siap", lalu connect dari perangkat yang login ke tailnet yang sama — IP terbaru selalu ada di [branch `status`](#status-live).

## 2. Prasyarat

- Repo ini (publik boleh, asal `STATE_ENCRYPTION_KEY` terisi — lihat kotak keamanan di atas; privat juga boleh).
- Akun Tailscale + **auth key** (`tskey-auth-...`) dari <https://login.tailscale.com/admin/settings/keys>.
- Aplikasi Tailscale terpasang & login di HP/PC kamu, di tailnet yang sama.
- Aplikasi klien sesuai OS sesi: **RDP** (Windows bawaan `mstsc`, atau Windows App / Microsoft Remote Desktop di Android/iOS) untuk Windows & Linux desktop; **VNC viewer** (mis. RealVNC Viewer/AVNC) untuk macOS; **SSH** (Termux/dll.) untuk mode terminal.
- GitHub Actions aktif di repo.

## 3. Secrets

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Wajib? | Isi |
|---|---|---|
| `RDP_PASSWORD` | ✅ | Password user remote. Min. 8 karakter, kuat & unik. (Ingat: login VNC macOS hanya memakai 8 karakter pertamanya.) |
| `TAILSCALE_AUTH_KEY` | ✅ | Auth key Tailscale (`tskey-auth-...`). |
| `STATE_ENCRYPTION_KEY` | — | Passphrase enkripsi arsip state (AES-256). **Jangan hilang** — tanpa ini state terenkripsi tidak bisa dipulihkan. Wajib diisi bila repo publik. |
| `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | — | Notifikasi Telegram. |
| `DISCORD_WEBHOOK_URL` | — | Notifikasi Discord. |
| `NOTIFY_WEBHOOK_URL` | — | Webhook JSON umum (`{"text": "...", "event": "..."}`). |
| `CLEANUP_TOKEN` | — | PAT scope `repo`/`actions` untuk menghapus run lama (fallback `GITHUB_TOKEN`). |

> Cara cepat: jalankan `setup-wizard.ps1` di Windows atau `bash setup-wizard.sh` di Linux/Termux (butuh `gh` yang sudah login).

## 4. Menjalankan sesi

1. Tab **Actions → RDPfread — Sesi 6 Jam Pro (Windows/Linux/macOS) → Run workflow**.
2. Pilih runner (OS), preset/mode, timezone, dan durasi (default 342 menit).
3. Tunggu step setup selesai; IP muncul di log, Summary run, notifikasi, dan branch `status`.
4. Connect dari perangkat yang login ke tailnet yang sama:
   - **Windows:** `mstsc` → Computer = `100.x.x.x`, user = `fread` (atau yang kamu pilih), password = `RDP_PASSWORD`. Cara tercepat: unduh artifact **`rdpfread-connection`** dari run itu, klik dua kali file `rdpfread.rdp`-nya.
   - **Android/iOS (Windows/Linux desktop):** Windows App / Microsoft Remote Desktop → tambah PC `100.x.x.x` dengan user yang sama.
   - **macOS:** aplikasi VNC → host `100.x.x.x:5900`, user yang sama, password = 8 karakter pertama `RDP_PASSWORD`.
   - **Terminal:** `ssh fread@100.x.x.x`, password sama (Linux/macOS selalu aktif; Windows bila `akses_ssh=ya` — shell PowerShell di Windows).
5. Simpan file kerjamu di tempat yang persisten: **`C:\RDPData`** (Windows), **home user** (Linux/macOS) — hanya lokasi itu (+ folder profil user Windows) yang ikut tersimpan antar sesi.

## 5. Berhenti dan perpanjangan

- **Auto-stop:** 3 menit sebelum `expires_at`. Batas keras job GitHub: 360 menit.
- **Perpanjangan otomatis** (`perpanjang_otomatis=ya`): sesi berikutnya di-dispatch ±20 menit sebelum habis dan memulihkan state (OS & pengaturan ikut diteruskan).
- **Berhenti total:** Cancel run yang sedang berjalan **dan** semua run yang masih antre di tab Actions.
- **Catatan IP/hostname:** nama node Tailscale memakai pola `rdpfread-<nomor run>` agar konsisten antar sesi. Karena nomor run selalu naik, nama/IP node bisa berbeda antar sesi bila auth key bersifat ephemeral — IP terbaru selalu ada di branch `status`.

## 6. Struktur repository

```
.github/workflows/
  rdp.yml            # sesi utama (Windows/Linux/macOS)
  validate.yml       # validasi YAML + parse PowerShell + PSScriptAnalyzer + bash -n/shellcheck
scripts/
  lib-common.ps1       # logger, status JSON, hostname, helper Tailscale (Windows)
  cleanup-actions.ps1  # hapus run lama (Windows)
  setup-rdp.ps1        # user/password RDP, NLA, timezone, folder kerja (Windows)
  restore-state.ps1    # pulihkan state Windows (tar.gz, terenkripsi opsional)
  setup-akses.ps1      # Tailscale resmi + firewall RDP khusus tailnet (Windows)
  setup-windows.ps1    # tweak Windows: power, Explorer, long paths, shortcut
  optimize-storage.ps1 # storage boost + debloat ringan, input optimasi (Windows)
  setup-ssh.ps1        # OpenSSH Server Windows opsional (hanya tailnet)
  make-rdp-file.ps1    # file koneksi .rdp siap klik, artifact (Windows)
  setup-preset.ps1     # preset software Windows (winget/choco)
  setup-games.ps1      # paket game preset "game" (Mesa3D, Minecraft, SA-MP/GTA SA, 6 game gratis)
  merge-profile.ps1    # gabung item profil dari staging ke profil asli saat logon pertama
  debloat-windows.ps1  # debloat berat (AppX, Defender, service, visual)
  debloat-full.ps1     # debloat tingkat full (AppX lapis-2, fitur opsional, Defender total, DISM)
  setup-linux.sh       # sesi Linux (desktop/desktop-ringan/desktop-dev/polos): setup, keepalive, finalize
  setup-macos.sh       # sesi macOS (VNC + SSH): setup, keepalive, finalize
  publish-status.ps1   # branch status: rdp-status.json + STATUS.md (Windows)
  notify.ps1           # Telegram / Discord / webhook (Windows)
  keepalive.ps1        # heartbeat resource, checkpoint, handover, auto-stop (Windows)
  persist-state.ps1    # simpan state Windows (staging + manifest, enkripsi opsional)
  finalize.ps1         # logout Tailscale + notifikasi berhenti (Windows)
config/
  backup-paths.txt   # folder Windows yang ikut disimpan ke state
setup-wizard.ps1     # wizard setup lokal (Windows) via gh CLI
setup-wizard.sh      # wizard setup lokal (Linux/Termux) via gh CLI
```

## 7. Keamanan dan batasan

- Akses remote hanya dari tailnet (`100.64.0.0/10`) dengan NLA (Windows); runner tidak punya inbound publik untuk RDP/VNC.
- Password & auth key hanya hidup sebagai Secrets — tidak ditulis ke log, status, atau arsip state.
- Installer Tailscale diambil dari sumber resmi `pkgs.tailscale.com`; preset memakai winget/Chocolatey bawaan image runner (Windows) atau repo resmi (Firefox Mozilla, VS Code). Tidak ada script eksternal acak yang diunduh/dijalankan.
- Runner GitHub-hosted bersifat ephemeral dan dibatasi 6 jam per job; tidak ada jaminan bebas suspend dari GitHub — gunakan untuk pekerjaan yang wajar (dev, belajar, testing), bukan mining / proxy publik / layanan produksi.
- Batas artifact mengikuti plan GitHub (Free 500 MB); arsip state di atas ±1,9 GB dilewati untuk Release.
- Gunakan auth key Tailscale yang bisa dicabut (reusable + ephemeral lebih aman), dan cabut bila perangkat hilang.
- **Watermark "Test Mode" (Windows):** image GitHub mengaktifkan test signing, jadi pojok kanan bawah menampilkan "Test Mode". Menghilangkannya butuh `bcdedit testsigning off` + reboot — reboot mematikan sesi, jadi watermark ini sengaja dibiarkan (kosmetik, tanpa efek fungsi).
- **Latensi:** runner GitHub umumnya di AS — dari Indonesia, latensi RDP ±200–250 ms adalah normal; koneksi Tailscale bisa direct (peer-to-peer) atau lewat relay DERP.
- **macOS VNC — BELUM SUPPORT (27 Okt 2026):** uji lapangan pertama membuktikan display hitam di semua klien (AVNC, RealVNC) meski koneksi + autentikasi lolos, setelah restart agen, allow-all-users, dan reset WindowServer. Penyebab display belum teridentifikasi; SSH macOS jalan normal. Dukungan VNC macOS ditahan sampai display terpecahkan.

## 📡 Status live

Sesi yang sedang berjalan (bila ada) bisa dipantau tanpa membuka log Actions:

- Dashboard ringkas: [STATUS.md di branch `status`](https://github.com/qioceky/RDPfread/blob/status/STATUS.md)
- Data mentah: [rdp-status.json di branch `status`](https://github.com/qioceky/RDPfread/blob/status/rdp-status.json) — IP/DNS Tailscale, OS, preset/mode, waktu berakhir, dan nomor run terbaru selalu ada di sini.

## 🗺️ Rencana berikut

- Perbaiki display VNC macOS (uji 27 Okt: connect OK, display hitam di semua klien; bug persist state macOS diperbaiki di v1.7.1).
- Desktop Linux berstatus eksperimental (diuji 27 Okt: connect + desktop jalan, tapi delay berat meski sudah dioptimasi v1.7.3+v1.7.4) — perbaikan lag XRDP masih terbuka; `desktop-dev` belum diuji lapangan.
- Opsi runner/mode baru di Panel aplikasi RDPfread XD (dispatch 1-tap).
- Tes ulang preset game pasca-hardening hive v1.5.2 (tes ini menggantikan sesi yang sedang jalan).

## 🐛 Lapor masalah

Buka [Issue baru](https://github.com/qioceky/RDPfread/issues) dengan info: nomor run, OS/runner yang dipilih, langkah yang gagal, dan potongan log step terkait. Jangan pernah menempel password, auth key, atau kunci enkripsi state di Issue — ketiganya hanya hidup sebagai Secrets.
