# The Ultron Legion

*n. a growing army of retired Android phones that got bored of being paperweights and decided to think for a living instead.*

Somewhere in a drawer, an old phone is charging for no reason, doing absolutely nothing with its life. This fixes that. One command turns it into a soldier in a distributed AI brain — lending its spare CPU and RAM to a swarm that's bigger, together, than any single device in it.

Is it a *tiny* bit "rogue AI slowly assembling a private robot army" energy? Maybe. Should that stop you? Absolutely not. We're doing this for **science** (and because buying a GPU cluster is expensive and phones — and laptops, and that old desktop under the desk — are just... sitting there).

## Enlist

Same ceremony everywhere: paste one line, hit enter, walk away. Pick your platform.

**Android** — open [Termux](https://f-droid.org/en/packages/com.termux/), paste this:

```bash
curl -fsSL https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node.sh | bash
```

**Linux** (Fedora, Ubuntu, Debian, whatever — battle-tested, verified live) — any terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node_linux.sh | bash
```

**macOS** — Terminal, needs [Homebrew](https://brew.sh) already installed (it's how this gets a proper CLI copy of Tailscale, not the menu-bar app):

```bash
curl -fsSL https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node_macos.sh | bash
```

**Windows** — PowerShell:

```powershell
irm https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node_windows.ps1 | iex
```

That's it. That's the whole ceremony. No forms, no oath, no chip in your neck — just a script that quietly turns your machine into a tiny cog in a much bigger one.

*Heads up: the macOS and Windows versions are new and haven't been run on real hardware yet (Linux and Android have, extensively). They're built the same way and should work the same way, but if something's off, that's why — please say something if it is.*

## Before you enlist

**Android** needs two apps from F-Droid, both free:

- **[Termux](https://f-droid.org/en/packages/com.termux/)** — the terminal your phone didn't know it needed.
- **[Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/)** — open it *once* after installing so it's allowed to wake your node up when your phone reboots. Skip this and your recruit goes back to sleep every time the phone restarts, which is a very undignified way to serve the Legion.

**macOS** needs [Homebrew](https://brew.sh) — it's the only way to get Tailscale's CLI without installing the full menu-bar app.

**Linux and Windows** need nothing extra — the script handles everything itself.

**A note for Windows recruits specifically:** Tailscale's own installer needs admin rights and a system driver, which doesn't fit "run one command and forget it exists." So this script uses a purpose-built Tailscale binary instead, compiled from Tailscale's own public source rather than downloaded as their signed installer. It's unsigned. Windows Defender or SmartScreen might raise an eyebrow at an unrecognized .exe that opens network connections — that's a real possibility, not a hidden one.

## What actually happens when you run it

No smoke, no mirrors, just your device quietly:

1. Getting itself a small, unauthenticated-but-harmless piece of `llama.cpp` that can accept compute jobs from the mothership — a prebuilt copy where one exists for your platform (fast), or compiled on the spot where it doesn't (Android always compiles; the others fall back to it automatically if the prebuilt one won't run).
2. Joining a private [Tailscale](https://tailscale.com) network — your device gets an ID card and a name like `ultron-linux-a1b2`, and nothing about it is reachable from the open internet.
3. Getting itself a Tailscale membership card automatically. You don't touch a single key — the script fetches one from the coordinator on its own, uses it once, and never keeps a copy lying around.
4. Setting itself up to survive a reboot, so once it's in, it's *in*. Every restart (or every login, depending on platform), it reports back for duty without you lifting a finger.
5. Checking in quietly every so often for anything new, and updating itself in the background if there is. You'll never see a prompt, never need to re-run this command — once you're in, you're taken care of.

Your device doesn't download the AI model itself, doesn't need to be plugged in forever, and isn't doing anything alarming — it's just lending some idle compute to a cluster that does the actual thinking elsewhere. Think "seti@home," not "skynet." Probably.

## FAQ nobody asked for

**Is my phone going to become self-aware?**
No. It's going to become slightly warmer than usual and occasionally do some math. That's the whole superpower.

**Why is it called Ultron?**
Because "Distributed-Inference-Coordination-Framework-v2" doesn't have the same ring to it, and every good origin story needs a slightly ominous name.

---

*Recruitment is voluntary. Robot uprising is a bit. Mostly.*
