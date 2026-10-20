#!/usr/bin/env bash
# Download the model files the AI stack needs. Safe to re-run: files that already exist are skipped,
# and interrupted downloads resume.
set -euo pipefail

BASE="${AI_STACK_DIR:-$HOME/ai-stack}"
HF=https://huggingface.co

get() {  # get <url> <destination>
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then echo "skip   $dest (already present)"; return; fi
  mkdir -p "$(dirname "$dest")"
  echo "fetch  $dest"
  curl -L --fail --retry 3 -C - -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

echo "Needs roughly 22 GB free under $BASE (Z-Image ~20 GB, whisper ~1.6 GB)."
df -h "$(mkdir -p "$BASE" && echo "$BASE")" | tail -1

# --- ComfyUI: Z-Image-Turbo ---------------------------------------------------
Z="$HF/Comfy-Org/z_image_turbo/resolve/main/split_files"
get "$Z/diffusion_models/z_image_turbo_bf16.safetensors" "$BASE/comfyui/models/diffusion_models/z_image_turbo_bf16.safetensors"
get "$Z/text_encoders/qwen_3_4b.safetensors"             "$BASE/comfyui/models/text_encoders/qwen_3_4b.safetensors"
get "$Z/vae/ae.safetensors"                              "$BASE/comfyui/models/vae/ae.safetensors"

# --- whisper.cpp: speech-to-text ----------------------------------------------
get "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" "$BASE/whisper/models/ggml-large-v3-turbo.bin"

# --- Ollama models (needs the ollama container running) ------------------------
OLLAMA_MODELS=(qwen3:14b nomic-embed-text)
if podman ps --format '{{.Names}}' | grep -qx ollama; then
  for m in "${OLLAMA_MODELS[@]}"; do
    echo "pull   ollama $m"
    podman exec ollama ollama pull "$m"
  done
else
  echo "note   ollama container is not running; later run: systemctl --user start ollama, then re-run this script"
fi

echo "Done."

