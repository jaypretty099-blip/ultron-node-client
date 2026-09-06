#!/data/data/com.termux/files/usr/bin/bash
#
# Ultron volunteer node installer (Termux / Android).
#
# Turns a bare Termux install into a persistent llama.cpp RPC worker that
# joins your Tailscale mesh and survives reboots via Termux:Boot.
#
# Run with:
#   curl -fsSL https://raw.githubusercontent.com/<you>/ultron-node-client/main/install_node.sh | bash
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================

# Fill this in before distributing this script. Left blank on purpose: this
# repo is public, and a live Tailscale auth key committed to git history
# would let anyone join the tailnet. Distribute the real key to supporters
# out-of-band (DM, a --tags-scoped reusable key, etc), not via this file.
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-REPLACE_WITH_YOUR_TAILSCALE_AUTH_KEY}"

ULTRON_HOME="$HOME/.ultron"
TAILSCALE_DIR="$HOME/.tailscale"
TAILSCALE_SOCKET="$TAILSCALE_DIR/tailscaled.sock"
TAILSCALE_STATE_DIR="$TAILSCALE_DIR/state"
TAILSCALE_SOCKS5_PORT=1055

LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_DIR="$ULTRON_HOME/src/llama.cpp"

# Both bind to loopback only. In --tun=userspace-networking mode there is no
# real network interface carrying the tailscale IP, so nothing could bind to
# it directly anyway — tailscaled's own netstack forwards inbound tailnet
# connections addressed to <this-node-ip>:PORT to 127.0.0.1:PORT. Binding to
# loopback also means neither service is reachable except via the tailnet,
# which matters a lot for the RPC server: upstream explicitly warns it has no
# auth and must never be exposed on an open network.
RPC_PORT=50052
NODE_AGENT_PORT=50053

NODE_HOSTNAME="ultron-node-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

LOG_FILE="$ULTRON_HOME/logs/install.log"

# ============================================================================

mkdir -p "$ULTRON_HOME"/{bin,logs,config} "$HOME/.termux/boot" "$TAILSCALE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[install_node] $*"; }
die() { echo "[install_node] ERROR: $*" >&2; exit 1; }

log "Starting Ultron node install as $NODE_HOSTNAME"

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
log "Installing packages ..."
pkg update -y
pkg install -y git cmake clang make python curl proot termux-services iproute2

if ! command -v tailscale >/dev/null 2>&1; then
    log "tailscale not available via pkg, falling back to the official static binary"
    case "$(uname -m)" in
        aarch64) TS_ARCH="arm64" ;;
        armv7l|armv8l) TS_ARCH="arm" ;;
        x86_64) TS_ARCH="amd64" ;;
        i686) TS_ARCH="386" ;;
        *) die "unsupported architecture $(uname -m) for Tailscale static binary" ;;
    esac
    TS_VERSION="$(curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors https://pkgs.tailscale.com/stable/?mode=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["TarballsVersion"])' 2>/dev/null || echo "")"
    if [[ -z "$TS_VERSION" ]]; then
        die "could not determine latest Tailscale version (network may be unstable — re-run this script to retry); or install tailscale manually"
    fi
    TS_TARBALL="tailscale_${TS_VERSION}_${TS_ARCH}.tgz"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/${TS_TARBALL}"
    tar -xzf /tmp/tailscale.tgz -C /tmp
    cp "/tmp/tailscale_${TS_VERSION}_${TS_ARCH}/tailscale" "/tmp/tailscale_${TS_VERSION}_${TS_ARCH}/tailscaled" "$ULTRON_HOME/bin/"
    chmod +x "$ULTRON_HOME/bin/tailscale" "$ULTRON_HOME/bin/tailscaled"
    rm -rf /tmp/tailscale.tgz "/tmp/tailscale_${TS_VERSION}_${TS_ARCH}"
    export PATH="$ULTRON_HOME/bin:$PATH"
fi

TAILSCALE_BIN="$(command -v tailscale || echo "$ULTRON_HOME/bin/tailscale")"
TAILSCALED_BIN="$(command -v tailscaled || echo "$ULTRON_HOME/bin/tailscaled")"

# ----------------------------------------------------------------------------
# 2. Python venv + node agent (reports free RAM; ggml-rpc-server has no
#    remote introspection API of its own, so the orchestrator polls this
#    instead)
# ----------------------------------------------------------------------------
log "Setting up Python venv ..."
python -m venv "$ULTRON_HOME/venv"

cat > "$ULTRON_HOME/bin/node_agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""Minimal stdlib-only HTTP endpoint reporting free RAM, polled by the
Ultron orchestrator to decide which model the cluster can afford to run.
Binds to loopback only — see install_node.sh for why."""
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
        pass  # keep node.log focused on the RPC server, not health-check noise


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

# ----------------------------------------------------------------------------
# 3. Build ggml-rpc-server (llama.cpp RPC backend, CPU-only — no exo)
# ----------------------------------------------------------------------------
if [[ ! -x "$ULTRON_HOME/bin/ggml-rpc-server" ]]; then
    log "Building ggml-rpc-server (this can take a while on-device) ..."
    if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
        git clone --depth 1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
    fi
    cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_DIR/build" -DGGML_RPC=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "$LLAMA_CPP_DIR/build" --target ggml-rpc-server -j"$(nproc)"
    cp "$LLAMA_CPP_DIR/build/bin/ggml-rpc-server" "$ULTRON_HOME/bin/ggml-rpc-server"
else
    log "ggml-rpc-server already built, skipping"
fi

# ----------------------------------------------------------------------------
# 4. User-space Tailscale
# ----------------------------------------------------------------------------
log "Starting tailscaled (userspace networking) ..."
mkdir -p "$TAILSCALE_STATE_DIR"

if ! pgrep -f "tailscaled.*--socket=$TAILSCALE_SOCKET" >/dev/null 2>&1; then
    nohup "$TAILSCALED_BIN" \
        --socket="$TAILSCALE_SOCKET" \
        --statedir="$TAILSCALE_STATE_DIR" \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:${TAILSCALE_SOCKS5_PORT} \
        >> "$ULTRON_HOME/logs/tailscaled.log" 2>&1 &
    sleep 2
fi

if [[ "$TAILSCALE_AUTH_KEY" == "REPLACE_WITH_YOUR_TAILSCALE_AUTH_KEY" ]]; then
    log "WARNING: TAILSCALE_AUTH_KEY is still a placeholder."
    log "Set it via: TAILSCALE_AUTH_KEY=tskey-... bash install_node.sh"
    log "or export it before piping this script into bash. Skipping 'tailscale up' for now —"
    log "run it manually once you have a key:"
    log "  $TAILSCALE_BIN --socket=$TAILSCALE_SOCKET up --authkey=<key> --hostname=$NODE_HOSTNAME --accept-dns=false"
else
    "$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" up \
        --authkey="$TAILSCALE_AUTH_KEY" \
        --hostname="$NODE_HOSTNAME" \
        --accept-dns=false
    log "Joined tailnet as $NODE_HOSTNAME: $("$TAILSCALE_BIN" --socket="$TAILSCALE_SOCKET" ip -4)"
fi

# ----------------------------------------------------------------------------
# 5. Termux:Boot integration
# ----------------------------------------------------------------------------
log "Installing Termux:Boot start script ..."
cat > "$HOME/.termux/boot/start_ultron.sh" <<BOOTEOF
#!/data/data/com.termux/files/usr/bin/bash
# Launched by the Termux:Boot app on device boot. Requires the separate
# Termux:Boot app (installed from F-Droid) to be installed and opened once.
termux-wake-lock

ULTRON_HOME="$ULTRON_HOME"
TAILSCALE_SOCKET="$TAILSCALE_SOCKET"
TAILSCALE_STATE_DIR="$TAILSCALE_STATE_DIR"
TAILSCALED_BIN="$TAILSCALED_BIN"
RPC_PORT=$RPC_PORT
NODE_AGENT_PORT=$NODE_AGENT_PORT
LOG="\$ULTRON_HOME/logs/node.log"

echo "[boot] \$(date) starting" >> "\$LOG"

if ! pgrep -f "tailscaled.*--socket=\$TAILSCALE_SOCKET" >/dev/null 2>&1; then
    nohup "\$TAILSCALED_BIN" \\
        --socket="\$TAILSCALE_SOCKET" \\
        --statedir="\$TAILSCALE_STATE_DIR" \\
        --tun=userspace-networking \\
        --socks5-server=127.0.0.1:${TAILSCALE_SOCKS5_PORT} \\
        >> "\$ULTRON_HOME/logs/tailscaled.log" 2>&1 &
fi

for i in \$(seq 1 30); do
    if "\$ULTRON_HOME/bin/tailscale" --socket="\$TAILSCALE_SOCKET" ip -4 >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! pgrep -f "ggml-rpc-server.*-p \$RPC_PORT" >/dev/null 2>&1; then
    nohup "\$ULTRON_HOME/bin/ggml-rpc-server" --host 127.0.0.1 -p "\$RPC_PORT" >> "\$LOG" 2>&1 &
fi

if ! pgrep -f "node_agent.py \$NODE_AGENT_PORT" >/dev/null 2>&1; then
    nohup "\$ULTRON_HOME/venv/bin/python3" "\$ULTRON_HOME/bin/node_agent.py" "\$NODE_AGENT_PORT" >> "\$LOG" 2>&1 &
fi

echo "[boot] \$(date) started (rpc=\$RPC_PORT agent=\$NODE_AGENT_PORT)" >> "\$LOG"
BOOTEOF
chmod +x "$HOME/.termux/boot/start_ultron.sh"

# ----------------------------------------------------------------------------
# 6. Bring the node up now, don't just wait for the next reboot
# ----------------------------------------------------------------------------
log "Starting worker services now ..."
"$HOME/.termux/boot/start_ultron.sh"

log "Done. Node hostname: $NODE_HOSTNAME"
log "Logs: $ULTRON_HOME/logs/node.log"
log "If you haven't already: install the Termux:Boot app from F-Droid and open it once,"
log "otherwise this node won't restart itself after your phone reboots."
