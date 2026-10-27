#!/usr/bin/env bash
# setup-linux.sh - sesi Linux RDPfread (v1.6.0), dipanggil workflow rdp.yml
# bila runner Ubuntu. Tiga fase (satu step workflow per fase):
#   --setup     : user + password (secret RDP_PASSWORD), timezone, restore
#                 state, Tailscale, lalu mode:
#                   desktop        = XFCE4 + XRDP (:3389) + SSH (:22)
#                   desktop-ringan = desktop + Firefox + LibreOffice
#                   desktop-dev    = desktop + VS Code (Git/Node/Python
#                                    sudah bawaan image runner)
#                   polos          = SSH saja, tanpa desktop
#                 Akhiri dengan publish status + notifikasi "ready".
#   --keepalive : detak 1 menit (publish 5 mnt, checkpoint state 15 mnt,
#                 reconnect Tailscale otomatis, dispatch estafet 20 mnt
#                 sebelum habis + jeda acak, auto-stop 3 mnt sebelum habis).
#   --finalize  : simpan state final, status off, notifikasi, logout
#                 Tailscale.
# State Linux memakai asset terpisah di Release yang sama dengan Windows:
# rdpfread-state-linux.tar.gz[.enc] - isi: home user (minus cache) + state
# Tailscale (identitas node/IP bertahan antar sesi, pola yang sama dengan
# QVPS). Enkripsi AES-256 sama seperti state Windows bila
# STATE_ENCRYPTION_KEY terisi.
set -u

TAG="RDPfread:linux"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="$WS/out"
SESS="$OUT/linux-session.env"
STATUS_JSON="$OUT/rdp-status.json"
MODE="linux-${LINUX_MODE:-desktop}"
[ "${LINUX_MODE:-desktop}" = "polos" ] && MODE="linux-ssh"
REL_TAG="rdpfread-state-latest"
ASSET_BASE="rdpfread-state-linux.tar.gz"

log() { echo "[$(date -u +%H:%M:%S) UTC][$TAG] $*"; }
warn() { log "WARN: $*"; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

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
import json, os, sys
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
    "preset": os.environ.get("RDPFREAD_MODE", "linux"),
    "linux_mode": os.environ.get("LINUX_MODE", "desktop"),
    "started_at": started,
    "expires_at": expires,
    "duration_menit": int(os.environ.get("DUR", "342") or 342),
    "run_number": os.environ.get("GITHUB_RUN_NUMBER", ""),
    "run_id": os.environ.get("GITHUB_RUN_ID", ""),
    "updated_at": "",
})
import datetime
data["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(data, open(path, "w"), indent=2)
PYEOF
  # STATUS.md ringkas
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

# ---------- state Linux (Release, asset terpisah) ----------
state_file_local() { echo "$OUT/state-linux/$ASSET_BASE"; }

persist_state() {
  local label="${1:-checkpoint}"
  command -v gh >/dev/null 2>&1 || { warn "gh tidak ada - persist dilewati"; return 0; }
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local dir="$OUT/state-linux"
  rm -rf "$dir"; mkdir -p "$dir/stage/home" "$dir/stage/_tailscale"
  rsync -a --exclude '.cache' --exclude '.local/share/Trash' \
        --exclude '.config/google-chrome/*/Cache' --exclude '.mozilla/firefox/*/cache2' \
        "/home/${RDP_USER:-fread}/" "$dir/stage/home/" 2>/dev/null || \
    cp -a "/home/${RDP_USER:-fread}/." "$dir/stage/home/" 2>/dev/null || true
  sudo rsync -a --exclude '*.sock' --exclude '*.log*' /var/lib/tailscale/ "$dir/stage/_tailscale/" 2>/dev/null || true
  sudo chown -R "$(id -u):$(id -g)" "$dir/stage/_tailscale" 2>/dev/null || true
  local arc="$dir/$ASSET_BASE"
  tar -czf "$arc" -C "$dir/stage" . 2>/dev/null || { warn "tar state gagal"; return 0; }
  rm -rf "$dir/stage"
  local final="$arc"
  if [ -n "${STATE_ENCRYPTION_KEY:-}" ]; then
    if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in "$arc" -out "$arc.enc" 2>/dev/null; then
      rm -f "$arc"; final="$arc.enc"; log "State Linux dienkripsi AES-256."
    else
      warn "Enkripsi state Linux gagal - disimpan polos"
    fi
  fi
  local bytes; bytes="$(stat -c %s "$final" 2>/dev/null || echo 0)"
  if [ "$bytes" -gt 1992294400 ]; then warn "State Linux > 1,9 GB - upload dilewati ($label)"; return 0; fi
  gh release view "$REL_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || \
    gh release create "$REL_TAG" --repo "$GITHUB_REPOSITORY" --title "RDPfread State (latest)" --notes "Arsip state sesi RDPfread - dikelola otomatis." >/dev/null 2>&1 || true
  if gh release upload "$REL_TAG" "$final" --clobber --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    log "State Linux terunggah ($label, $bytes bytes)."
  else
    warn "Upload state Linux gagal ($label)"
  fi
}

restore_state() {
  command -v gh >/dev/null 2>&1 || return 0
  [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local dir="$OUT/download-linux"
  rm -rf "$dir"; mkdir -p "$dir"
  gh release download "$REL_TAG" --repo "$GITHUB_REPOSITORY" --pattern "rdpfread-state-linux*" --dir "$dir" >/dev/null 2>&1 || true
  local f=""
  f="$(find "$dir" -name 'rdpfread-state-linux.tar.gz*' -type f 2>/dev/null | head -1)"
  [ -z "$f" ] && { log "Belum ada state Linux tersimpan - mulai bersih."; return 0; }
  log "State Linux ditemukan: $(basename "$f") ($(stat -c %s "$f") bytes)"
  local arc="$f"
  if [ "${f##*.}" = "enc" ]; then
    if [ -z "${STATE_ENCRYPTION_KEY:-}" ]; then warn "State Linux terenkripsi tapi kunci kosong - restore dilewati"; return 0; fi
    local dec="$dir/rdpfread-state-linux.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:STATE_ENCRYPTION_KEY -in "$f" -out "$dec" 2>/dev/null; then
      warn "Dekripsi state Linux gagal - restore dilewati"; return 0
    fi
    arc="$dec"
  fi
  local ext="$dir/ext"; mkdir -p "$ext"
  tar -xzf "$arc" -C "$ext" 2>/dev/null || { warn "Ekstrak state Linux gagal"; return 0; }
  if [ -d "$ext/_tailscale" ]; then
    sudo mkdir -p /var/lib/tailscale
    sudo cp -a "$ext/_tailscale/." /var/lib/tailscale/ 2>/dev/null || true
    log "State Tailscale dipulihkan (identitas node dipertahankan)."
  fi
  if [ -d "$ext/home" ]; then
    sudo rsync -a "$ext/home/" "/home/${RDP_USER:-fread}/" 2>/dev/null || \
      sudo cp -a "$ext/home/." "/home/${RDP_USER:-fread}/" 2>/dev/null || true
    sudo chown -R "${RDP_USER:-fread}:${RDP_USER:-fread}" "/home/${RDP_USER:-fread}" 2>/dev/null || true
    log "Home user dipulihkan dari state Linux."
  fi
}

# Firefox .deb resmi dari repo Mozilla (v1.6.0): paket apt Ubuntu 24.04
# untuk firefox hanya stub snap - di sesi XRDP, snap bisa rewel; .deb
# Mozilla menghindari itu. Best effort: gagal = warn, setup tetap lanjut.
install_firefox_deb() {
  sudo install -d -m 0755 /etc/apt/keyrings 2>/dev/null || { warn "Buat /etc/apt/keyrings gagal - Firefox dilewati"; return 0; }
  if ! curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg 2>/dev/null | sudo gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg 2>/dev/null; then
    warn "Kunci repo Mozilla gagal diunduh - Firefox dilewati"
    return 0
  fi
  echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null 2>&1
  printf '%s\n' 'Package: *' 'Pin: origin packages.mozilla.org' 'Pin-Priority: 1000' | sudo tee /etc/apt/preferences.d/mozilla >/dev/null 2>&1
  sudo apt-get update -qq >/dev/null 2>&1 || true
  local ok=0 i
  for i in 1 2; do
    if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq firefox >/dev/null 2>&1; then ok=1; break; fi
  done
  [ "$ok" = "1" ] || warn "Install Firefox bermasalah - XFCE tetap jalan"
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
  log "Setup sesi Linux (mode: $MODE, durasi: ${dur} mnt)"

  if [ -n "${TZ_NAME:-}" ]; then sudo timedatectl set-timezone "$TZ_NAME" 2>/dev/null || true; fi

  local user="${RDP_USER:-fread}"
  if ! id "$user" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$user" || true
  fi
  echo "${user}:${RDP_PASSWORD:-}" | sudo chpasswd
  sudo usermod -aG sudo "$user" 2>/dev/null || true
  log "User '$user' siap (password dari secret RDP_PASSWORD)."

  restore_state

  # Tailscale
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || warn "Install Tailscale gagal"
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

  # SSH (kedua mode) - drop-in password auth
  sudo apt-get update -qq >/dev/null 2>&1 || true
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq openssh-server >/dev/null 2>&1 || warn "Install openssh-server gagal"
  fi
  sudo mkdir -p /run/sshd /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/99-rdpfread.conf >/dev/null
  sudo systemctl enable ssh >/dev/null 2>&1 || true
  sudo systemctl restart ssh >/dev/null 2>&1 || sudo service ssh restart >/dev/null 2>&1 || true

  case "${LINUX_MODE:-desktop}" in
    desktop*)
      log "Memasang XFCE4 + XRDP (bisa beberapa menit)..."
      local ok=0
      for i in 1 2; do
        if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq xfce4 xfce4-goodies xfce4-terminal xrdp xorgxrdp dbus-x11 >/dev/null 2>&1; then ok=1; break; fi
        sudo apt-get update -qq >/dev/null 2>&1 || true
      done
      [ "$ok" = "1" ] || warn "Install XFCE4/XRDP bermasalah - periksa log step ini"
      echo "xfce4-session" | sudo -u "$user" tee "/home/$user/.xsession" >/dev/null
      # v1.7.4: batasi warna sesi ke 16-bit. Di link HP jarak jauh, 32-bit
      # menggandakan data gambar dibanding 16-bit tanpa manfaat nyata di
      # layar HP (hanya gradasi foto/wallpaper yang sedikit banding).
      # Ini pemangkas bandwidth terbesar di sisi server; klien tetap
      # bisa nego di bawah cap ini. Balikkan ke 32 bila warna penuh
      # lebih penting daripada respons.
      sudo sed -i 's/^max_bpp=.*/max_bpp=16/' /etc/xrdp/xrdp.ini 2>/dev/null || true
      sudo sed -i 's/^tcp_nodelay=.*/tcp_nodelay=true/' /etc/xrdp/xrdp.ini 2>/dev/null || true
      sudo adduser xrdp ssl-cert >/dev/null 2>&1 || true
      # v1.7.2: startwm.sh bawaan Ubuntu tidak menyiapkan D-Bus dan
      # mewariskan XDG_*_HOME dari environment runner. Terbukti di #35:
      # XDG_CONFIG_HOME=/home/runner/.config membuat xfce4-session gagal
      # "Unable to load a failsafe session". Tulis ulang dengan
      # environment sesi yang bersih + dbus-launch.
      sudo tee /etc/xrdp/startwm.sh > /dev/null <<'EOF'
#!/bin/sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset XDG_CONFIG_HOME
unset XDG_DATA_HOME
unset XDG_CACHE_HOME
unset XDG_STATE_HOME
export XDG_CONFIG_DIRS=/etc/xdg:${XDG_CONFIG_DIRS:-/etc/xdg}
exec dbus-launch --exit-with-session startxfce4
EOF
      sudo chmod +x /etc/xrdp/startwm.sh
      # v1.7.3: matikan compositing xfwm4 secara default. Compositing
      # (transparansi/bayangan) mahal di RDP dan terasa sebagai lag di
      # link jauh; untuk sesi remote, nonaktif adalah default yang benar.
      # Ditulis ke default sistem /etc/xdg agar berlaku untuk user baru.
      sudo python3 - <<'PYEOF' 2>/dev/null || true
import os, xml.etree.ElementTree as ET
p = '/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml'
os.makedirs(os.path.dirname(p), exist_ok=True)
if os.path.exists(p):
    t = ET.parse(p); r = t.getroot()
else:
    r = ET.Element('channel', {'name': 'xfwm4', 'version': '1.0'}); t = ET.ElementTree(r)
g = r.find("property[@name='general']")
if g is None:
    g = ET.SubElement(r, 'property', {'name': 'general', 'type': 'empty'})
c = g.find("property[@name='use_compositing']")
if c is None:
    c = ET.SubElement(g, 'property', {'name': 'use_compositing', 'type': 'bool', 'value': 'false'})
else:
    c.set('value', 'false')
t.write(p, encoding='UTF-8', xml_declaration=True)
PYEOF
      case "${LINUX_MODE:-desktop}" in
        desktop-ringan)
          log "Varian ringan: memasang Firefox (repo resmi Mozilla, .deb) + LibreOffice..."
          install_firefox_deb
          local ok2=0
          for i in 1 2; do
            if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq libreoffice >/dev/null 2>&1; then ok2=1; break; fi
            sudo apt-get update -qq >/dev/null 2>&1 || true
          done
          [ "$ok2" = "1" ] || warn "Install LibreOffice bermasalah - Firefox/XFCE tetap jalan"
          ;;
        desktop-dev)
          log "Varian dev: memasang VS Code (Git/Node/Python sudah bawaan image runner)..."
          local code_deb; code_deb="$(mktemp -d)/code.deb"
          if curl -fsSL -o "$code_deb" "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" 2>/dev/null; then
            sudo dpkg -i "$code_deb" >/dev/null 2>&1 || sudo apt-get install -f -y -qq >/dev/null 2>&1 || warn "Install VS Code bermasalah"
          else
            warn "Unduh VS Code gagal - varian dev jalan tanpa VS Code"
          fi
          ;;
      esac
      sudo systemctl enable xrdp xrdp-sesman >/dev/null 2>&1 || true
      sudo systemctl restart xrdp-sesman xrdp >/dev/null 2>&1 || warn "Start XRDP gagal"
      log "Desktop XFCE4 + XRDP siap di port 3389 (varian: ${LINUX_MODE:-desktop})."
      ;;
    *)
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq tmux htop git curl >/dev/null 2>&1 || true
      log "Mode polos: SSH saja (port 22), tanpa desktop."
      ;;
  esac

  publish_status "true" "$ip" "$dns"
  local cara="SSH ke ${ip} (user $user)"
  case "${LINUX_MODE:-desktop}" in
    desktop*) cara="RDP ke ${ip} atau SSH (user $user)" ;;
  esac
  notify "siap" "$cara | berakhir $(iso_at "$EXPIRES_EPOCH") UTC | mode $MODE"
  log "Setup Linux selesai - sesi siap dipakai."
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
    -f runner="${RUNNER_IMAGE:-ubuntu-24.04}" \
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
  log "Keepalive Linux mulai - sesi berakhir $(iso_at "$expires") UTC."
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
      if dispatch_next; then dispatched=1; log "Sesi berikutnya ter-dispatch (estafet Linux)."; else warn "Dispatch estafet gagal - dicoba lagi detak berikut"; fi
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
  notify "selesai" "sesi Linux berakhir | mode $MODE"
  sudo tailscale logout >/dev/null 2>&1 || true
  log "Finalize Linux selesai."
}

case "${1:-}" in
  --setup) do_setup ;;
  --keepalive) do_keepalive ;;
  --finalize) do_finalize ;;
  *) echo "Pemakaian: $0 --setup|--keepalive|--finalize" >&2; exit 2 ;;
esac
