# 🤖 The Ultron Legion

*n. a growing army of retired Android phones that got bored of being paperweights and decided to think for a living instead.*

Somewhere in a drawer, an old phone is charging for no reason, doing absolutely nothing with its life. This fixes that. One command turns it into a soldier in a distributed AI brain — lending its spare CPU and RAM to a swarm that's bigger, together, than any single device in it.

Is it a *tiny* bit "rogue AI slowly assembling a private robot army" energy? Maybe. Should that stop you? Absolutely not. We're doing this for **science** (and because buying a GPU cluster is expensive and phones are just... sitting there).

## Enlist

Open [Termux](https://f-droid.org/en/packages/com.termux/), paste this, hit enter, and welcome to the Legion:

```bash
curl -fsSL https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node.sh | bash
```

That's it. That's the whole ceremony. No forms, no oath, no chip in your neck — just a script that quietly turns your phone into a tiny cog in a much bigger machine.

## Before you enlist

You'll need two apps from F-Droid, both free, both doing exactly what their names promise:

- **[Termux](https://f-droid.org/en/packages/com.termux/)** — the terminal your phone didn't know it needed.
- **[Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/)** — open it *once* after installing so it's allowed to wake your node up when your phone reboots. Skip this and your recruit goes back to sleep every time the phone restarts, which is a very undignified way to serve the Legion.

## What actually happens when you run it

No smoke, no mirrors, just your phone quietly:

1. Installing a handful of build tools (don't worry, it cleans up after itself).
2. Compiling a small, unauthenticated-but-harmless piece of `llama.cpp` that can accept compute jobs from the mothership.
3. Joining a private [Tailscale](https://tailscale.com) network — your phone gets an ID card and a name like `ultron-node-a1b2`, and nothing about it is reachable from the open internet.
4. Getting itself a Tailscale membership card automatically. You don't touch a single key — the script fetches one from the coordinator on its own, uses it once, and never keeps a copy lying around.
5. Setting itself up to survive a reboot, so once it's in, it's *in*. Every restart, it reports back for duty without you lifting a finger.

Your phone doesn't download the AI model itself, doesn't need to be plugged in forever, and isn't doing anything alarming — it's just lending some idle compute to a cluster that does the actual thinking elsewhere. Think "seti@home," not "skynet." Probably.

## FAQ nobody asked for

**Is my phone going to become self-aware?**
No. It's going to become slightly warmer than usual and occasionally do some math. That's the whole superpower.

**Why is it called Ultron?**
Because "Distributed-Inference-Coordination-Framework-v2" doesn't have the same ring to it, and every good origin story needs a slightly ominous name.

---

*Recruitment is voluntary. Robot uprising is a bit. Mostly.*
