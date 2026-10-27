#!/usr/bin/env bash
# setup-macos.sh - sesi macOS RDPfread (v1.7.0), dipanggil workflow rdp.yml
# bila runner macOS. Tiga fase (satu step workflow per fase), pola yang
# sama dengan setup-linux.sh:
#   --setup     : user + password (secret RDP_PASSWORD), timezone, restore
#                 state, Tailscale, lalu Screen Sharing (VNC :5900) +
#                 Remote Login (SSH :22). Akhiri dengan publish status +
#                 notifikasi "ready".
#   --keepalive : detak 1 menit (publish 5 mnt, checkpoint state 15 mnt,
#                 reconnect Tailscale otomatis, dispatch estafet 20 mnt
#                 sebelum habis + jeda acak, auto-stop 3 mnt sebelum habis).
#   --finalize  : simpan state final, status off, notifikasi, logout
#                 Tailscale.
# CATATAN PENTING (jujur, bukan janji):
# - macOS TIDAK punya RDP bawaan: yang dipakai adalah VNC (Screen
#   Sharing). Dari HP butuh aplikasi VNC (mis. RealVNC Viewer/AVNC),
#   bukan klien RDP biasa.
# - Password VNC legacy macOS dibatasi 8 karakter (batas protokol VNC):
#   bila RDP_PASSWORD lebih panjang, login VNC memakai 8 karakter
#   pertamanya. SSH memakai password penuh seperti biasa.
# - Butuh uji lapangan: aktivasi Screen Sharing + login VNC dari HP
#   belum pernah dites (runner macOS tidak bisa dites dari VM ini).
# State macOS memakai asset terpisah di Release yang sama dengan
# Windows/Linux: rdpfread-state-macos.tar.gz[.enc] - isi: home user
# (minus cache) + state Tailscale BILA ditemukan (best effort: lokasi
# state tailscaled di macOS bervariasi menurut cara instalasi; path
# sumber disimpan di dalam arsip supaya restore menaruhnya kembali ke
# tempat yang sama). Enkripsi AES-256 sama seperti state lain bila
# STATE_ENCRYPTION_KEY terisi.
# Kompatibilitas: ditulis untuk bash 3.2 macOS (tanpa fitur bash 4,
# tanpa flag GNU: stat pakai -f %z, date pakai -r, cp pakai -pR).
set -u

TAG="RDPfread:macos"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="$WS/out"
SESS="$OUT/macos-session.env"
STATUS_JSON="$OUT/rdp-status.json"
MODE="macos-vnc"
REL_TAG="rdpfread-state-latest"
ASSET_BASE="rdpfread-state-macos.tar.gz"

log() { echo "[$(date -u +%H:%M:%S) UTC][$TAG] $*"; }
warn() { log "WARN: $*"; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_at() {
  if [ "$(uname)" = "Darwin" ]; then date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ;
  else date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; fi
}
file_bytes() {
  if [ "$(uname)" = "Darwin" ]; then stat -f %z "$1" 2>/dev/null || echo 0;
  else stat -c %s "$1" 2>/dev/null || echo 0; fi
}

ts_hostname() {
  local base run
  base="$(printf '%s' "${RDP_HOST:-rdpfread}" | tr -cd 'a-zA-Z0-9-' | tr 'A-Z' 'a-z' | sed 's/^-*//;s/-*$//')"
  [ -z "$base" ] && base="rdpfread"
  base="$(printf '%s' "$base" | cut -c1-30 | sed 's/-*$//')"
  run="${GITHUB_RUN_NUMBER:-local}"
  printf '%s-%s' "$base" "$run"
}

# ---------- status JSON + publish ke branch status ----------
write_status() {
  local active="$1" ip="${2:-}" dns="${3:-}"
  mkdir -p "$OUT"
  local started_s="" expires_s=""
  if [ -f "$SESS" ]; then
    # shellcheck disable=SC1090
    . "$SESS"
    started_s="$(iso_at "${STARTED_EPOCH:-0}")"
    expires_s="$(iso_at "${EXPIRES_EPOCH:-0}")"
  fi
  python3 - "$STATUS_JSON" "$active" "$ip" "$dns" "$started_s" "$expires_s" <<'PYEOF'
import json, os, sys, datetime
path, active, ip, dns, started, expires = sys.argv[1:7]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data.update({
    "active": active == "true",
    "mode": os.environ.get("RDPFREAD_MODE", ""),
    "os": os.environ.get("RUNNER_IMAGE", ""),
    "hostname": os.environ.get("RDPFREAD_TSHOST", ""),
    "tailscale_ip": ip,
    "dns_name": dns,
    "rdp_user": os.environ.get("RDP_USER", ""),
    "preset": "macos",
    "macos_mode": "vnc",
    "started_at": started,
    "expires_at": expires,
    "duration_menit": int(os.environ.get("DUR", "342") or 342),
    "run_number": os.environ.get("GITHUB_RUN_NUMBER", ""),
    "run_id": os.environ.get("GITHUB_RUN_ID", ""),
    "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
})
json.dump(data, open(path, "w"), indent=2)
PYEOF
  {
    echo "# Status RDPfread"
    echo
    echo "- Aktif: $active"
    echo "- Mode: $MODE"
    echo "- Hostname: $(ts_hostname)"
    [ -n "$ip" ] && echo "- IP Tailscale: $ip"
    [ -n "$dns" ] && echo "- DNS: $dns"
    echo "- Berakhir: $expires_s UTC"
    echo "- Diperbarui: $(iso_now) UTC"
  } > "$OUT/STATUS.md"
}

publish_status() {
  local active="$1" ip="${2:-}" dns="${3:-}"
  export RDPFREAD_MODE="$MODE" RDPFREAD_TSHOST="$(ts_hostname)"
  write_status "$active" "$ip" "$dns"
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -z "$token" ] && { warn "token GitHub kosong - publish status dilewati"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  local url="https://x-access-token:${token}@github.com/${GITHUB_REPOSITORY}.git"
  if git clone --quiet --depth 1 --branch status --single-branch "$url" "$tmp/repo" 2>/dev/null; then
    :
  else
    mkdir -p "$tmp/repo"
    git -C "$tmp/repo" init --quiet
    git -C "$tmp/repo" checkout --quiet --orphan status
    git -C "$tmp/repo" remote add origin "$url"
  fi
  cp "$STATUS_JSON" "$tmp/repo/rdp-status.json"
  cp "$OUT/STATUS.md" "$tmp/repo/STATUS.md"
  git -C "$tmp/repo" config user.name "rdpfread-bot"
  git -C "$tmp/repo" config user.email "rdpfread-bot@users.noreply.github.com"
  git -C "$tmp/repo" add rdp-status.json STATUS.md
  if git -C "$tmp/repo" commit --quiet -m "status: $MODE $active $(iso_now)"; then
    git -C "$tmp/repo" push --quiet origin status 2>/dev/null || warn "push branch status gagal"
  fi
  rm -rf "$tmp"
}

notify() {
  local event="$1" msg="$2"
  local full="RDPfread ($MODE) $event: $msg"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=${full}" >/dev/null 2>&1 || true
  fi
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "$DISCORD_WEBHOOK_URL" -H "Content-Type: application/json" \
      -d "{\"content\": \"$full\"}" >/dev/null 2>&1 || true
  fi
  if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "$NOTIFY_WEBHOOK_URL" -H "Content-Type: application/json" \
      -d "{\"event\": \"$event\", \"message\": \"$full\"}" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---------- state macOS (Release, asset terpisah) ----------
persist_state() {
  local label="${1:-checkpoint}"
  command -v gh >/dev/null 2>&1 || { warn "gh tidak ada - persist dilewati"; return 0; }
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local dir="$OUT/state-macos"
  rm -rf "$dir"; mkdir -p "$dir/stage/home" "$dir/stage/_tailscale"
  rsync -a --exclude '.cache' --exclude 'Library/Caches' \
        "/Users/${RDP_USER:-fread}/" "$dir/stage/home/" 2>/dev/null || \
    cp -pR "/Users/${RDP_USER:-fread}/." "$dir/stage/home/" 2>/dev/null || true
  local ts_src="" d
  for d in /Library/Tailscale /var/db/tailscale /var/lib/tailscale; do
    if [ -d "$d" ]; then ts_src="$d"; break; fi
  done
  if [ -n "$ts_src" ]; then
    echo "$ts_src" > "$dir/stage/_tailscale_src"
    sudo cp -pR "$ts_src/." "$dir/stage/_tailscale/" 2>/dev/null || true
    # v1.7.1: file hasil sudo cp milik root - tanpa chown ini, tar yang
    # jalan sebagai user runner tidak bisa membaca stage dan persist
    # selalu gagal ("tar state gagal" di semua checkpoint run #33).
    sudo chown -R "$(id -u):$(id -g)" "$dir/stage/_tailscale" 2>/dev/null || true
    log "State Tailscale ditemukan di $ts_src - ikut diarsipkan."
  else
    rmdir "$dir/stage/_tailscale" 2>/dev/null || true
    warn "State Tailscale tidak ditemukan - node baru tiap sesi (best effort)"
  fi
  local arc="$dir/$ASSET_BASE"
  tar -czf "$arc" -C "$dir/stage" . 2>/dev/null || { warn "tar state gagal"; return 0; }
  rm -rf "$dir/stage"
  local final="$arc"
  if [ -n "${STATE_ENCRYPTION_KEY:-}" ]; then
    if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in "$arc" -out "$arc.enc" 2>/dev/null; then
      rm -f "$arc"; final="$arc.enc"; log "State macOS dienkripsi AES-256."
    else
      warn "Enkripsi state macOS gagal - disimpan polos"
    fi
  fi
  local bytes; bytes="$(file_bytes "$final")"
  if [ "$bytes" -gt 1992294400 ]; then warn "State macOS > 1,9 GB - upload dilewati ($label)"; return 0; fi
  gh release view "$REL_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || \
    gh release create "$REL_TAG" --repo "$GITHUB_REPOSITORY" --title "RDPfread State (latest)" --notes "Arsip state sesi RDPfread - dikelola otomatis." >/dev/null 2>&1 || true
  if gh release upload "$REL_TAG" "$final" --clobber --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    log "State macOS terunggah ($label, $bytes bytes)."
  else
    warn "Upload state macOS gagal ($label)"
  fi
}

restore_state() {
  command -v gh >/dev/null 2>&1 || return 0
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local dir="$OUT/download-macos"
  rm -rf "$dir"; mkdir -p "$dir"
  gh release download "$REL_TAG" --repo "$GITHUB_REPOSITORY" --pattern "rdpfread-state-macos*" --dir "$dir" >/dev/null 2>&1 || true
  local f=""
  f="$(find "$dir" -name 'rdpfread-state-macos.tar.gz*' -type f 2>/dev/null | head -1)"
  [ -z "$f" ] && { log "Belum ada state macOS tersimpan - mulai bersih."; return 0; }
  log "State macOS ditemukan: $(basename "$f") ($(file_bytes "$f") bytes)"
  local arc="$f"
  if [ "${f##*.}" = "enc" ]; then
    if [ -z "${STATE_ENCRYPTION_KEY:-}" ]; then warn "State macOS terenkripsi tapi kunci kosong - restore dilewati"; return 0; fi
    local dec="$dir/rdpfread-state-macos.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in "$f" -out "$dec" 2>/dev/null; then
      warn "Dekripsi state macOS gagal - restore dilewati"; return 0
    fi
    arc="$dec"
  fi
  local ext="$dir/ext"; mkdir -p "$ext"
  tar -xzf "$arc" -C "$ext" 2>/dev/null || { warn "Ekstrak state macOS gagal"; return 0; }
  if [ -d "$ext/_tailscale" ]; then
    local dest; dest="$(cat "$ext/_tailscale_src" 2>/dev/null || echo /Library/Tailscale)"
    sudo mkdir -p "$dest"
    sudo cp -pR "$ext/_tailscale/." "$dest/" 2>/dev/null || true
    log "State Tailscale dipulihkan ke $dest (best effort)."
  fi
  if [ -d "$ext/home" ]; then
    sudo cp -pR "$ext/home/." "/Users/${RDP_USER:-fread}/" 2>/dev/null || true
    sudo chown -R "${RDP_USER:-fread}:staff" "/Users/${RDP_USER:-fread}" 2>/dev/null || true
    log "Home user dipulihkan dari state macOS."
  fi
}

# ---------- fase setup ----------
do_setup() {
  mkdir -p "$OUT"
  local dur="${DUR:-342}"
  STARTED_EPOCH="$(date +%s)"
  EXPIRES_EPOCH=$((STARTED_EPOCH + dur * 60))
  {
    echo "STARTED_EPOCH=$STARTED_EPOCH"
    echo "EXPIRES_EPOCH=$EXPIRES_EPOCH"
  } > "$SESS"
  log "Setup sesi macOS (mode: $MODE, durasi: ${dur} mnt)"

  if [ -n "${TZ_NAME:-}" ]; then sudo systemsetup -settimezone "$TZ_NAME" >/dev/null 2>&1 || true; fi

  local user="${RDP_USER:-fread}"
  if ! id "$user" >/dev/null 2>&1; then
    sudo sysadminctl -addUser "$user" -password "${RDP_PASSWORD:-}" -admin >/dev/null 2>&1 || warn "Buat user $user gagal - VNC/SSH mungkin tidak bisa login"
  else
    sudo sysadminctl -resetPasswordFor "$user" -newPassword "${RDP_PASSWORD:-}" >/dev/null 2>&1 || warn "Set password user $user gagal"
  fi
  log "User '$user' siap (password dari secret RDP_PASSWORD)."

  restore_state

  # Tailscale (brew sudah bawaan image runner macOS)
  if ! command -v tailscale >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      brew install tailscale >/dev/null 2>&1 || warn "Install Tailscale via brew gagal"
    else
      warn "brew tidak ada - Tailscale tidak bisa dipasang"
    fi
  fi
  if command -v tailscaled >/dev/null 2>&1; then
    sudo tailscaled install-system-daemon >/dev/null 2>&1 || true
    sleep 3
  fi
  local tshost; tshost="$(ts_hostname)"
  local up_ok=0 i
  for i in 1 2 3; do
    if sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY:-}" --hostname="$tshost" --accept-dns=false 2>/dev/null; then up_ok=1; break; fi
    sleep 5
  done
  [ "$up_ok" = "1" ] || warn "tailscale up belum berhasil - keepalive akan mencoba lagi"
  local ip="" dns=""
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  dns="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
  echo "TS_IP=$ip" >> "$SESS"
  echo "TS_DNS=$dns" >> "$SESS"
  log "Tailscale: host=$tshost ip=${ip:-?} dns=${dns:-?}"

  # SSH (Remote Login)
  sudo systemsetup -setremotelogin on >/dev/null 2>&1 || warn "Aktifkan Remote Login gagal"

  # Screen Sharing (VNC :5900) via kickstart
  local ks="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
  if [ -x "$ks" ]; then
    sudo "$ks" -activate -configure -access -on -users "$user" -privs -all -restart -agent -menu >/dev/null 2>&1 || warn "Aktivasi Screen Sharing gagal"
    sudo "$ks" -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "${RDP_PASSWORD:-}" >/dev/null 2>&1 || warn "Set password VNC gagal"
    log "Screen Sharing (VNC :5900) aktif untuk user $user."
    log "Catatan: password VNC legacy macOS dibatasi 8 karakter - bila RDP_PASSWORD lebih panjang, login VNC memakai 8 karakter pertamanya."
  else
    warn "kickstart tidak ditemukan - VNC tidak aktif"
  fi

  publish_status "true" "$ip" "$dns"
  notify "siap" "VNC ke ${ip}:5900 + SSH (user $user) | berakhir $(iso_at "$EXPIRES_EPOCH") UTC | mode $MODE"
  log "Setup macOS selesai - sesi siap dipakai (uji lapangan VNC masih diperlukan)."
}

# ---------- fase keepalive ----------
dispatch_next() {
  command -v gh >/dev/null 2>&1 || return 1
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 1
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local jeda=$((RANDOM % 21 + 10))
  log "Jeda acak $jeda detik sebelum dispatch sesi berikutnya..."
  sleep "$jeda"
  gh workflow run rdp.yml --repo "$GITHUB_REPOSITORY" \
    -f durasi_menit="${DUR:-342}" \
    -f hostname="${RDP_HOST:-rdpfread}" \
    -f rdp_user="${RDP_USER:-fread}" \
    -f runner="${RUNNER_IMAGE:-macos-14}" \
    -f preset="${PRESET:-minimal}" \
    -f optimasi="${OPTIMASI:-ya}" \
    -f akses_ssh="${AKSES_SSH:-tidak}" \
    -f timezone="${TZ_NAME:-Asia/Jakarta}" \
    -f perpanjang_otomatis="${PERPANJANG_OTOMATIS:-ya}" \
    -f debloat="${DEBLOAT_LEVEL:-tidak}" \
    -f linux_mode="${LINUX_MODE:-desktop}" \
    -f fps="${FPS_MODE:-standar}" \
    -f renewal="ya" >/dev/null 2>&1
}

do_keepalive() {
  # shellcheck disable=SC1090
  [ -f "$SESS" ] && . "$SESS"
  local expires="${EXPIRES_EPOCH:-0}"
  if [ "$expires" = "0" ]; then
    local dur="${DUR:-342}"
    expires=$(( $(date +%s) + dur * 60 ))
  fi
  local dispatched=0 tick=0
  log "Keepalive macOS mulai - sesi berakhir $(iso_at "$expires") UTC."
  while :; do
    local now remain
    now="$(date +%s)"
    remain=$(( (expires - now) / 60 ))
    [ $((expires - now)) -le 180 ] && { log "Sisa <= 3 menit - keepalive selesai."; break; }
    tick=$((tick + 1))
    local ip=""
    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -z "$ip" ]; then
      warn "detak #$tick | sisa $remain mnt | tailscale terputus - mencoba reconnect"
      sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY:-}" --hostname="$(ts_hostname)" --accept-dns=false >/dev/null 2>&1 || true
      ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    fi
    if [ $((tick % 5)) -eq 0 ]; then
      local dns=""
      dns="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
      publish_status "true" "$ip" "$dns"
      log "detak #$tick | sisa $remain mnt | ip=${ip:-?} | status diterbitkan"
    else
      log "detak #$tick | sisa $remain mnt | tailscale=${ip:-terputus}"
    fi
    if [ $((tick % 15)) -eq 0 ]; then persist_state "checkpoint"; fi
    if [ "${PERPANJANG_OTOMATIS:-ya}" = "ya" ] && [ "$dispatched" = "0" ] && [ "$remain" -le 20 ]; then
      if dispatch_next; then dispatched=1; log "Sesi berikutnya ter-dispatch (estafet macOS)."; else warn "Dispatch estafet gagal - dicoba lagi detak berikut"; fi
    fi
    sleep 60
  done
}

# ---------- fase finalize ----------
do_finalize() {
  # shellcheck disable=SC1090
  [ -f "$SESS" ] && . "$SESS"
  persist_state "final"
  local ip="${TS_IP:-}" dns="${TS_DNS:-}"
  publish_status "false" "$ip" "$dns"
  notify "selesai" "sesi macOS berakhir | mode $MODE"
  sudo tailscale logout >/dev/null 2>&1 || true
  log "Finalize macOS selesai."
}

case "${1:-}" in
  --setup) do_setup ;;
  --keepalive) do_keepalive ;;
  --finalize) do_finalize ;;
  *) echo "Pemakaian: $0 --setup|--keepalive|--finalize" >&2; exit 2 ;;
esac
