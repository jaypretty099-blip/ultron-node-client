#!/usr/bin/env bash
#
# Welcome to the Ultron Legion — macOS edition. This Mac was going to spend
# today idling — this gives it a job instead.
#
# What you're about to run: it grabs a small llama.cpp worker (prebuilt
# where possible) and Tailscale (via Homebrew, the same open-source CLI
# build servers use — not the menu-bar app), gets this machine a quiet
# membership card on a private Tailscale network, and sets it up to report
# for duty automatically every time you log in. No sudo, no GUI, no drama.
#
# NOTE: unlike the Linux and Android versions of this script, this one has
# not been verified on a real Mac — there wasn't one available to test on
# while building it. The logic mirrors the Linux client closely (which
# *has* been verified live), and every command here is a standard,
# long-documented one, but if something's off, that's why. Please report
# back what happened.
#
# Enlistment line:
#   curl -fsSL https://raw.githubusercontent.com/<you>/ultron-node-client/main/install_node_macos.sh | bash
#
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================

ORCHESTRATOR_JOIN_KEY_URL="http://47.84.207.32:8010/join-key"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
ORCHESTRATOR_TAILNET_IP="100.73.49.17"
UPDATE_CHECK_INTERVAL_SECONDS=1800

ULTRON_HOME="$HOME/.ultron"
TAILSCALE_DIR="$HOME/.tailscale"
TAILSCALE_SOCKET="$TAILSCALE_DIR/tailscaled.sock"
TAILSCALE_STATE_DIR="$TAILSCALE_DIR/state"
TAILSCALE_SOCKS5_PORT=1055

LLAMA_BIN_DIR="$ULTRON_HOME/bin/llama"
LLAMA_RPC_BIN="$LLAMA_BIN_DIR/ggml-rpc-server"
# Same official release tag pinned everywhere else in this project — see
# the long comment in install_node_linux.sh for why this has to be the
# exact same commit as the VPS and every other client, not just "recent."
LLAMA_CPP_BUILD_TAG="b10839"
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_SRC_DIR="$ULTRON_HOME/src/llama.cpp"
LLAMA_CPP_PINNED_COMMIT="0cae43063cf15170e91a2ff4d034da0ecef4a1b2"

RPC_PORT=50052
NODE_AGENT_PORT=50053

NODE_HOSTNAME="ultron-macos-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

LOG_FILE="$ULTRON_HOME/logs/install.log"

declare -A LLAMA_SHA256=(
    [x64]="912b6bfe2f602a3336a0152daf1296b45fcbdd08c661f09556f688d590ce565e"
    [arm64]="88ea2d0c5c5a849bbc523022f4fcdd93ca858598c6850c8d6345610052cee574"
)

# ============================================================================

mkdir -p "$ULTRON_HOME"/{bin,logs,tmp} "$TAILSCALE_DIR" "$LLAMA_BIN_DIR" "$HOME/Library/LaunchAgents"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[install_node_macos] $*"; }
die() { echo "[install_node_macos] ERROR: $*" >&2; exit 1; }

log "Enlisting this Mac as $NODE_HOSTNAME. Stand by."

[[ "$(uname)" == "Darwin" ]] || die "This script is for macOS only — use install_node_linux.sh on Linux."

case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x64" ;;
    *) die "Unsupported CPU architecture $(uname -m)." ;;
esac
log "Detected architecture: $ARCH"

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required and wasn't found."
done

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for $file (got $actual, expected $expected) — refusing to run it."
}

# ----------------------------------------------------------------------------
# 1. Tailscale — via Homebrew, the same open-source binaries servers use.
#    Not the menu-bar app: no GUI, no NetworkExtension, nothing to click.
#    Run exactly like the Linux client — own socket, own state, userspace
#    networking — since tailscaled's flags are the same Go binary on every
#    OS, not a macOS-specific setup.
# ----------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required to fetch Tailscale's CLI build and wasn't found. Install it from https://brew.sh, then re-run this script. (This is the one thing here that needs a one-time manual step — Tailscale doesn't publish standalone macOS CLI binaries outside of Homebrew or their signed GUI app, and the GUI app isn't usable headlessly.)"
fi

if ! brew list tailscale >/dev/null 2>&1; then
    log "Installing Tailscale via Homebrew (CLI only, no GUI app, no sudo) ..."
    brew install tailscale >/dev/null
else
    log "Tailscale already installed via Homebrew — skipping"
fi
TAILSCALE_PREFIX="$(brew --prefix tailscale)"
TAILSCALE_BIN="$TAILSCALE_PREFIX/bin/tailscale"
TAILSCALED_BIN="$TAILSCALE_PREFIX/bin/tailscaled"
[[ -x "$TAILSCALE_BIN" && -x "$TAILSCALED_BIN" ]] || die "Homebrew installed tailscale but the binaries weren't where expected ($TAILSCALE_PREFIX/bin) — check 'brew info tailscale'."

# ----------------------------------------------------------------------------
# 2. llama.cpp RPC worker — official prebuilt binary at the pinned build,
#    falling back to a from-source build (via Homebrew's cmake + Xcode's
#    clang) if the prebuilt won't actually run. Same reasoning as Linux:
#    "the binary exists" and "the binary runs on this exact machine" turned
#    out to be different questions there, so this checks the second one
#    too instead of assuming.
# ----------------------------------------------------------------------------
llama_rpc_actually_works() {
    DYLD_LIBRARY_PATH="$LLAMA_BIN_DIR" "$LLAMA_RPC_BIN" --help >/dev/null 2>&1
}

if [[ -x "$LLAMA_RPC_BIN" ]] && llama_rpc_actually_works; then
    log "llama.cpp RPC worker already present and working — skipping"
else
    log "Fetching the llama.cpp RPC worker ($LLAMA_CPP_BUILD_TAG, $ARCH) — no compiling needed, if it runs here ..."
    LLAMA_TARBALL="$ULTRON_HOME/tmp/llama.tar.gz"
    curl -fsSL -o "$LLAMA_TARBALL" \
        "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_CPP_BUILD_TAG}/llama-${LLAMA_CPP_BUILD_TAG}-bin-macos-${ARCH}.tar.gz"
    verify_sha256 "$LLAMA_TARBALL" "${LLAMA_SHA256[$ARCH]}"
    rm -rf "$LLAMA_BIN_DIR"
    tar xzf "$LLAMA_TARBALL" -C "$ULTRON_HOME/tmp"
    mv "$ULTRON_HOME/tmp/llama-${LLAMA_CPP_BUILD_TAG}" "$LLAMA_BIN_DIR"
    chmod +x "$LLAMA_RPC_BIN"
    rm -f "$LLAMA_TARBALL"

    if llama_rpc_actually_works; then
        log "Prebuilt binary runs fine here — no compiler needed."
    else
        log "Prebuilt binary doesn't run on this Mac. Falling back to building it from source"
        log "at the same pinned commit — slower, but works anywhere."
        command -v cmake >/dev/null 2>&1 || die "cmake is required to build from source and wasn't found. Install it with 'brew install cmake' and re-run this script."
        command -v clang++ >/dev/null 2>&1 || die "A C++ compiler is required to build from source and none was found. Install Xcode Command Line Tools ('xcode-select --install') and re-run this script."
        if [[ ! -d "$LLAMA_CPP_SRC_DIR/.git" ]]; then
            rm -rf "$LLAMA_CPP_SRC_DIR"
            mkdir -p "$LLAMA_CPP_SRC_DIR"
            git init -q "$LLAMA_CPP_SRC_DIR"
            git -C "$LLAMA_CPP_SRC_DIR" remote add origin "$LLAMA_CPP_REPO"
        fi
        git -C "$LLAMA_CPP_SRC_DIR" fetch --depth 1 origin "$LLAMA_CPP_PINNED_COMMIT"
        git -C "$LLAMA_CPP_SRC_DIR" checkout -q FETCH_HEAD
        cmake -S "$LLAMA_CPP_SRC_DIR" -B "$LLAMA_CPP_SRC_DIR/build" -DGGML_RPC=ON -DCMAKE_BUILD_TYPE=Release
        cmake --build "$LLAMA_CPP_SRC_DIR/build" --target ggml-rpc-server -j"$(sysctl -n hw.ncpu)"
        rm -rf "$LLAMA_BIN_DIR"
        mkdir -p "$LLAMA_BIN_DIR"
        cp "$LLAMA_CPP_SRC_DIR/build/bin/ggml-rpc-server" "$LLAMA_RPC_BIN"
        cp "$LLAMA_CPP_SRC_DIR"/build/bin/*.dylib "$LLAMA_BIN_DIR/" 2>/dev/null || true
        llama_rpc_actually_works || die "Built from source but it still won't run — check $ULTRON_HOME/logs/install.log"
        log "Source build works."
    fi
fi

# ----------------------------------------------------------------------------
# 3. The world's smallest snitch — reports free RAM back to HQ, macOS-style
#    (no /proc here, so this shells out to sysctl + vm_stat instead).
#    Best-effort: if python3 isn't on this Mac, the RPC worker still runs
#    fine, HQ just won't count this node's RAM toward big-model placement.
# ----------------------------------------------------------------------------
HAVE_PYTHON3=""
if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON3=1
    cat > "$ULTRON_HOME/bin/node_agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""The world's smallest snitch, macOS edition: reports how much RAM (and
CPU) this Mac has free so HQ knows whether to trust it with real work.
Loopback-only."""
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 50053


def read_meminfo():
    total_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
    page_size = int(subprocess.check_output(["sysctl", "-n", "hw.pagesize"]).strip())
    vm_stat_out = subprocess.check_output(["vm_stat"]).decode()
    pages = {}
    for line in vm_stat_out.splitlines():
        m = re.match(r"Pages (free|inactive|speculative):\s+(\d+)\.", line)
        if m:
            pages[m.group(1)] = int(m.group(2))
    available_pages = pages.get("free", 0) + pages.get("inactive", 0) + pages.get("speculative", 0)
    return total_bytes, available_pages * page_size


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/meminfo":
            self.send_response(404)
            self.end_headers()
            return
        total_bytes, available_bytes = read_meminfo()
        body = json.dumps({
            "total_bytes": total_bytes,
            "available_bytes": available_bytes,
            "cpu_count": os.cpu_count(),
        }).encode()
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
    log "but HQ won't get a RAM report from it."
fi

# ----------------------------------------------------------------------------
# 4. The night watch — same hash-gated update pattern as every other
#    platform, hitting the macos-specific endpoints.
# ----------------------------------------------------------------------------
cat > "$ULTRON_HOME/bin/updater.sh" <<UPDATEEOF
#!/usr/bin/env bash
ULTRON_HOME="$ULTRON_HOME"
ORCHESTRATOR_TAILNET_IP="$ORCHESTRATOR_TAILNET_IP"
CHECK_INTERVAL="$UPDATE_CHECK_INTERVAL_SECONDS"
LOCAL_SCRIPT="\$ULTRON_HOME/bin/install_node_macos.sh"
LOG="\$ULTRON_HOME/logs/updater.log"
TS_PROXY="127.0.0.1:${TAILSCALE_SOCKS5_PORT}"

log() { echo "[updater] \$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG"; }

while true; do
    sleep "\$CHECK_INTERVAL"

    REMOTE_HASH="\$(curl -fsS -m 15 --socks5-hostname "\$TS_PROXY" "http://\$ORCHESTRATOR_TAILNET_IP:8010/client-script-hash/macos" 2>/dev/null || true)"
    if [[ -z "\$REMOTE_HASH" ]]; then
        continue
    fi

    LOCAL_HASH=""
    if [[ -f "\$LOCAL_SCRIPT" ]]; then
        LOCAL_HASH="\$(shasum -a 256 "\$LOCAL_SCRIPT" 2>/dev/null | awk '{print \$1}')"
    fi

    if [[ "\$REMOTE_HASH" == "\$LOCAL_HASH" ]]; then
        continue
    fi

    log "Update available (was \$LOCAL_HASH, now \$REMOTE_HASH) — applying quietly"
    NEW_SCRIPT="\$ULTRON_HOME/tmp/install_node_macos.sh.new"
    if ! curl -fsS -m 60 --socks5-hostname "\$TS_PROXY" "http://\$ORCHESTRATOR_TAILNET_IP:8010/client-script/macos" -o "\$NEW_SCRIPT" 2>>"\$LOG"; then
        log "Download failed, will try again next cycle"
        continue
    fi

    DOWNLOADED_HASH="\$(shasum -a 256 "\$NEW_SCRIPT" 2>/dev/null | awk '{print \$1}')"
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
done
UPDATEEOF
chmod +x "$ULTRON_HOME/bin/updater.sh"

# ----------------------------------------------------------------------------
# 5. Getting this Mac its membership card (Tailscale, userspace, no sudo)
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
# 6. The launcher — starts every daemon (idempotent, pgrep-guarded)
# ----------------------------------------------------------------------------
cat > "$ULTRON_HOME/bin/start_ultron.sh" <<STARTEOF
#!/usr/bin/env bash
ULTRON_HOME="$ULTRON_HOME"
TAILSCALE_SOCKET="$TAILSCALE_SOCKET"
TAILSCALE_STATE_DIR="$TAILSCALE_STATE_DIR"
TAILSCALED_BIN="$TAILSCALED_BIN"
TAILSCALE_BIN="$TAILSCALE_BIN"
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
    if "\$TAILSCALE_BIN" --socket="\$TAILSCALE_SOCKET" ip -4 >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! pgrep -f "ggml-rpc-server.*-p \$RPC_PORT" >/dev/null 2>&1; then
    DYLD_LIBRARY_PATH="\$LLAMA_BIN_DIR" nohup "\$LLAMA_RPC_BIN" --host 127.0.0.1 -p "\$RPC_PORT" >> "\$LOG" 2>&1 &
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
# 7. Surviving a reboot — a launchd LaunchAgent, no sudo required. Starts
#    at every login, same tradeoff as the Linux client without linger
#    enabled: "every login" rather than "before any login at all", which
#    is the realistic case for a personal Mac anyway.
# ----------------------------------------------------------------------------
log "Teaching this Mac to report for duty automatically from now on ..."
PLIST="$HOME/Library/LaunchAgents/com.ultron.node.plist"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ultron.node</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ULTRON_HOME/bin/start_ultron.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$ULTRON_HOME/logs/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$ULTRON_HOME/logs/launchd.log</string>
</dict>
</plist>
PLISTEOF
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

# ----------------------------------------------------------------------------
# 8. No point waiting for a reboot — report for duty right now
# ----------------------------------------------------------------------------
log "Skipping the paperwork, sending you straight to the front line ..."
launchctl start com.ultron.node

curl -fsSL -m 15 --socks5-hostname "127.0.0.1:${TAILSCALE_SOCKS5_PORT}" "http://$ORCHESTRATOR_TAILNET_IP:8010/client-script/macos" -o "$ULTRON_HOME/bin/install_node_macos.sh" 2>/dev/null || true
chmod +x "$ULTRON_HOME/bin/install_node_macos.sh" 2>/dev/null || true

log "Done. This Mac is in the Legion now — no further action needed, ever."
