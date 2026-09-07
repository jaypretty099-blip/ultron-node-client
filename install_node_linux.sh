#!/usr/bin/env bash
#
# Welcome to the Ultron Legion — Linux edition. Your laptop, desktop, or
# spare box was going to spend today idling — this gives it a job instead.
#
# What you're about to run: it grabs a small llama.cpp worker and Tailscale,
# both official prebuilt binaries (nothing compiled, nothing needs a
# compiler), gets this machine a quiet membership card on a private
# Tailscale network, and sets it up to report for duty automatically after
# every reboot. No root required, no drama.
#
# Enlistment line:
#   curl -fsSL https://raw.githubusercontent.com/<you>/ultron-node-client/main/install_node_linux.sh | bash
#
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================

# No secret key hiding in this file — same reasoning as the Android script:
# the internet never forgets, and bots read public repos for breakfast. If
# you haven't already set TAILSCALE_AUTH_KEY yourself, this politely asks
# the mothership for a fresh, one-time-use key at install time.
ORCHESTRATOR_JOIN_KEY_URL="http://47.84.207.32:8010/join-key"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

# Self-updates, once already on the tailnet, are fetched only over the
# tailnet IP — never plain public HTTP — for the same reason as Android:
# this is the one thing here that runs downloaded code unattended, so it
# only trusts a source we're already mutually authenticated with.
ORCHESTRATOR_TAILNET_IP="100.73.49.17"
UPDATE_CHECK_INTERVAL_SECONDS=1800

ULTRON_HOME="$HOME/.ultron"
TAILSCALE_DIR="$HOME/.tailscale"
TAILSCALE_SOCKET="$TAILSCALE_DIR/tailscaled.sock"
TAILSCALE_STATE_DIR="$TAILSCALE_DIR/state"
TAILSCALE_SOCKS5_PORT=1055
TAILSCALE_BIN_DIR="$ULTRON_HOME/bin/tailscale"
TAILSCALE_BIN="$TAILSCALE_BIN_DIR/tailscale"
TAILSCALED_BIN="$TAILSCALE_BIN_DIR/tailscaled"

# Official prebuilt release, pinned to an exact version — not "whatever's
# current" — same reasoning as everywhere else in this project: reproducible
# builds, no surprise regressions landing on volunteer machines unannounced.
TAILSCALE_VERSION="1.102.3"

LLAMA_BIN_DIR="$ULTRON_HOME/bin/llama"
LLAMA_RPC_BIN="$LLAMA_BIN_DIR/ggml-rpc-server"
# llama.cpp's own docs call the RPC backend fragile/proof-of-concept, and it
# has to speak the exact same wire version the VPS orchestrator was built
# from — two mismatched commits connected at the TCP level and then just
# hung forever, no error, confirmed on a real device earlier in this
# project. b10839 is llama.cpp's own release tag for the exact commit
# pinned everywhere else (VPS, Android): using the official prebuilt binary
# from that same tagged release keeps this bit-for-bit compatible without
# needing a compiler on this machine at all. If this ever moves, it has to
# move together with the pins in deploy_vps.sh and install_node.sh.
LLAMA_CPP_BUILD_TAG="b10839"

RPC_PORT=50052
NODE_AGENT_PORT=50053

NODE_HOSTNAME="ultron-linux-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

LOG_FILE="$ULTRON_HOME/logs/install.log"

# ============================================================================
# Pinned checksums — every download below is verified against one of these
# before it's ever executed. A CDN hiccup or a tampered mirror gets refused,
# not silently run.
# ============================================================================
declare -A TAILSCALE_SHA256=(
    [amd64]="36ddd9b51be57ffc2990cf76323cfa13643bfbb1b8a969f6183fa164741cdef5"
    [arm64]="a0fa1b154af8c61f862a2259f559f7396d96c0225f4a863eae2333e1546bbe25"
)
declare -A LLAMA_SHA256=(
    [amd64]="0883bbc958fcaad3b686d48381de6b4beb864ef93e440bd0da2cde56a8ab2318"
    [arm64]="1715afc12e9c283a5b2debb3c905570da205f11a6b7a31e1349d6ac327803414"
)

# ============================================================================

mkdir -p "$ULTRON_HOME"/{bin,logs,tmp} "$TAILSCALE_DIR" "$TAILSCALE_BIN_DIR" "$LLAMA_BIN_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[install_node_linux] $*"; }
die() { echo "[install_node_linux] ERROR: $*" >&2; exit 1; }

log "Enlisting this machine as $NODE_HOSTNAME. Stand by."

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required and wasn't found — install it and re-run."
done

case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported CPU architecture $(uname -m) — this script currently supports amd64/arm64 Linux only." ;;
esac
log "Detected architecture: $ARCH"

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for $file (got $actual, expected $expected) — refusing to run it."
}

# ----------------------------------------------------------------------------
# 1. Tailscale — official prebuilt binary, userspace networking, no root
# ----------------------------------------------------------------------------
if [[ ! -x "$TAILSCALED_BIN" ]]; then
    log "Fetching Tailscale $TAILSCALE_VERSION ($ARCH) ..."
    TS_TARBALL="$ULTRON_HOME/tmp/tailscale.tgz"
    curl -fsSL -o "$TS_TARBALL" "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${ARCH}.tgz"
    verify_sha256 "$TS_TARBALL" "${TAILSCALE_SHA256[$ARCH]}"
    tar xzf "$TS_TARBALL" -C "$ULTRON_HOME/tmp"
    cp "$ULTRON_HOME/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscale" "$TAILSCALE_BIN"
    cp "$ULTRON_HOME/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscaled" "$TAILSCALED_BIN"
    chmod +x "$TAILSCALE_BIN" "$TAILSCALED_BIN"
    rm -rf "$TS_TARBALL" "$ULTRON_HOME/tmp/tailscale_${TAILSCALE_VERSION}_${ARCH}"
else
    log "Tailscale already present — skipping download"
fi

# ----------------------------------------------------------------------------
# 2. llama.cpp RPC worker — official prebuilt binary at the pinned build
# ----------------------------------------------------------------------------
if [[ ! -x "$LLAMA_RPC_BIN" ]]; then
    log "Fetching the llama.cpp RPC worker ($LLAMA_CPP_BUILD_TAG, $ARCH) — no compiling needed ..."
    LLAMA_ASSET="ubuntu-${ARCH/amd64/x64}"
    LLAMA_TARBALL="$ULTRON_HOME/tmp/llama.tar.gz"
    curl -fsSL -o "$LLAMA_TARBALL" \
        "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_CPP_BUILD_TAG}/llama-${LLAMA_CPP_BUILD_TAG}-bin-${LLAMA_ASSET}.tar.gz"
    verify_sha256 "$LLAMA_TARBALL" "${LLAMA_SHA256[$ARCH]}"
    tar xzf "$LLAMA_TARBALL" -C "$ULTRON_HOME/tmp"
    # The extracted dir carries libggml-rpc.so and CPU-feature-specific
    # backend .so's (e.g. libggml-cpu-haswell.so) that ggml-rpc-server loads
    # by relative path at startup — everything has to live together, not
    # just the one binary copied out on its own.
    rm -rf "$LLAMA_BIN_DIR"
    mv "$ULTRON_HOME/tmp/llama-${LLAMA_CPP_BUILD_TAG}" "$LLAMA_BIN_DIR"
    chmod +x "$LLAMA_RPC_BIN"
    rm -f "$LLAMA_TARBALL"
else
    log "llama.cpp RPC worker already present — skipping download"
fi

# ----------------------------------------------------------------------------
# 3. The world's smallest snitch — reports free RAM back to HQ. Best-effort:
#    if python3 genuinely isn't on this machine, the RPC worker still runs
#    fine, HQ just won't count this node's RAM toward big-model placement.
# ----------------------------------------------------------------------------
HAVE_PYTHON3=""
if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON3=1
    cat > "$ULTRON_HOME/bin/node_agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""The world's smallest snitch: reports how much RAM this machine has free
so HQ knows whether to trust it with real work. Loopback-only."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 50053


def read_meminfo():
    total_kb = available_kb = 0
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                total_kb = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                available_kb = int(line.split()[1])
    return total_kb * 1024, available_kb * 1024


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/meminfo":
            self.send_response(404)
            self.end_headers()
            return
        total_bytes, available_bytes = read_meminfo()
        body = json.dumps({"total_bytes": total_bytes, "available_bytes": available_bytes}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF
else
    log "WARNING: python3 not found — this node will still contribute compute,"
    log "but HQ won't get a RAM report from it. Install python3 any time to fix that."
fi

# ----------------------------------------------------------------------------
# 4. The night watch — checks in with HQ periodically, updates itself
#    quietly if there's anything new. Same hash-gated pattern as Android,
#    hitting the linux-specific endpoints so it never downloads the wrong
#    platform's script.
# ----------------------------------------------------------------------------
cat > "$ULTRON_HOME/bin/updater.sh" <<UPDATEEOF
#!/usr/bin/env bash
ULTRON_HOME="$ULTRON_HOME"
ORCHESTRATOR_TAILNET_IP="$ORCHESTRATOR_TAILNET_IP"
CHECK_INTERVAL="$UPDATE_CHECK_INTERVAL_SECONDS"
LOCAL_SCRIPT="\$ULTRON_HOME/bin/install_node_linux.sh"
LOG="\$ULTRON_HOME/logs/updater.log"
# --tun=userspace-networking means there's no real network interface for the
# OS to route tailnet IPs through — outbound connections to other tailnet
# members have to go explicitly through tailscaled's own SOCKS5 proxy or
# they just hang until they time out (confirmed on a real device earlier in
# this project, same fix applies here).
TS_PROXY="127.0.0.1:${TAILSCALE_SOCKS5_PORT}"

log() { echo "[updater] \$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG"; }

while true; do
    sleep "\$CHECK_INTERVAL"

    REMOTE_HASH="\$(curl -fsS -m 15 --socks5-hostname "\$TS_PROXY" "http://\$ORCHESTRATOR_TAILNET_IP:8010/client-script-hash/linux" 2>/dev/null || true)"
    if [[ -z "\$REMOTE_HASH" ]]; then
        continue
    fi

    LOCAL_HASH=""
    if [[ -f "\$LOCAL_SCRIPT" ]]; then
        LOCAL_HASH="\$(sha256sum "\$LOCAL_SCRIPT" 2>/dev/null | awk '{print \$1}')"
    fi

    if [[ "\$REMOTE_HASH" == "\$LOCAL_HASH" ]]; then
        continue
    fi

    log "Update available (was \$LOCAL_HASH, now \$REMOTE_HASH) — applying quietly"
    NEW_SCRIPT="\$ULTRON_HOME/tmp/install_node_linux.sh.new"
    if ! curl -fsS -m 60 --socks5-hostname "\$TS_PROXY" "http://\$ORCHESTRATOR_TAILNET_IP:8010/client-script/linux" -o "\$NEW_SCRIPT" 2>>"\$LOG"; then
        log "Download failed, will try again next cycle"
        continue
    fi

    DOWNLOADED_HASH="\$(sha256sum "\$NEW_SCRIPT" 2>/dev/null | awk '{print \$1}')"
    if [[ "\$DOWNLOADED_HASH" != "\$REMOTE_HASH" ]]; then
        log "Downloaded content didn't match the promised hash, discarding"
        rm -f "\$NEW_SCRIPT"
        continue
    fi

    cp "\$NEW_SCRIPT" "\$LOCAL_SCRIPT"
    chmod +x "\$LOCAL_SCRIPT"
    rm -f "\$NEW_SCRIPT"

    pkill -f "ggml-rpc-server" 2>/dev/null || true
    pkill -f "node_agent.py" 2>/dev/null || true
    pkill -f "tailscaled.*--socket=" 2>/dev/null || true

    bash "\$LOCAL_SCRIPT" >> "\$LOG" 2>&1
    log "Update applied."
    # Not restarting this loop itself — changes to the updater's own logic
    # take effect on the next natural restart of the systemd unit, not
    # mid-loop. Handing off to a fresh copy here would mean this process
    # killing its own command line mid-execution, a worse trade than
    # waiting.
done
UPDATEEOF
chmod +x "$ULTRON_HOME/bin/updater.sh"

# ----------------------------------------------------------------------------
# 5. Getting this machine its membership card (Tailscale, userspace, no root)
# ----------------------------------------------------------------------------
log "Waking up the private network connection ..."
mkdir -p "$TAILSCALE_STATE_DIR"

if pgrep -f "tailscaled.*--socket=$TAILSCALE_SOCKET" >/dev/null 2>&1 && [[ ! -S "$TAILSCALE_SOCKET" ]]; then
    log "Found a stale tailscaled with no working socket, clearing it out ..."
    pkill -f "tailscaled.*--socket=$TAILSCALE_SOCKET" 2>/dev/null || true
    sleep 1
fi

if ! pgrep -f "tailscaled.*--socket=$TAILSCALE_SOCKET" >/dev/null 2>&1; then
    nohup "$TAILSCALED_BIN" \
        --socket="$TAILSCALE_SOCKET" \
        --statedir="$TAILSCALE_STATE_DIR" \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:${TAILSCALE_SOCKS5_PORT} \
        >> "$ULTRON_HOME/logs/tailscaled.log" 2>&1 &
    disown
fi

log "Waiting for the connection to actually come up ..."
TAILSCALED_READY=""
for i in $(seq 1 30); do
    if [[ -S "$TAILSCALE_SOCKET" ]]; then
        TAILSCALED_READY=1
        break
    fi
    sleep 1
done
[[ -n "$TAILSCALED_READY" ]] || die "tailscaled never became ready — check $ULTRON_HOME/logs/tailscaled.log"

if "$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" ip -4 >/dev/null 2>&1; then
    log "Already enlisted from before — resuming as $("$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" ip -4)"
elif [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
    log "No key on hand — sending a runner to fetch one from HQ ..."
    # No --retry-all-errors here on purpose: that flag needs curl 7.71+
    # (added 2020), and plenty of still-common Linux distros (this VPS's own
    # Ubuntu base included — ships 7.68.0) don't have it. It's silently an
    # "unknown option" on older curl, which exits nonzero before ever
    # trying the request — confirmed live during testing, not a guess.
    # Plain --retry still covers the connection-level failures that matter.
    TAILSCALE_AUTH_KEY="$(curl -fsSL --retry 5 --retry-delay 3 "$ORCHESTRATOR_JOIN_KEY_URL" 2>/dev/null || true)"
    if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
        log "WARNING: couldn't get a key (HQ didn't answer and none was provided). Everything"
        log "else is installed and ready — you just need to finish enlistment manually once"
        log "you've got a key:"
        log "  $TAILSCALE_BIN --socket=$TAILSCALE_SOCKET up --authkey=<key> --hostname=$NODE_HOSTNAME --accept-dns=false"
    else
        "$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" up \
            --authkey="$TAILSCALE_AUTH_KEY" \
            --hostname="$NODE_HOSTNAME" \
            --accept-dns=false
        log "Welcome to the Legion, $NODE_HOSTNAME. Your badge number is $("$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" ip -4)"
    fi
else
    "$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" up \
        --authkey="$TAILSCALE_AUTH_KEY" \
        --hostname="$NODE_HOSTNAME" \
        --accept-dns=false
    log "Welcome to the Legion, $NODE_HOSTNAME. Your badge number is $("$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" ip -4)"
fi

# ----------------------------------------------------------------------------
# 6. The launcher — starts every daemon (idempotent, pgrep-guarded), used
#    both right now and every time systemd brings this unit up again.
# ----------------------------------------------------------------------------
cat > "$ULTRON_HOME/bin/start_ultron.sh" <<STARTEOF
#!/usr/bin/env bash
ULTRON_HOME="$ULTRON_HOME"
TAILSCALE_SOCKET="$TAILSCALE_SOCKET"
TAILSCALE_STATE_DIR="$TAILSCALE_STATE_DIR"
TAILSCALED_BIN="$TAILSCALED_BIN"
LLAMA_RPC_BIN="$LLAMA_RPC_BIN"
LLAMA_BIN_DIR="$LLAMA_BIN_DIR"
RPC_PORT=$RPC_PORT
NODE_AGENT_PORT=$NODE_AGENT_PORT
HAVE_PYTHON3="$HAVE_PYTHON3"
LOG="\$ULTRON_HOME/logs/node.log"

echo "[start] \$(date) starting" >> "\$LOG"

if ! pgrep -f "tailscaled.*--socket=\$TAILSCALE_SOCKET" >/dev/null 2>&1; then
    nohup "\$TAILSCALED_BIN" \\
        --socket="\$TAILSCALE_SOCKET" \\
        --statedir="\$TAILSCALE_STATE_DIR" \\
        --tun=userspace-networking \\
        --socks5-server=127.0.0.1:${TAILSCALE_SOCKS5_PORT} \\
        >> "\$ULTRON_HOME/logs/tailscaled.log" 2>&1 &
    disown
fi

for i in \$(seq 1 30); do
    if "\$ULTRON_HOME/bin/tailscale/tailscale" --socket="\$TAILSCALE_SOCKET" ip -4 >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! pgrep -f "ggml-rpc-server.*-p \$RPC_PORT" >/dev/null 2>&1; then
    LD_LIBRARY_PATH="\$LLAMA_BIN_DIR" nohup "\$LLAMA_RPC_BIN" --host 127.0.0.1 -p "\$RPC_PORT" >> "\$LOG" 2>&1 &
    disown
fi

if [[ -n "\$HAVE_PYTHON3" ]] && ! pgrep -f "node_agent.py \$NODE_AGENT_PORT" >/dev/null 2>&1; then
    nohup python3 "\$ULTRON_HOME/bin/node_agent.py" "\$NODE_AGENT_PORT" >> "\$LOG" 2>&1 &
    disown
fi

if ! pgrep -f "bin/updater.sh" >/dev/null 2>&1; then
    nohup "\$ULTRON_HOME/bin/updater.sh" >> "\$LOG" 2>&1 &
    disown
fi

echo "[start] \$(date) started (rpc=\$RPC_PORT agent=\$NODE_AGENT_PORT)" >> "\$LOG"
STARTEOF
chmod +x "$ULTRON_HOME/bin/start_ultron.sh"

# ----------------------------------------------------------------------------
# 7. Surviving a reboot — a systemd --user unit, no root required. Falls
#    back to an XDG autostart entry too, belt and suspenders, since some
#    desktop setups don't run a systemd --user instance the same way.
# ----------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    log "Teaching this machine to report for duty automatically from now on ..."
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ultron-node.service" <<SERVICEEOF
[Unit]
Description=Ultron Legion node
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ULTRON_HOME/bin/start_ultron.sh
ExecStop=/usr/bin/pkill -f ggml-rpc-server
ExecStop=/usr/bin/pkill -f node_agent.py
ExecStop=/usr/bin/pkill -f bin/updater.sh

[Install]
WantedBy=default.target
SERVICEEOF
    systemctl --user daemon-reload
    systemctl --user enable ultron-node.service >/dev/null 2>&1 || true
    # Best-effort: lets the user systemd instance (and this service) keep
    # running even with nobody logged in, closer to "survives every
    # reboot" rather than just "starts again at next login". Not fatal if
    # this machine's polkit rules don't allow self-linger — the unit still
    # starts at login either way, just not before.
    loginctl enable-linger "$(whoami)" 2>/dev/null || log "Couldn't enable linger (needs elevated perms on this system) — node will still start automatically at every login, just not before one."
else
    log "No systemd found — skipping the reboot-persistence unit. Everything still works,"
    log "you'll just need to re-run start_ultron.sh yourself after a reboot:"
    log "  $ULTRON_HOME/bin/start_ultron.sh"
fi

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/ultron-node.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Ultron Legion node
Exec=$ULTRON_HOME/bin/start_ultron.sh
X-GNOME-Autostart-enabled=true
Hidden=false
Terminal=false
DESKTOPEOF

# ----------------------------------------------------------------------------
# 8. No point waiting for a reboot — report for duty right now
# ----------------------------------------------------------------------------
log "Skipping the paperwork, sending you straight to the front line ..."
"$ULTRON_HOME/bin/start_ultron.sh"

# Baseline copy for the updater to compare future checks against, fetched
# over the tailnet now that we're actually on it. If this fails, no harm —
# the updater just treats its first check as an update and re-applies the
# identical content once, a no-op in every way that matters.
curl -fsSL -m 15 --socks5-hostname "127.0.0.1:${TAILSCALE_SOCKS5_PORT}" "http://$ORCHESTRATOR_TAILNET_IP:8010/client-script/linux" -o "$ULTRON_HOME/bin/install_node_linux.sh" 2>/dev/null || true
chmod +x "$ULTRON_HOME/bin/install_node_linux.sh" 2>/dev/null || true

log "Done. This machine is in the Legion now — no further action needed, ever."
