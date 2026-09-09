# AMD ROCm AI Quadlets

Podman Quadlet unit files for running a self-hosted AI stack on AMD GPUs via ROCm. Everything runs rootless under `systemd --user`, with a shared bridge network so the containers can reach each other by name.

## What's in the stack

| Unit | Image | Purpose |
|---|---|---|
| `ai-stack.network` | — | Custom bridge network so containers resolve each other by name (the default rootless Podman network doesn't do this) |
| `ollama.container` | `ollama/ollama:rocm` | LLM inference server, GPU-accelerated via ROCm |
| `open-webui.container` | `ghcr.io/open-webui/open-webui:main` | Chat UI — talks to Ollama for text, SearXNG for web search, ComfyUI for image generation |
| `comfyui.container` | `yanwk/comfyui-boot:rocm7` | Image generation backend, GPU-accelerated via ROCm |
| `searxng.container` | `searxng/searxng:latest` | Self-hosted search engine, used as Open WebUI's web search backend |
| `speaches.container` | `speaches-ai/speaches:latest-cpu` | OpenAI-compatible STT/TTS server, used by Open WebUI for voice input/output |

> **Note:** `speaches` currently runs on CPU, not ROCm. It's likely to be swapped out for a hardware-accelerated STT/TTS service in a future update. A reverse proxy for HTTPS (Traefik/Caddy) is also planned — see the [mic/HTTPS note](#post-install-configuration) below.

## Requirements

- Linux with `systemd` and rootless [Podman](https://podman.io/) (Quadlet support requires Podman 4.4+; Podman 5.x recommended)
- An AMD GPU with a working [ROCm](https://rocm.docs.amd.com/) install on the host
- Your user account in the `video` (and possibly `render`) group for `/dev/kfd` and `/dev/dri` access
- The GPU device paths (`/dev/kfd`, `/dev/dri`) available to rootless containers

These files were built and tested against an RDNA4 card (RX 9070 XT, `gfx1201`). If you're on a different GPU generation, see [Tuning for your GPU](#tuning-for-your-gpu) below.

## Installation

Quadlet files are picked up from `~/.config/containers/systemd/` for rootless (per-user) setups.

```bash
mkdir -p ~/.config/containers/systemd
cp *.network *.container ~/.config/containers/systemd/
systemctl --user daemon-reload
```

Then start the stack (the network and `After=` ordering handle dependencies):

```bash
systemctl --user start ollama.service
systemctl --user start searxng.service
systemctl --user start speaches.service
systemctl --user start comfyui.service
systemctl --user start open-webui.service
```

Check status and logs the usual systemd way:

```bash
systemctl --user status ollama.service
journalctl --user -u ollama.service -f
```

For starting the stack automatically at boot instead of manually, see [Starting at boot](#starting-at-boot) below.

## Starting at boot

By default these units have no `[Install]` section, so `systemctl --user enable` has nothing to hook into — they're meant to be started manually or pulled in as dependencies. To have systemd start them automatically at boot:

1. **Uncomment the `[Install]` block** at the bottom of each `.container` file you want to auto-start:

   ```ini
   [Install]
   WantedBy=default.target
   ```

   Do this for `ollama.container`, `searxng.container`, `speaches.container`, `comfyui.container`, and `open-webui.container` (leave `ai-stack.network` alone — it doesn't need `[Install]`; it's pulled in automatically by any container that references it).

2. **Reload and enable each service:**

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable ollama.service searxng.service speaches.service comfyui.service open-webui.service
   ```

3. **Enable lingering** for your user, so `systemd --user` (and these services) start at boot even before you log in:

   ```bash
   loginctl enable-linger "$USER"
   ```

   Without lingering, rootless `systemd --user` units only run while you have an active login session.

After a reboot, confirm everything came up:

```bash
systemctl --user status ollama.service open-webui.service comfyui.service searxng.service speaches.service
```

## Data locations

All persistent data lives under `~/ai-stack/`, bind-mounted into the containers:

- `~/ai-stack/ollama` — pulled models and Ollama state
- `~/ai-stack/comfyui/{models,output,custom_nodes,input,workflows,hf-hub,torch-hub}` — ComfyUI models, generated images, custom nodes, cached weights
- `~/ai-stack/open-webui` — Open WebUI database/config
- `~/ai-stack/searxng` — SearXNG config (`settings.yml`)
- `~/ai-stack/speaches` — cached Hugging Face STT/TTS models

These directories are created automatically on first start; back them up if you want to preserve chat history, models, or generated images.

## Ports

| Service | Port |
|---|---|
| Ollama | `11434` |
| Open WebUI | `3000` (proxies to container port `8080`) |
| ComfyUI | `8188` |
| SearXNG | `8080` |
| speaches | `8000` |

## Post-install configuration

**SearXNG** — JSON output is off by default but required for Open WebUI's search integration. After the first start, edit `~/ai-stack/searxng/settings.yml` and add `json` to the search formats:

```yaml
search:
  formats:
    - html
    - json
```

Then restart: `systemctl --user restart searxng.service`

**Open WebUI image generation** — the `COMFYUI_WORKFLOW` (API-format JSON) and node-ID mappings still need to be configured once through Admin Panel > Settings > Images in the Open WebUI UI.

**Microphone input** — browser mic access for Open WebUI's STT only works over HTTPS or from `localhost`. Plain `http://<host-ip>:3000` from other devices on your network won't get mic permission (typing, image generation, and TTS playback still work fine). Put a TLS-terminating reverse proxy (Traefik, Caddy, etc.) in front of Open WebUI if you need mic access from other devices.

## Automatic image updates (podman auto-update)

Every `.container` unit in this repo sets `AutoUpdate=registry`, which marks the container as eligible for [`podman auto-update`](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html) — Podman checks the image's registry digest and, if a newer image was pushed (e.g. after `AutoUpdate=registry` for `docker.io/ollama/ollama:rocm`), pulls it and restarts the systemd unit with the same name.

**Enable the timer** (runs a check once a day by default) so this happens automatically:

```bash
systemctl --user enable --now podman-auto-update.timer
```

Check when it last ran / will next run:

```bash
systemctl --user list-timers podman-auto-update.timer
```

**Run a check manually** at any time instead of waiting for the timer:

```bash
podman auto-update
```

**Dry-run** to see what would be updated without actually doing it:

```bash
podman auto-update --dry-run
```

Update logs land in the systemd journal:

```bash
journalctl --user -u podman-auto-update.service
```

A couple of things worth knowing:

- Auto-update only works for images pulled from a registry with a resolvable digest (i.e. not `:latest`-only local builds) — all the images used here qualify.
- A restart means a few seconds of downtime for that service and, for `ollama`/`comfyui`, the model/weights caches on disk are unaffected (they live in the bind-mounted `~/ai-stack/...` volumes), but anything in-memory (e.g. a model loaded into VRAM) has to reload on next use.
- If you'd rather control updates yourself, remove the `AutoUpdate=registry` line from a unit and pull/restart manually (`podman pull <image>` then `systemctl --user restart <service>`).

## Tuning for your GPU

A few settings in these units are specific to the GPU they were tuned on and may need adjusting:

- `ollama.container` and `comfyui.container` both add `/dev/kfd` and `/dev/dri`, plus `GroupAdd=keep-groups` for GPU device access. See [A note on `GroupAdd=keep-groups`](#a-note-on-groupaddkeep-groups-vs-explicit-groups) below for a tighter alternative.
- `comfyui.container` sets `HSA_OVERRIDE_GFX_VERSION=12.0.1` to make an unsupported/newer arch report as a supported one. If your GPU is natively supported by your ROCm/PyTorch version, try removing this line first.
- Ollama env vars (`OLLAMA_KV_CACHE_TYPE`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_KEEP_ALIVE`) are tuned for a single-user, single-model, VRAM-constrained setup — adjust to taste if you have more VRAM or multiple concurrent users.

### A note on `GroupAdd=keep-groups` vs. explicit groups

`ollama.container` and `comfyui.container` both use `GroupAdd=keep-groups` to get access to `/dev/kfd` and `/dev/dri`, which on most distros are owned by the `render` and/or `video` groups. `keep-groups` is a rootless-Podman-only option that carries over **all** of the supplementary groups your host user belongs to into the container — not just `render`/`video`. It's the simplest thing that works, which is why these units default to it, but it's broader than the container actually needs: if your user account also happens to be in `wheel`, `docker`, or some other sensitive group, the container gets that group membership too (though it still can't do anything with it unless something inside the container tries to use it).

For a tighter setup, replace `GroupAdd=keep-groups` with the specific GIDs the container needs:

```bash
getent group video   # note the GID
getent group render  # note the GID
```

```ini
GroupAdd=44    # video, or whatever your `getent group video` printed
GroupAdd=105   # render, or whatever your `getent group render` printed
```

This grants only GPU device access instead of your full group list, at the cost of having to hardcode GIDs that can differ between machines (which is why `keep-groups` is used here as the portable default). If you're running this on a shared or otherwise security-sensitive host, the explicit-GID form is the safer choice.

## Roadmap

- Replace `speaches` (currently CPU-only) with a hardware-accelerated STT/TTS service once the ROCm crash bug is resolved upstream or a suitable alternative is found.
- Add a TLS-terminating reverse proxy (Traefik or Caddy) in front of Open WebUI, enabling HTTPS and browser mic access from devices other than `localhost`.

## License

[MIT](LICENSE)
