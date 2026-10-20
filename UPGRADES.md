# RDPfread v1.0 — Daftar Peningkatan

Perapihan total dari versi awal RDPfread (satu file workflow, dibuat 2026-10-10) menjadi project modular setara QVPS:

## Struktur & workflow
1. **Modular** — dari 1 file `main.yml` menjadi workflow `rdp.yml` + 14 script PowerShell di `scripts/` + `config/`, masing-masing satu tugas dan bisa diuji terpisah.
2. **Input workflow lengkap** — durasi, hostname, username, pilihan runner (windows-2022/2025/latest), preset, timezone, dan auto-renew bisa dipilih saat Run, bukan edit file.
3. **Validate CI** — `validate.yml` memeriksa YAML (Ubuntu) dan sintaks semua `.ps1` dengan parser PowerShell + PSScriptAnalyzer (Windows).
4. **Actions v5 & concurrency** — `actions/checkout@v5`, `upload-artifact@v5`, dan concurrency group agar hanya 1 sesi aktif dalam satu waktu.
5. **Cleanup otomatis** — run lama dihapus, disisakan 10 terakhir.

## Keamanan
6. **Tanpa password hardcoded** — password user RDP 100% dari secret `RDP_PASSWORD` (min. 8 karakter, divalidasi di awal sesi).
7. **Tanpa unduhan script eksternal acak** — satu-satunya unduhan adalah installer resmi Tailscale dari `pkgs.tailscale.com`; software preset dari winget/Chocolatey bawaan image.
8. **RDP khusus tailnet** — rule firewall bawaan yang terbuka untuk semua alamat dimatikan, diganti rule khusus `100.64.0.0/10`; NLA tetap wajib.
9. **Rekomendasi repo Private** — ditegaskan di README, PANDUAN, dan kedua wizard karena state disimpan di Release repo.

## Fitur baru (menyusul QVPS)
10. **State persisten** — `C:\RDPData` + Desktop & Documents user, checkpoint 15 menit, manifest pemetaan path, enkripsi AES-256 opsional.
11. **Dashboard status** — branch `status` dengan `rdp-status.json` (schema v2) + `STATUS.md`.
12. **Notifikasi** — Telegram / Discord / webhook untuk event ready, expiring, handover, stopped.
13. **Preset software** — minimal / web / dev / full via winget (fallback choco), versi tools dicatat ke status.
14. **Heartbeat resource** — CPU/RAM/disk + status Tailscale tiap 5 menit, auto-reconnect Tailscale, auto-restart service RDP.
15. **Auto-renew / handover** — sesi berikutnya di-dispatch 20 menit sebelum habis dengan input yang sama.
16. **Setup wizard ganda** — `setup-wizard.ps1` untuk Windows dan `setup-wizard.sh` untuk Linux/Termux.
17. **Dokumentasi lengkap** — README baru + PANDUAN langkah demi langkah + file ini.

## Fitur khas Windows (pembeda dari QVPS)
18. **Preset `desktop`** — pengalaman desktop penuh: PowerToys, Windows Terminal, PowerShell 7, VLC, LibreOffice, OBS Studio (di samping isi preset `full`).
19. **Tweak Windows otomatis** — power plan High Performance tanpa sleep, Explorer menampilkan ekstensi & file tersembunyi (hive Default User), long paths, redirection clipboard/drive/audio RDP, shortcut folder persisten di desktop.
20. **File koneksi `.rdp` siap klik** — artifact `rdpfread-connection` per run; tanpa password di dalamnya (mstsc/Windows App yang menanyakan).
21. **OpenSSH Server Windows opsional** — input `akses_ssh=ya`: jalur terminal PowerShell ke Windows dari Termux/HP, akun & password sama dengan RDP, firewall tetap khusus tailnet dan rule bawaan yang terbuka dimatikan.

## Perbaikan v1.0.1 (dari temuan Run pertama, 2026-10-20)
22. **Fix keepalive mati 0 detik** — `ConvertFrom-Json` PowerShell 7 mengubah string tanggal ISO jadi DateTime lokal; setelah timezone VM diganti, jam berakhir UTC bergeser -7 jam sehingga sesi dianggap sudah habis. Sekarang semua tanggal status dibaca sebagai UTC murni (`Get-StatusUtc`) + pengaman hitung-ulang dari `started_at`, dan format tampilan tanggal dikembalikan ke ISO UTC. Teruji di zona Jakarta/UTC/New York.
23. **Fix publish status & cleanup ke-skip** — workflow kini menyetel `GITHUB_TOKEN` (sebelumnya hanya `GH_TOKEN`) yang dibaca script publish-status, cleanup, dan dispatch handover.
