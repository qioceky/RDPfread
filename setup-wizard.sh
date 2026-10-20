#!/usr/bin/env bash
# setup-wizard.sh - wizard lokal RDPfread untuk Linux/macOS/Termux.
# Jalankan (butuh GitHub CLI `gh` yang sudah login):
#   bash setup-wizard.sh [--run]
# Menyiapkan repo (default: qioceky/RDPfread-style, PRIVATE) + secrets wajib
# RDP_PASSWORD & TAILSCALE_AUTH_KEY lewat input tersembunyi - tidak dicetak/disimpan.
set -euo pipefail

say() { printf '\n== %s ==\n' "$*"; }
command -v gh >/dev/null 2>&1 || { echo 'ERROR: GitHub CLI (gh) belum terpasang. Install: https://cli.github.com'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'ERROR: gh belum login. Jalankan: gh auth login'; exit 1; }
GH_USER="$(gh api user --jq .login)"
echo "Login GitHub sebagai: $GH_USER"

say 'Repository'
printf 'Nama repo (default: RDPfread): '; read -r REPO_NAME; REPO_NAME="${REPO_NAME:-RDPfread}"
FULL="$GH_USER/$REPO_NAME"

if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "Repo $FULL sudah ada - memakai repo itu."
  echo 'PENTING: pastikan visibility PRIVATE (Settings > General > Danger Zone), karena state sesi disimpan di Release repo.'
else
  printf 'Buat repo PRIVATE baru "%s" dari folder ini dan push? [y/N] ' "$FULL"; read -r ans
  case "$ans" in y|Y)
    git init -q 2>/dev/null || true
    git add -A 2>/dev/null || true
    git commit -qm 'RDPfread v1.0' 2>/dev/null || true
    gh repo create "$FULL" --private --source=. --push
    ;;
  *) echo 'Dibatalkan. Buat repo-nya dulu, lalu jalankan wizard lagi.'; exit 0;;
  esac
fi

set_secret() { # $1=nama - baca tersembunyi bila tty, kirim ke gh secret set
  local name="$1" val=""
  printf 'Masukkan %s (kosong = lewati): ' "$name"
  if [ -t 0 ]; then read -rs val; echo; else read -r val; fi
  [ -z "$val" ] && { echo "  -> $name dilewati."; return; }
  printf '%s' "$val" | gh secret set "$name" --repo "$FULL" >/dev/null
  echo "  -> $name tersimpan sebagai secret."
}

say 'Secrets WAJIB'
set_secret RDP_PASSWORD
set_secret TAILSCALE_AUTH_KEY

say 'Secrets OPSIONAL (kosongkan bila tidak pakai)'
set_secret STATE_ENCRYPTION_KEY
set_secret TELEGRAM_BOT_TOKEN
set_secret TELEGRAM_CHAT_ID
set_secret DISCORD_WEBHOOK_URL

say 'Selesai'
echo "Repo     : https://github.com/$FULL"
echo "Jalankan : Actions -> 'RDPfread - RDP Windows 6 Jam Pro' -> Run workflow"
echo "Atau     : gh workflow run rdp.yml --repo $FULL"

RUN_IT=0; [ "${1:-}" = '--run' ] && RUN_IT=1
if [ "$RUN_IT" -eq 0 ]; then printf 'Langsung Run workflow sekarang? [y/N] '; read -r ans; case "$ans" in y|Y) RUN_IT=1;; esac; fi
if [ "$RUN_IT" -eq 1 ]; then
  gh workflow run rdp.yml --repo "$FULL"
  echo "Workflow dijalankan. Pantau: gh run watch --repo $FULL / https://github.com/$FULL/actions"
fi
