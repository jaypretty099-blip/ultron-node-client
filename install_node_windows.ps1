# Welcome to the Ultron Legion — Windows edition. This PC was going to
# spend today idling — this gives it a job instead.
#
# What you're about to run: it grabs a small llama.cpp worker (official
# prebuilt binary) and a purpose-built, admin-free Tailscale client, gets
# this machine a quiet membership card on a private Tailscale network, and
# sets it up to report for duty automatically every time you log in.
# No admin rights, no installer wizard, no tray icon — just a background
# process.
#
# NOTE: unlike the Linux client (verified live on a real machine while
# building this), this one has not been run on a real Windows PC — there
# wasn't one available to test on. The logic mirrors the Linux client
# closely and every mechanism here (named pipes, Task Scheduler,
# HttpListener) is a standard, long-documented Windows feature, but please
# report back what actually happens when you run it.
#
# A second, more particular note: Tailscale's own Windows installer needs
# admin rights and a kernel driver (WinTun), which conflicts with "run one
# command, no interference." So the Tailscale binaries this script fetches
# are not Tailscale's official installer — they're built from Tailscale's
# own public source at the exact same pinned commit already used by every
# other Ultron client, just compiled ahead of time (from the same source
# ggml-org... no, tailscale/tailscale — see below) rather than on your
# machine, using the same feature-trimming build tags the Android client
# uses. They are unsigned. Windows Defender or SmartScreen may flag an
# unrecognized unsigned .exe that opens network connections — that's a
# real possibility this script can't route around, only disclose.
#
# Enlistment line (PowerShell):
#   irm https://raw.githubusercontent.com/<you>/ultron-node-client/main/install_node_windows.ps1 | iex
#
$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIG
# ============================================================================

$OrchestratorJoinKeyUrl = "http://47.84.207.32:8010/join-key"
$TailscaleAuthKey = $env:TAILSCALE_AUTH_KEY
$OrchestratorTailnetIp = "100.73.49.17"
$OrchestratorGatewayPort = 8010
$UpdateCheckIntervalSeconds = 1800

$UltronHome = Join-Path $env:USERPROFILE ".ultron"
$TailscaleDir = Join-Path $env:USERPROFILE ".tailscale"
$TailscaleStateDir = Join-Path $TailscaleDir "state"
# A custom named pipe, not tailscaled's Windows default
# (\\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled) — that
# default lives under a namespace prefix Windows itself restricts to the
# Administrators group at the object-manager level, regardless of what
# tailscaled asks for. A differently-named pipe doesn't inherit that
# restriction, which is what makes running any of this without admin
# rights possible at all. Confirmed via reading tailscale's own source
# (paths.DefaultTailscaledSocket) rather than assumed.
$TailscalePipe = "\\.\pipe\ultron-tailscaled"
$TailscaleSocksPort = 1055
$TailscaleBinDir = Join-Path $UltronHome "bin\tailscale"
$TailscaleExe = Join-Path $TailscaleBinDir "tailscale_amd64.exe"
$TailscaledExe = Join-Path $TailscaleBinDir "tailscaled_amd64.exe"
# Hosted from this same repo — see the header note on why these aren't
# Tailscale's own official binaries.
$TailscaleBinBaseUrl = "https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/bin/windows"

$LlamaBinDir = Join-Path $UltronHome "bin\llama"
$LlamaRpcExe = Join-Path $LlamaBinDir "ggml-rpc-server.exe"
# Same official release tag pinned everywhere else in this project — see
# the long comment in install_node_linux.sh for why this has to be the
# exact same commit as the VPS and every other client, not just "recent."
$LlamaCppBuildTag = "b10839"
$LlamaSha256 = "28829ed31a1555f241aef02664305f3bcdbffb611e1eb178b130a2a38e98f3a6"

$RpcPort = 50052
$NodeAgentPort = 50053

$rand = -join ((1..4) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
$NodeHostname = "ultron-windows-$rand"

$LogFile = Join-Path $UltronHome "logs\install.log"

$TailscaledSha256 = "430874683a66eba171407efe1a916d626e556811f15e7311792659b7be465181"
$TailscaleCliSha256 = "f79df7a0f4f5632f5e8bb82a96d3887e9853d7cca3cc0aef9854a16e20290abb"

# ============================================================================

New-Item -ItemType Directory -Force -Path (Join-Path $UltronHome "bin"), (Join-Path $UltronHome "logs"), (Join-Path $UltronHome "tmp"), $TailscaleBinDir, $LlamaBinDir, $TailscaleStateDir | Out-Null

function Log($msg) {
    $line = "[install_node_windows] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}
function Die($msg) {
    Log "ERROR: $msg"
    exit 1
}

Log "Enlisting this PC as $NodeHostname. Stand by."

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    Die "This script currently only supports 64-bit x86 Windows (AMD64). Detected: $($env:PROCESSOR_ARCHITECTURE)."
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Die "curl.exe is required and wasn't found. It ships with Windows 10 1803+ and Windows 11 by default — if it's genuinely missing, install it and re-run."
}

function Test-Sha256($Path, $Expected) {
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Expected.ToLower()) {
        Die "checksum mismatch for $Path (got $actual, expected $Expected) — refusing to run it."
    }
}

# ----------------------------------------------------------------------------
# 1. Tailscale — self-built, sha256-pinned binaries (see header note). Run
#    exactly like the Linux/macOS clients: own pipe, own state dir,
#    userspace networking, no admin, no driver, no tray icon.
# ----------------------------------------------------------------------------
if (-not (Test-Path $TailscaledExe)) {
    Log "Fetching Tailscale (amd64) ..."
    curl.exe -fsSL -o "$TailscaledExe" "$TailscaleBinBaseUrl/tailscaled_amd64.exe"
    curl.exe -fsSL -o "$TailscaleExe" "$TailscaleBinBaseUrl/tailscale_amd64.exe"
    Test-Sha256 $TailscaledExe $TailscaledSha256
    Test-Sha256 $TailscaleExe $TailscaleCliSha256
} else {
    Log "Tailscale already present — skipping download"
}

# ----------------------------------------------------------------------------
# 2. llama.cpp RPC worker — official prebuilt binary, sha256-pinned. No
#    from-source fallback on Windows (no compiler assumed present) — if
#    this doesn't run, the error will be clear rather than silent.
# ----------------------------------------------------------------------------
function Test-LlamaRpcWorks {
    try {
        & $LlamaRpcExe --help *> $null
        return $true
    } catch {
        return $false
    }
}

if (-not ((Test-Path $LlamaRpcExe) -and (Test-LlamaRpcWorks))) {
    Log "Fetching the llama.cpp RPC worker ($LlamaCppBuildTag, amd64) ..."
    $llamaZip = Join-Path $UltronHome "tmp\llama.zip"
    curl.exe -fsSL -o "$llamaZip" "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaCppBuildTag/llama-$LlamaCppBuildTag-bin-win-cpu-x64.zip"
    Test-Sha256 $llamaZip $LlamaSha256
    if (Test-Path $LlamaBinDir) { Remove-Item -Recurse -Force $LlamaBinDir }
    New-Item -ItemType Directory -Force -Path $LlamaBinDir | Out-Null
    Expand-Archive -Path $llamaZip -DestinationPath $LlamaBinDir -Force
    Remove-Item -Force $llamaZip

    if (-not (Test-LlamaRpcWorks)) {
        Die "Downloaded the llama.cpp RPC worker but it won't run on this PC — check $LogFile. (No source-build fallback exists for Windows yet; if you can, please report this.)"
    }
    Log "Prebuilt binary runs fine here."
} else {
    Log "llama.cpp RPC worker already present and working — skipping"
}

# ----------------------------------------------------------------------------
# 3. The world's smallest snitch — reports free RAM back to HQ. PowerShell
#    native, no Python dependency needed on this platform at all.
# ----------------------------------------------------------------------------
$NodeAgentScript = Join-Path $UltronHome "bin\node_agent.ps1"
@"
param([int]`$Port = $NodeAgentPort)
`$listener = New-Object System.Net.HttpListener
# Binding to literal 'localhost' (not '+' or a hostname) is the one case
# HTTP.sys exempts from needing a URL ACL reservation — which is what
# makes this work without admin rights at all.
`$listener.Prefixes.Add("http://localhost:`$Port/")
`$listener.Start()
while (`$listener.IsListening) {
    `$context = `$listener.GetContext()
    `$request = `$context.Request
    `$response = `$context.Response
    if (`$request.Url.AbsolutePath -eq "/meminfo") {
        `$os = Get-CimInstance Win32_OperatingSystem
        `$totalBytes = [int64]`$os.TotalVisibleMemorySize * 1024
        `$availableBytes = [int64]`$os.FreePhysicalMemory * 1024
        `$cpuCount = [Environment]::ProcessorCount
        `$body = (@{ total_bytes = `$totalBytes; available_bytes = `$availableBytes; cpu_count = `$cpuCount } | ConvertTo-Json)
        `$buffer = [System.Text.Encoding]::UTF8.GetBytes(`$body)
        `$response.ContentType = "application/json"
        `$response.ContentLength64 = `$buffer.Length
        `$response.OutputStream.Write(`$buffer, 0, `$buffer.Length)
    } else {
        `$response.StatusCode = 404
    }
    `$response.OutputStream.Close()
}
"@ | Set-Content -Path $NodeAgentScript

# ----------------------------------------------------------------------------
# 4. The night watch — same hash-gated update pattern as every other
#    platform, hitting the windows-specific endpoints.
# ----------------------------------------------------------------------------
$UpdaterScript = Join-Path $UltronHome "bin\updater.ps1"
@"
`$UltronHome = "$UltronHome"
`$OrchestratorTailnetIp = "$OrchestratorTailnetIp"
`$CheckInterval = $UpdateCheckIntervalSeconds
`$LocalScript = Join-Path `$UltronHome "bin\install_node_windows.ps1"
`$Log = Join-Path `$UltronHome "logs\updater.log"
`$TsProxy = "127.0.0.1:$TailscaleSocksPort"

function Log(`$msg) { "[updater] `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') `$msg" | Add-Content -Path `$Log }

while (`$true) {
    Start-Sleep -Seconds `$CheckInterval

    `$remoteHash = (curl.exe -fsS -m 15 --socks5-hostname `$TsProxy "http://`${OrchestratorTailnetIp}:$OrchestratorGatewayPort/client-script-hash/windows" 2>`$null)
    if (-not `$remoteHash) { continue }

    `$localHash = `$null
    if (Test-Path `$LocalScript) {
        `$localHash = (Get-FileHash -Path `$LocalScript -Algorithm SHA256).Hash.ToLower()
    }
    if (`$remoteHash -eq `$localHash) { continue }

    Log "Update available (was `$localHash, now `$remoteHash) — applying quietly"
    `$newScript = Join-Path `$UltronHome "tmp\install_node_windows.ps1.new"
    curl.exe -fsS -m 60 --socks5-hostname `$TsProxy "http://`${OrchestratorTailnetIp}:$OrchestratorGatewayPort/client-script/windows" -o `$newScript 2>>`$Log
    if (-not (Test-Path `$newScript)) { Log "Download failed, will try again next cycle"; continue }

    `$downloadedHash = (Get-FileHash -Path `$newScript -Algorithm SHA256).Hash.ToLower()
    if (`$downloadedHash -ne `$remoteHash) {
        Log "Downloaded content didn't match the promised hash, discarding"
        Remove-Item -Force `$newScript
        continue
    }

    Copy-Item -Force `$newScript `$LocalScript
    Remove-Item -Force `$newScript

    Get-Process | Where-Object { `$_.Path -like "*ggml-rpc-server*" -or `$_.Path -like "*tailscaled_amd64*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    # Get-Process objects don't expose CommandLine (that's a Win32_Process-only
    # field) — needed here since node_agent.ps1/updater.ps1 both just show up
    # as generic "powershell.exe", distinguishable only by their script-file
    # argument, not by process name.
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { `$_.CommandLine -like "*node_agent.ps1*" } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }

    powershell -NoProfile -ExecutionPolicy Bypass -File `$LocalScript *>> `$Log
    Log "Update applied."
}
"@ | Set-Content -Path $UpdaterScript

# ----------------------------------------------------------------------------
# 5. Getting this PC its membership card (Tailscale, userspace, no admin)
# ----------------------------------------------------------------------------
Log "Waking up the private network connection ..."

$tailscaledRunning = Get-Process -Name "tailscaled_amd64" -ErrorAction SilentlyContinue
if (-not $tailscaledRunning) {
    $tsLog = Join-Path $UltronHome "logs\tailscaled.log"
    Start-Process -FilePath $TailscaledExe -ArgumentList @(
        "--socket=$TailscalePipe",
        "--statedir=$TailscaleStateDir",
        "--tun=userspace-networking",
        "--socks5-server=127.0.0.1:$TailscaleSocksPort"
    ) -WindowStyle Hidden -RedirectStandardOutput $tsLog -RedirectStandardError "${tsLog}.err"
}

Log "Waiting for the connection to actually come up ..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        & $TailscaleExe --socket=$TailscalePipe version *> $null
        $ready = $true
        break
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $ready) { Die "tailscaled never became ready — check $UltronHome\logs\tailscaled.log" }

$alreadyUp = $false
try {
    & $TailscaleExe --socket=$TailscalePipe ip -4 *> $null
    if ($LASTEXITCODE -eq 0) { $alreadyUp = $true }
} catch {}

# Local state claiming "enlisted" isn't proof of it — the server side can
# purge a device out from under it (a join key marked "ephemeral" in the
# Tailscale admin console does this automatically the instant the
# connection drops), and the local daemon has no way to notice that
# happened. Confirmed live on real Android/Linux nodes: they sat there
# reporting "already enlisted" and kept running, completely invisible to
# HQ and to `tailscale status` itself — not offline, just gone. Don't
# trust local state alone; prove HQ is actually reachable before believing it.
if ($alreadyUp) {
    $resumedOk = $false
    try {
        curl.exe -fsS -m 10 --socks5-hostname "127.0.0.1:$TailscaleSocksPort" "http://${OrchestratorTailnetIp}:${OrchestratorGatewayPort}/healthz" *> $null
        if ($LASTEXITCODE -eq 0) { $resumedOk = $true }
    } catch {}
    if (-not $resumedOk) {
        Log "Local state says enlisted, but HQ isn't reachable — this node was likely purged server-side. Logging out and rejoining fresh ..."
        try { & $TailscaleExe --socket=$TailscalePipe logout *> $null } catch {}
        $alreadyUp = $false
    }
}

if ($alreadyUp) {
    $badge = & $TailscaleExe --socket=$TailscalePipe ip -4
    Log "Already enlisted from before — resuming as $badge"
} else {
    if (-not $TailscaleAuthKey) {
        Log "No key on hand — sending a runner to fetch one from HQ ..."
        $TailscaleAuthKey = (curl.exe -fsSL --retry 5 --retry-delay 3 $OrchestratorJoinKeyUrl 2>$null)
    }
    if (-not $TailscaleAuthKey) {
        Log "WARNING: couldn't get a key (HQ didn't answer and none was provided). Everything"
        Log "else is installed and ready — you just need to finish enlistment manually once"
        Log "you've got a key:"
        Log "  & '$TailscaleExe' --socket=$TailscalePipe up --authkey=<key> --hostname=$NodeHostname --accept-dns=false"
    } else {
        & $TailscaleExe --socket=$TailscalePipe up --authkey=$TailscaleAuthKey --hostname=$NodeHostname --accept-dns=false
        $badge = & $TailscaleExe --socket=$TailscalePipe ip -4
        Log "Welcome to the Legion, $NodeHostname. Your badge number is $badge"
    }
}

# ----------------------------------------------------------------------------
# 6. The launcher — starts every daemon (idempotent, process-name-guarded)
# ----------------------------------------------------------------------------
$StartScript = Join-Path $UltronHome "bin\start_ultron.ps1"
@"
`$UltronHome = "$UltronHome"
`$TailscalePipe = "$TailscalePipe"
`$TailscaledExe = "$TailscaledExe"
`$TailscaleStateDir = "$TailscaleStateDir"
`$LlamaRpcExe = "$LlamaRpcExe"
`$RpcPort = $RpcPort
`$NodeAgentPort = $NodeAgentPort
`$NodeAgentScript = "$NodeAgentScript"
`$UpdaterScript = "$UpdaterScript"
`$Log = Join-Path `$UltronHome "logs\node.log"

"[start] `$(Get-Date) starting" | Add-Content -Path `$Log

if (-not (Get-Process -Name "tailscaled_amd64" -ErrorAction SilentlyContinue)) {
    `$tsLog = Join-Path `$UltronHome "logs\tailscaled.log"
    Start-Process -FilePath `$TailscaledExe -ArgumentList @(
        "--socket=`$TailscalePipe",
        "--statedir=`$TailscaleStateDir",
        "--tun=userspace-networking",
        "--socks5-server=127.0.0.1:$TailscaleSocksPort"
    ) -WindowStyle Hidden -RedirectStandardOutput `$tsLog -RedirectStandardError "`${tsLog}.err"
}

if (-not (Get-Process -Name "ggml-rpc-server" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath `$LlamaRpcExe -ArgumentList @("--host", "127.0.0.1", "-p", "`$RpcPort") -WindowStyle Hidden
}

`$nodeAgentUp = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { `$_.CommandLine -like "*node_agent.ps1*" } | Select-Object -First 1
if (-not `$nodeAgentUp) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`$NodeAgentScript", "-Port", "`$NodeAgentPort") -WindowStyle Hidden
}

`$updaterUp = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { `$_.CommandLine -like "*updater.ps1*" } | Select-Object -First 1
if (-not `$updaterUp) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`$UpdaterScript") -WindowStyle Hidden
}

"[start] `$(Get-Date) started (rpc=`$RpcPort agent=`$NodeAgentPort)" | Add-Content -Path `$Log
"@ | Set-Content -Path $StartScript

# ----------------------------------------------------------------------------
# 7. Surviving a reboot — a Task Scheduler entry, no admin required (a
#    per-user logon trigger with -RunLevel Limited registers fine without
#    elevation — this is standard, long-stable Windows behavior).
# ----------------------------------------------------------------------------
Log "Teaching this PC to report for duty automatically from now on ..."
$taskName = "UltronNode"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Limited
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null

# ----------------------------------------------------------------------------
# 8. No point waiting for a reboot — report for duty right now
# ----------------------------------------------------------------------------
Log "Skipping the paperwork, sending you straight to the front line ..."
Start-ScheduledTask -TaskName $taskName

curl.exe -fsSL -m 15 --socks5-hostname "127.0.0.1:$TailscaleSocksPort" "http://${OrchestratorTailnetIp}:${OrchestratorGatewayPort}/client-script/windows" -o (Join-Path $UltronHome "bin\install_node_windows.ps1") 2>$null

Log "Done. This PC is in the Legion now — no further action needed, ever."
