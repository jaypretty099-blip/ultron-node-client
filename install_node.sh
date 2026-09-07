#!/data/data/com.termux/files/usr/bin/bash
#
# Welcome to the Ultron Legion. Your phone was going to spend today doing
# nothing in particular — this gives it a job instead.
#
# What you're about to run: it installs a small llama.cpp worker, gets your
# phone a quiet membership card on a private Tailscale network, and sets it
# up to report for duty automatically after every reboot. No drama, no root,
# no permanent tattoo. Just spare CPU cycles doing something useful.
#
# Enlistment line:
#   curl -fsSL https://raw.githubusercontent.com/<you>/ultron-node-client/main/install_node.sh | bash
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================

# You will not find a secret key hiding in this file. We thought about it,
# then remembered the internet never forgets and bots read public repos for
# breakfast. So instead: if you haven't already set TAILSCALE_AUTH_KEY
# yourself, this script politely asks the mothership for a fresh one at
# install time. One-time use, nothing kept lying around, nothing for anyone
# to go digging for later.
ORCHESTRATOR_JOIN_KEY_URL="http://47.84.207.32:8000/join-key"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

ULTRON_HOME="$HOME/.ultron"
TAILSCALE_DIR="$HOME/.tailscale"
TAILSCALE_SOCKET="$TAILSCALE_DIR/tailscaled.sock"
TAILSCALE_STATE_DIR="$TAILSCALE_DIR/state"
TAILSCALE_SOCKS5_PORT=1055

LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_CPP_DIR="$ULTRON_HOME/src/llama.cpp"

# Both of these only answer to the tailnet, never the open internet. The RPC
# worker in particular has zero authentication by design (llama.cpp's own
# docs say so, in bold), so keeping it strictly on the private network isn't
# optional paranoia — it's the only thing standing between "helpful volunteer
# node" and "stranger's compute genie."
RPC_PORT=50052
NODE_AGENT_PORT=50053

NODE_HOSTNAME="ultron-node-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

LOG_FILE="$ULTRON_HOME/logs/install.log"

# ============================================================================

mkdir -p "$ULTRON_HOME"/{bin,logs,config,tmp} "$HOME/.termux/boot" "$TAILSCALE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[install_node] $*"; }
die() { echo "[install_node] ERROR: $*" >&2; exit 1; }

log "Enlisting this phone as $NODE_HOSTNAME. Stand by."

# ----------------------------------------------------------------------------
# 1. Packages — the boring-but-essential gear before basic training
# ----------------------------------------------------------------------------
log "Requisitioning supplies (a compiler, some tools, the usual) ..."
pkg update -y
pkg install -y git cmake clang make python curl golang termux-services iproute2

if [[ ! -x "$ULTRON_HOME/bin/tailscaled" ]]; then
    # Termux doesn't stock Tailscale, and — this took a while to track down —
    # the prebuilt Linux binary Tailscale publishes doesn't actually work
    # here: its network monitor needs a netlink route-table read that
    # Android's security policy denies to every unprivileged app, no
    # exceptions. Not a Termux quirk, not this phone, just how Android works.
    # Tailscale's own Android app avoids this by building for GOOS=android
    # instead of GOOS=linux, which swaps in a safe, netlink-free code path —
    # and Termux's own Go toolchain already targets GOOS=android by default.
    # So: build it ourselves, the same way the real app does, instead of
    # downloading a binary that's quietly broken for this exact use case.
    log "Building Tailscale from source (the prebuilt one doesn't work on Android — long story,"
    log "ask me sometime). This is the other slow part."
    TS_SRC_DIR="$ULTRON_HOME/src/tailscale"
    if [[ ! -d "$TS_SRC_DIR" ]]; then
        git clone --depth 1 https://github.com/tailscale/tailscale.git "$TS_SRC_DIR"
    fi
    # These ts_omit_* tags skip features we don't need (SSH server, system
    # tray icon, Synology cert helper, CLI connection diagnostics, ACME,
    # Taildrop file sharing) — partly to dodge build-constraint gaps where a
    # feature's "linux-only" tag forgot to also exclude android, and partly
    # because ts_omit_taildrop sidesteps a real nil-pointer panic on login
    # in this build (feature/taildrop's onChangeProfile — confirmed crash on
    # a real device, not present at all once the feature is left out).
    TS_BUILD_TAGS="ts_omit_ssh,ts_omit_systray,ts_omit_synology,ts_omit_cliconndiag,ts_omit_acme,ts_omit_taildrop"
    (cd "$TS_SRC_DIR" && go build -tags "$TS_BUILD_TAGS" -o "$ULTRON_HOME/bin/tailscaled" ./cmd/tailscaled)
    (cd "$TS_SRC_DIR" && go build -tags "$TS_BUILD_TAGS" -o "$ULTRON_HOME/bin/tailscale" ./cmd/tailscale)
else
    log "Already built Tailscale from source — skipping"
fi

export PATH="$ULTRON_HOME/bin:$PATH"
TAILSCALE_BIN="$ULTRON_HOME/bin/tailscale"
TAILSCALED_BIN="$ULTRON_HOME/bin/tailscaled"

# ----------------------------------------------------------------------------
# 2. Python venv + the world's smallest snitch (reports free RAM back to HQ,
#    since the RPC worker itself is the strong-and-silent type)
# ----------------------------------------------------------------------------
log "Setting up a Python venv (small, tidy, keeps to itself) ..."
python -m venv "$ULTRON_HOME/venv"

cat > "$ULTRON_HOME/bin/node_agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""The world's smallest snitch: reports how much RAM this phone has free so
HQ knows whether to trust it with real work. Loopback-only — see
install_node.sh for why we're precious about that."""
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
# 3. Basic training: compile the actual worker software
# ----------------------------------------------------------------------------
if [[ ! -x "$ULTRON_HOME/bin/ggml-rpc-server" ]]; then
    log "Compiling your phone's new job description. This is the slow part — go make tea ..."
    if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
        git clone --depth 1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
    fi
    cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_DIR/build" -DGGML_RPC=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "$LLAMA_CPP_DIR/build" --target ggml-rpc-server -j"$(nproc)"
    cp "$LLAMA_CPP_DIR/build/bin/ggml-rpc-server" "$ULTRON_HOME/bin/ggml-rpc-server"
else
    log "Already trained for this — skipping straight to deployment"
fi

# ----------------------------------------------------------------------------
# 4. Getting your phone its membership card (Tailscale, running quietly in
#    the background, no root required)
# ----------------------------------------------------------------------------
log "Waking up the private network connection ..."
mkdir -p "$TAILSCALE_STATE_DIR"

if pgrep -f "tailscaled.*--socket=$TAILSCALE_SOCKET" >/dev/null 2>&1 && [[ ! -S "$TAILSCALE_SOCKET" ]]; then
    # A process matching this command line exists, but its socket doesn't —
    # that's a stale/orphaned daemon (crashed, killed by the OS, whatever),
    # not a healthy one. Trusting pgrep alone here would make us wait
    # forever for a socket that's never coming. Clear it out and start over.
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
fi

# A flat "sleep 2" here used to bite us: on a slow moment the daemon's
# socket isn't ready yet, and the first "tailscale up" hits it mid-boot and
# fails with a bare "unexpected EOF" — confirmed on a real device. Poll for
# readiness instead of guessing at a fixed delay.
log "Waiting for the connection to actually come up ..."
TAILSCALED_READY=""
for i in $(seq 1 30); do
    # Socket existing, not "status" succeeding: status legitimately returns
    # non-zero ("Logged out") before we've authenticated, which isn't the
    # same thing as "daemon not ready yet" — checking that instead would
    # spin the full 30s and fail every single time. The socket appearing
    # means the daemon is listening, whatever our login state is.
    if [[ -S "$TAILSCALE_SOCKET" ]]; then
        TAILSCALED_READY=1
        break
    fi
    sleep 1
done
if [[ -z "$TAILSCALED_READY" ]]; then
    die "tailscaled never became ready — check $ULTRON_HOME/logs/tailscaled.log"
fi

if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
    log "No key on hand — sending a runner to fetch one from HQ ..."
    TAILSCALE_AUTH_KEY="$(curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$ORCHESTRATOR_JOIN_KEY_URL" 2>/dev/null || true)"
fi

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

# ----------------------------------------------------------------------------
# 5. Making sure you show up for duty even after your phone reboots
# ----------------------------------------------------------------------------
log "Teaching this phone to report for duty automatically from now on ..."
cat > "$HOME/.termux/boot/start_ultron.sh" <<BOOTEOF
#!/data/data/com.termux/files/usr/bin/bash
# The Legion's morning roll call. Termux:Boot runs this every time your
# phone wakes up, so your node clocks back in without you doing a thing.
# (Needs the Termux:Boot app from F-Droid, opened once, to be allowed to fire.)
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
# 6. No point making you wait for a reboot — report for duty right now
# ----------------------------------------------------------------------------
log "Skipping the paperwork, sending you straight to the front line ..."
"$HOME/.termux/boot/start_ultron.sh"

log "You're in. Node: $NODE_HOSTNAME"
log "Watch it work: $ULTRON_HOME/logs/node.log"
log "One last thing: install the Termux:Boot app from F-Droid and open it once if you"
log "haven't — otherwise this node goes AWOL every time your phone reboots."
