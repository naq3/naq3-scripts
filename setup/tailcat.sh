#!/usr/bin/env bash
# Install a tailcat server (https://github.com/tailscale/tailcat) on a Linux VM
# as a systemd service that tunnels to local TCP ports (sshd by default).
#
# Uses the release binary tarball, so it works on Ubuntu/Debian as well as
# Amazon Linux 2023/RHEL (no dependency on apt/dnf).
#
# Usage (as root):
#   sudo ./tailcat-install.sh
#   sudo TAILCAT_PORT=22,8080,4242 ./tailcat-install.sh
#   sudo TAILCAT_ALLOW=nodekey:<other-key> ./tailcat-install.sh
#
#   # or straight from GitHub (pass env vars after sudo):
#   curl -fsSL <raw-url>/tailcat-install.sh | sudo TAILCAT_PORT=22,8080 bash
#
# Environment variables:
#   TAILCAT_VER    release version (default 0.7.0)
#   TAILCAT_ALLOW  comma-separated client nodekeys allowed to connect
#                  (default: the nodekey below; set TAILCAT_ALLOW= (empty)
#                  to allow any client that knows the tc... address).
#                  Get a client nodekey with: tailcat genkey --client --key=client-default
#   TAILCAT_PORT   comma-separated local ports to serve (default 22, e.g. 22,8080,4242).
#                  The list REPLACES the previous one on re-run — always pass every port.
#                  Ports without a listening service are fine: tailcat dials
#                  localhost:<port> only when a client connects.
#   TAILCAT_FORCE  =1 to re-download/reinstall the binary even if the version matches
#
# Idempotent: re-running never creates a new key, so the tc... address stays the same.
# Note: re-running restarts tailcat when the config changes, which drops SSH
# sessions that go through tailcat itself.

set -euo pipefail

VER="${TAILCAT_VER:-0.7.0}"
ALLOW="${TAILCAT_ALLOW-nodekey:342bdd37a7b0077eae998e36fef4f7c676ed2829812d08373fe343d74cb98b55}"
PORT="${TAILCAT_PORT:-22}"
FORCE="${TAILCAT_FORCE:-0}"

BIN=/usr/local/bin/tailcat
SVC_USER=tailcat
SVC_HOME=/var/lib/tailcat
UNIT=/etc/systemd/system/tailcat.service
BASE_URL="https://github.com/tailscale/tailcat/releases/download/v${VER}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo)."
command -v systemctl >/dev/null || die "systemd not found."
for c in curl tar sha256sum; do
  command -v "$c" >/dev/null || die "Missing command: $c"
done

# ---------- 0. Detect OS / arch ----------
. /etc/os-release
log "OS: ${PRETTY_NAME:-$ID}"

case "$(uname -m)" in
  x86_64|amd64)   ARCH=amd64 ;;
  aarch64|arm64)  ARCH=arm64 ;;
  armv7l|armv7*)  ARCH=armv7 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
log "Arch: $ARCH"

# sshd unit name: Ubuntu/Debian = ssh.service, AL2023/RHEL = sshd.service
if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
  SSH_UNIT=ssh.service
elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
  SSH_UNIT=sshd.service
else
  die "Neither ssh.service nor sshd.service found — install openssh-server first."
fi
log "SSH unit: $SSH_UNIT"

NOLOGIN=$(command -v nologin || echo /usr/sbin/nologin)

# ---------- 1. Install binary from the release tarball ----------
# Version marker file (tailcat has no documented `version` command)
VER_MARKER=/usr/local/share/tailcat/VERSION
installed_ver=""
if [[ -x $BIN && -f $VER_MARKER ]]; then
  installed_ver=$(<"$VER_MARKER")
fi

if [[ $installed_ver == "$VER" && $FORCE != 1 ]]; then
  log "tailcat $VER already installed at $BIN — skipping download."
else
  TARBALL="tailcat_${VER}_linux_${ARCH}.tar.gz"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  log "Downloading $TARBALL"
  curl -fsSL --retry 3 -o "$TMP/$TARBALL"      "$BASE_URL/$TARBALL"
  curl -fsSL --retry 3 -o "$TMP/checksums.txt" "$BASE_URL/checksums.txt"

  log "Verifying sha256"
  (cd "$TMP" && grep " ${TARBALL}\$" checksums.txt | sha256sum -c -) \
    || die "Checksum mismatch!"

  mkdir -p "$TMP/x"
  tar -xzf "$TMP/$TARBALL" -C "$TMP/x" tailcat
  install -m 0755 -o root -g root "$TMP/x/tailcat" "$BIN"
  install -d -m 0755 "$(dirname "$VER_MARKER")"
  echo "$VER" >"$VER_MARKER"
  log "Installed $BIN ($VER)"
fi
"$BIN" --help 2>&1 | head -3 || true

# ---------- 2. Make sure sshd is running ----------
log "Enabling $SSH_UNIT"
systemctl enable --now "$SSH_UNIT"
# Warn only: tailcat dials localhost:<port> when a client connects,
# so ports without a service yet can still be served in advance.
IFS=',' read -ra PORT_LIST <<<"$PORT"
for p in "${PORT_LIST[@]}"; do
  [[ $p =~ ^[0-9]+$ ]] || die "Invalid port in TAILCAT_PORT: '$p'"
  if ! ss -ltn | grep -qE "[:.]${p}[[:space:]]"; then
    warn "Nothing is listening on port $p yet (client connections will be refused until a service starts)."
  fi
done

# ---------- 3. Dedicated user + persistent key ----------
if ! id "$SVC_USER" >/dev/null 2>&1; then
  log "Creating system user $SVC_USER"
  useradd --system --create-home --home-dir "$SVC_HOME" --shell "$NOLOGIN" "$SVC_USER"
fi
install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME"

as_tc() { runuser -u "$SVC_USER" -- env HOME="$SVC_HOME" "$@"; }

KEY_FILE="$SVC_HOME/.config/tailcat/keys/default.private.json"
if [[ -f $KEY_FILE ]] || as_tc "$BIN" genkey --list 2>/dev/null | grep -qw default; then
  log "Key 'default' already exists — keeping the current address."
else
  log "Generating key 'default' (--fixed-region)"
  as_tc "$BIN" genkey --key=default --fixed-region
fi

# ---------- 4. systemd service ----------
ALLOW_ARG=""
[[ -n $ALLOW ]] && ALLOW_ARG="--allow=${ALLOW} "

log "Writing $UNIT"
cat >"$UNIT.tmp" <<EOF
[Unit]
Description=tailcat server (tunnel to local ports ${PORT})
After=network-online.target ${SSH_UNIT}
Wants=network-online.target

[Service]
User=${SVC_USER}
Group=${SVC_USER}
Environment=HOME=${SVC_HOME}
ExecStart=${BIN} serve ${ALLOW_ARG}${PORT}
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SVC_HOME}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

if [[ -f $UNIT ]] && cmp -s "$UNIT.tmp" "$UNIT"; then
  rm -f "$UNIT.tmp"
  CHANGED=0
else
  mv "$UNIT.tmp" "$UNIT"
  CHANGED=1
fi

systemctl daemon-reload
systemctl enable tailcat.service >/dev/null
if [[ $CHANGED == 1 ]] || [[ $installed_ver != "$VER" ]] || ! systemctl is-active -q tailcat; then
  log "Restarting tailcat.service"
  systemctl restart tailcat.service
fi

# ---------- 5. Result ----------
sleep 3
systemctl --no-pager --lines=0 status tailcat.service || true
ADDR=$(journalctl -u tailcat.service -n 50 --no-pager -o cat 2>/dev/null \
        | grep -oE 'tc[A-Za-z0-9]{10,}' | tail -1 || true)
echo
if [[ -n $ADDR ]]; then
  log "Tailcat address: $ADDR"
  echo "    On the client: tailcat ping --until-direct $ADDR"
  echo "    Forward ports: tailcat forward $ADDR <port> [<local>:<remote> ...]"
else
  warn "Address not found in journal yet. Check: journalctl -u tailcat -n 30 --no-pager"
fi
[[ -z $ALLOW ]] && warn "Clients are not restricted (TAILCAT_ALLOW is empty) — anyone with the tc... address can reach ports $PORT."
exit 0
