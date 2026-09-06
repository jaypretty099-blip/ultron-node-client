# ultron-node-client

Turn a spare Android phone into a volunteer node for the Ultron distributed inference swarm.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jaypretty099-blip/ultron-node-client/main/install_node.sh | bash
```

Requires [Termux](https://f-droid.org/en/packages/com.termux/) and [Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/) (install both from F-Droid, open Termux:Boot once to grant permissions).

This sets up a Tailscale connection and a `llama.cpp` RPC worker that contributes your phone's spare CPU/RAM to the cluster. You'll need a Tailscale auth key from whoever's running the coordinator — see `install_node.sh` for how to provide it.
