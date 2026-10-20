# AMD ROCm AI Quadlets

Podman Quadlet unit files for running a self-hosted AI stack on an AMD GPU: chat (Ollama), web search (SearXNG), image generation (ComfyUI), GPU speech-to-text (whisper.cpp), and document RAG with OCR (Docling), all behind Open WebUI. Everything runs rootless under `systemd --user`, with a shared bridge network so the containers reach each other by name. Settings are seeded from environment variables in the unit files, so the stack can be rebuilt on another machine from this repo alone.

> **Security warning:** This stack is meant for your home network and/or a private [Tailscale](https://tailscale.com/) network, not the public internet. None of these services (Ollama, ComfyUI, SearXNG, whisper, Docling) has its own authentication, and Open WebUI's login is not a substitute for real hardening. Do **not** port-forward any of these ports on your router, and do **not** use `tailscale funnel` (which publishes to the internet) with this setup. See [Remote access](#remote-access) for the supported ways to reach the stack from elsewhere.

**Contents:** [What's in the stack](#whats-in-the-stack) · [Requirements](#requirements) · [Installation](#installation) · [How configuration works](#how-configuration-works) · [Verify a fresh install](#verify-a-fresh-install) · [Remote access](#remote-access) · [Starting at boot](#starting-at-boot) · [Automatic image updates](#automatic-image-updates-podman-auto-update) · [Reference](#reference) · [Tuning for your GPU](#tuning-for-your-gpu) · [Lessons learned](#lessons-learned) · [Backups](#backups) · [Roadmap](#roadmap) · [License](#license)

## What's in the stack

| Unit | Image | GPU | Purpose |
|---|---|---|---|
| `ai-stack.network` | none | none | Custom bridge network so containers resolve each other by name (the default rootless Podman network doesn't do this) |
| `ollama.container` | `ollama/ollama:rocm` | ROCm | LLM inference and RAG embeddings |
| `open-webui.container` | `ghcr.io/open-webui/open-webui:main` | none | Chat UI. Talks to Ollama, SearXNG, ComfyUI, whisper and Docling |
| `comfyui.container` | `yanwk/comfyui-boot:rocm7` | ROCm | Image generation (Z-Image-Turbo workflow) |
| `whisper.container` | `ghcr.io/ggml-org/whisper.cpp:main-vulkan` | Vulkan | Speech-to-text, OpenAI-compatible endpoint |
| `docling.container` | `quay.io/docling-project/docling-serve:latest` | none (CPU) | Document extraction and OCR for RAG |
| `searxng.container` | `searxng/searxng:latest` | none | Self-hosted search engine, Open WebUI's web search backend |

Also in the repo: `fetch-models.sh` downloads the model files the stack needs.

Text-to-speech uses the browser's built-in voice; there is no TTS service. Speech-to-text uses whisper.cpp on Vulkan because faster-whisper/CTranslate2 can't use RDNA4 yet (see [Lessons learned](#lessons-learned)). Docling runs on the CPU because the project ships only CPU and NVIDIA images.

## Requirements

- Linux with `systemd` and rootless [Podman](https://podman.io/) (Quadlet needs 4.4+; 5.x recommended)
- An AMD GPU with a working [ROCm](https://rocm.docs.amd.com/) install on the host, plus Mesa Vulkan drivers (RADV) for whisper
- About 22 GB of free disk for the models fetched by `fetch-models.sh`, plus room for Ollama models
- GPU device permissions: see [step 1 of Installation](#installation)

Built and tested on a Radeon RX 9070 XT (RDNA4, `gfx1201`, 16 GB VRAM) on Fedora with SELinux enforcing. Other AMD cards should work; see [Tuning for your GPU](#tuning-for-your-gpu).

## Installation

1. **Check GPU device permissions.** The GPU containers (ollama, comfyui, whisper) get the device nodes through `AddDevice=`. Whether they also need a `GroupAdd=` line depends on who may open those nodes on the host:
   ```bash
   ls -ln /dev/kfd /dev/dri/
   getent group render video
   ```
   - If `/dev/kfd` and `/dev/dri/renderD128` show `crw-rw-rw-` (world read/write), **no `GroupAdd=` is needed**. The units here ship that way.
   - If they show `crw-rw----` with a group (usually `render`), add `GroupAdd=keep-groups` to each GPU container. That passes along the groups your host user belongs to, so your user must be a member first: check with `id`, and if `render` and `video` are missing, run `sudo usermod -aG render,video $USER` and log in again.
   - Distributions differ. Fedora left these nodes world-accessible on the machine this was built on; some Ubuntu and Debian setups restrict them. Run the `ls` check on every new machine rather than assuming.
   - Don't use numeric IDs (`GroupAdd=105`): in a rootless user namespace the number refers to a group inside the container's own mapping, not the host group. `GroupAdd=render` by name fails with "no matching entries in group file", because Quadlet looks the name up inside the image.

   Ollama and ComfyUI need `/dev/kfd` and `/dev/dri` (ROCm). Whisper needs only `/dev/dri` (Vulkan). Apply the same rule to all three so they stay consistent.

2. **Create the data directories.**
   ```bash
   mkdir -p ~/ai-stack/{ollama,searxng,open-webui,whisper/models}
   mkdir -p ~/ai-stack/comfyui/{models,output,custom_nodes,hf-hub,torch-hub,input,workflows}
   ```

3. **Install the units.**
   ```bash
   mkdir -p ~/.config/containers/systemd
   cp *.network *.container ~/.config/containers/systemd/
   systemctl --user daemon-reload
   ```

4. **Download models.** Ollama has to be running for the Ollama part.
   ```bash
   systemctl --user start ollama
   ./fetch-models.sh
   ```
   This fetches the three Z-Image files (~20 GB) into `~/ai-stack/comfyui/models/`, the whisper model into `~/ai-stack/whisper/models/`, and pulls `qwen3:14b` and `nomic-embed-text` into Ollama. It skips files already present and resumes interrupted downloads. Set `AI_STACK_DIR` to use a different base directory.

5. **Enable SearXNG's JSON output.** JSON is off by default but Open WebUI's search integration needs it. Start SearXNG once so it writes its config, then edit `~/ai-stack/searxng/settings.yml`:
   ```yaml
   search:
     formats:
       - html
       - json
   ```
   Restart it: `systemctl --user restart searxng`. Without this, web search fails with 403.

6. **Start everything.** The network unit starts automatically as a dependency.
   ```bash
   systemctl --user start ollama searxng whisper comfyui docling open-webui
   ```
   Stop with the same command using `stop`. Check status and logs the usual systemd way:
   ```bash
   systemctl --user status ollama.service
   journalctl --user -u ollama.service -f
   ```

7. **Open `http://<host-ip>:3000`**, create the first account (it becomes the admin), and run the [checks below](#verify-a-fresh-install).

Units have no active `[Install]` section, so nothing starts at boot unless you opt in; see [Starting at boot](#starting-at-boot).

## How configuration works

- **Environment variables in the units seed Open WebUI's settings:** web search, image generation (including the ComfyUI workflow and node mappings), RAG and embeddings, Docling, and the speech-to-text endpoint. No clicking through the admin panel is needed on a new install.
- **Open WebUI stores these in its database after first start.** Editing `open-webui.container` later changes nothing on an existing install. Change the setting in Admin > Settings, or stop Open WebUI and clear `~/ai-stack/open-webui` to re-seed from the files (this deletes accounts and chats).
- **JSON values** (`COMFYUI_WORKFLOW`, `COMFYUI_WORKFLOW_NODES`, `DOCLING_PARAMS`) are written as `Environment="KEY=...\"..."` lines with escaped quotes. `EnvironmentFile=` strips double quotes and breaks them, so don't move them there.
- **Ollama's context length** is `OLLAMA_CONTEXT_LENGTH` in `ollama.container`. A per-model value set in Open WebUI overrides it.
- **Not covered by environment variables**, so set by hand if you want them: user accounts, knowledge collections, per-model overrides, and trimming the built-in tool list on a model.

## Verify a fresh install

| Check | What to do | Expected |
|---|---|---|
| Chat | Send a message | Reply streams; `podman exec ollama ollama ps` shows `100% GPU` |
| Context | Look at `ollama ps` | CONTEXT matches `OLLAMA_CONTEXT_LENGTH` |
| Web search | Enable search, ask for something current | Results cited, no 403 from SearXNG |
| Images | Ask for a picture | Image appears; the ComfyUI log shows the job |
| STT | Record or upload audio | Transcript appears; `journalctl --user -u whisper` shows the request. Admin > Settings > Audio should show the OpenAI engine pointing at `http://whisper:8001/v1` |
| RAG | Upload a text file, ask about it | Answer uses its contents |
| OCR | Upload an image-only PDF | Text from the scan is retrievable (Docling must be running) |

GPU checks, per container:
- **whisper:** `journalctl --user -u whisper` shows a `ggml_vulkan:` line naming your AMD GPU at startup.
- **ollama:** `podman exec ollama ollama ps` shows `100% GPU` after a chat.
- **comfyui:** the startup log names the AMD device, and images generate without falling back to the CPU.

## Remote access

No reverse proxy is required. Whichever option you use, keep the [security warning](#amd-rocm-ai-quadlets) in mind: neither adds authentication, they only control who can reach the network the services sit on.

**Microphone input:** browsers only allow mic access over HTTPS or from `localhost`. Plain `http://<host-ip>:3000` from other devices won't get mic permission (typing, image generation and TTS playback still work). The Tailscale option below fixes this; LAN-only does not.

### Tailscale access

Use [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve), a reverse proxy built into `tailscaled`. It terminates HTTPS with Tailscale's own auto-renewing MagicDNS certificate and stays **tailnet-only**. Its sibling `tailscale funnel` publishes to the public internet; don't use that here.

Each service is served on a port `10000` higher than its normal port (see [Ports](#ports)). That's easy to remember, and `tailscale serve` can't reuse a port a service already listens on for LAN access.

1. **Enable HTTPS certs** for your tailnet once, in the [Tailscale admin console](https://login.tailscale.com/admin/dns) (DNS tab, "HTTPS Certificates").
2. **Find your MagicDNS hostname:** `tailscale status --self` (it looks like `myhost.tailnet-name.ts.net`).
3. **Serve the services you want reachable:**
   ```bash
   sudo tailscale serve --bg --https=13000 http://127.0.0.1:3000     # Open WebUI
   sudo tailscale serve --bg --https=18188 http://127.0.0.1:8188     # ComfyUI
   ```
   Only Open WebUI is needed for normal use, and ComfyUI if you want its own interface. The others (Ollama `11434`, SearXNG `8080`, whisper `8001`, Docling `5001`) are normally only used container to container; serve them only if you have a reason to.

Reach a service at `https://myhost.tailnet-name.ts.net:<port>`, for example `:13000` for Open WebUI. To inspect or remove:

```bash
tailscale serve status
sudo tailscale serve --https=13000 off
```

### LAN-only access

Each service is reachable directly at `http://<host-ip>:<port>` (see [Ports](#ports)); nothing extra to set up. This is plain HTTP, so mic input is unavailable. If you need it from another device, put that device on your tailnet and use Tailscale access instead.

## Starting at boot

The units have a commented-out `[Install]` block, so `systemctl --user enable` has nothing to hook into by default. To start the stack automatically:

1. **Uncomment the `[Install]` block** at the bottom of each `.container` file you want to auto-start:
   ```ini
   [Install]
   WantedBy=default.target
   ```
   Leave `ai-stack.network` alone; any container that references it pulls it in.

2. **Reload and enable:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable ollama.service searxng.service whisper.service comfyui.service docling.service open-webui.service
   ```

3. **Enable lingering**, so your user's services start at boot before you log in and survive logout:
   ```bash
   loginctl enable-linger "$USER"
   ```

Be aware that a single-GPU machine then loads Ollama, ComfyUI and whisper on boot. They only take VRAM when a model is loaded, but see [Resource notes](#resource-notes).

## Automatic image updates (podman auto-update)

`ollama`, `open-webui`, `comfyui` and `searxng` set `AutoUpdate=registry`, which makes them eligible for [`podman auto-update`](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html): Podman compares the registry digest and, if a newer image exists, pulls it and restarts the unit. `whisper` and `docling` don't set it, so they only change when you pull them yourself. Add the line to those units if you want them updated too.

```bash
systemctl --user enable --now podman-auto-update.timer    # daily check
systemctl --user list-timers podman-auto-update.timer     # last/next run
podman auto-update --dry-run                              # show what would update
podman auto-update                                        # update now
journalctl --user -u podman-auto-update.service           # logs
```

Notes:
- A restart means a few seconds of downtime for that service. Models and data live in the bind mounts and are unaffected, but anything loaded into VRAM has to reload on next use.
- Images tracked at `:main` or `:latest` can change behavior between updates. To control updates yourself, remove `AutoUpdate=registry` from a unit and run `podman pull <image>` then `systemctl --user restart <service>` when you choose.

## Reference

### Data locations

All persistent data lives under `~/ai-stack/`, bind-mounted into the containers. Back it up if you want to keep chat history, settings or generated images.

| Path | Contents |
|---|---|
| `~/ai-stack/ollama` | Pulled models and Ollama state |
| `~/ai-stack/comfyui/{models,output,custom_nodes,input,workflows,hf-hub,torch-hub}` | ComfyUI models, generated images, custom nodes, cached weights |
| `~/ai-stack/whisper/models` | whisper.cpp model file |
| `~/ai-stack/open-webui` | Open WebUI database and config |
| `~/ai-stack/searxng` | SearXNG config (`settings.yml`) |

Docling keeps no persistent data.

### Ports

| Service | Host port | Tailscale HTTPS port (optional) |
|---|---|---|
| Open WebUI | `3000` (container port `8080`) | `13000` |
| Ollama | `11434` | `21434` |
| ComfyUI | `8188` | `18188` |
| SearXNG | `8080` | `18080` |
| whisper | `8001` | `18001` |
| Docling | `5001` | `15001` |

The Tailscale column only applies if you set up [Tailscale access](#tailscale-access). SearXNG publishes host port 8080, so anything else you add that wants 8080 on the host needs another port.

## Tuning for your GPU

- **Device access** is covered in [Installation step 1](#installation). Ollama and ComfyUI add `/dev/kfd` and `/dev/dri`; whisper adds only `/dev/dri`.
- **GPU not detected in a ROCm container:** an arch override may help. Set `HSA_OVERRIDE_GFX_VERSION` to a supported arch string close to your card's real target (find it with `rocminfo | grep gfx`). It isn't needed on an RX 9070 XT with ROCm 7.x, but older ROCm builds or other unsupported cards may need it.
- **Ollama settings** (`OLLAMA_CONTEXT_LENGTH`, `OLLAMA_KV_CACHE_TYPE`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS`) are tuned for a single user and a 16 GB card. With more VRAM or several users, raise them.
- **Different models:** change `OLLAMA_CONTEXT_LENGTH` to suit. The default of 2048 silently truncates prompts, which drops tool definitions first (see [Lessons learned](#lessons-learned)).
- **Different image model:** the ComfyUI workflow and node mappings are the `COMFYUI_*` variables in `open-webui.container`, and the files `fetch-models.sh` downloads. Change both together.

## Resource notes

- This is a single-user setup by design. Ollama runs one parallel request and one loaded model so that Ollama, ComfyUI and whisper can share one GPU. Several people at once would queue.
- The KV cache is quantized (`q8_0`, flash attention on), roughly halving the VRAM cost of context.
- A loaded chat model and ComfyUI share the same card. If images are slow right after a long chat, shorten Ollama's keep-alive (`OLLAMA_KEEP_ALIVE`).
- Docling runs on the CPU. Scanned PDFs can take minutes, which is why `DOCLING_SERVE_MAX_SYNC_WAIT` is raised to 600. It only needs to be running when you upload documents; PDF uploads fail while it is stopped.

## Lessons learned

Problems hit while building this, so they don't recur.

- **Tools silently disappeared at the default 2048-token context.** Ollama drops the oldest tokens without warning, and tool definitions come first in the prompt. Set `OLLAMA_CONTEXT_LENGTH` in the **Ollama** container; setting it in Open WebUI's has no effect. If a tool stops being called, check `prompt_eval_count` in debug logs.
- **`EnvironmentFile=` strips double quotes,** which breaks JSON values. Keep them as escaped `Environment=` lines. After editing, confirm with `podman exec open-webui env | grep COMFYUI_WORKFLOW_NODES` that the quotes survived.
- **Open WebUI settings are persistent.** Environment variables only seed the database on first start; later edits to the unit are ignored.
- **Image Prompt Generation only works in Default function-calling mode,** not Native.
- **The ComfyUI container needs** `SeccompProfile=unconfined`, `AddCapability=CAP_SYS_PTRACE` and `--ipc=host`.
- **Rootless bind mounts can have the wrong owner** for images that run as a non-root user. Fix with `podman unshare chown -R <uid>:<gid> <dir>`.

## Backups

Back up `~/ai-stack`, leaving out the model folders, which `fetch-models.sh` can recreate:

```bash
systemctl --user stop open-webui
tar -czf ~/ai-stack-backup-$(date +%F).tar.gz \
  --exclude='ai-stack/ollama' --exclude='ai-stack/comfyui/models' \
  --exclude='ai-stack/whisper/models' -C ~ ai-stack
systemctl --user start open-webui
```

If `tar` reports permission errors, run it under `podman unshare`. Open WebUI's data directory (`~/ai-stack/open-webui`) matters most.

## Roadmap

- A higher-quality text-to-speech service in place of the browser voice.

## License

[MIT](LICENSE)
