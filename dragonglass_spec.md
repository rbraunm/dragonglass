# Local AI Stack Implementation Spec

**Author:** Randy + Claude  
**Date:** May 12, 2026  
**Cluster:** Proxmox (labradorite / larvikite)  
**Workstation:** Windows + RTX 2080 Ti (11GB VRAM)

---

## Overview

Replace $120/mo in AI subscriptions (Claude Max 5x + ChatGPT) with a $20/mo Claude Pro subscription backed by on-prem local LLM inference and local image generation. One-time hardware cost: ~$177 (CPU upgrade + thermal paste).

### Cost Summary

| Before | After |
|--------|-------|
| Claude Max 5x: $100/mo | Claude Pro: $20/mo |
| ChatGPT: $20/mo | Local LLM (dragonglass on labradorite): $0 |
| | ComfyUI image gen (2080 Ti): $0 |
| **Total: $120/mo** | **Total: ~$23/mo (incl. power)** |
| | **One-time: ~$177 (2x E5-2699 v4 + paste)** |
| | **Savings: ~$97/mo / ~$1,164/yr** |
| | **Payback on hardware: < 2 months** |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Windows Workstation                    │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │   Browser     │  │  Unity Editor│  │  WSL2 + Docker│  │
│  │              │  │              │  │               │  │
│  │  Open WebUI  │  │  Game Dev    │  │  ComfyUI      │  │
│  │  (remote)    │  │              │  │  + CUDA       │  │
│  │              │  │              │  │  + SD/SDXL     │  │
│  └──────┬───────┘  └──────────────┘  └───────┬───────┘  │
│         │                                     │          │
│         │ HTTP                         RTX 2080 Ti       │
│         │                              11GB VRAM         │
└─────────┼─────────────────────────────────────┘          │
          │                                                 
          │ http://dragonglass:3000                         
          ▼                                                 
┌─────────────────────────────────────────────────────────┐
│              labradorite (Dell PowerEdge R730)            │
│              2x Xeon E5-2699 v4 | 320GB DDR4 @ 2400      │
│              ~256GB free | ~128 GB/s bandwidth            │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │            LXC Container: dragonglass              │  │
│  │            64GB RAM | 8 cores | 50GB disk          │  │
│  │                                                    │  │
│  │  ┌──────────────┐    ┌──────────────────────────┐  │  │
│  │  │   Ollama      │    │   Open WebUI (Docker)    │  │  │
│  │  │   Port 11434  │◄───│   Port 3000              │  │  │
│  │  │               │    │                          │  │  │
│  │  │  Models:       │    │  Provider:               │  │  │
│  │  │  - qwen2.5-   │    │  - Ollama (local)        │  │  │
│  │  │    coder:14b   │    │                          │  │  │
│  │  │  - deepseek-  │    │  Features:               │  │  │
│  │  │    r1:14b      │    │  - RAG / doc upload       │  │  │
│  │  │  - qwen2.5-   │    │  - Web search (SearXNG)  │  │  │
│  │  │    coder:7b    │    │  - Chat history           │  │  │
│  │  └──────────────┘    └──────────────────────────┘  │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Existing VMs remain untouched                           │
└──────────────────────────────────────────────────────────┘
```

---

## Phase 0: Hardware Optimization (Labradorite)

Perform before creating the LXC container. Requires labradorite downtime.

### 0.1 CPU Swap: E5-2680 v3 → E5-2699 v4

**Purchase:** 2x Intel Xeon E5-2699 v4 (SR2JS) — ~$169/pair on eBay  
**Also needed:** Thermal paste (Arctic MX-4 or Noctua NT-H1) — ~$8

| Spec | Current (2x E5-2680 v3) | Upgraded (2x E5-2699 v4) |
|------|------------------------|--------------------------|
| Architecture | Haswell-EP | Broadwell-EP |
| Cores / Threads | 24c / 48t | 44c / 88t |
| Base / Turbo | 2.5 / 3.3 GHz | 2.2 / 3.6 GHz |
| Max DDR4 | 2133 MT/s | 2400 MT/s |
| TDP (total) | 240W | 290W |
| L3 Cache | 30MB | 55MB |

**Procedure:**
1. Shut down labradorite, migrate or stop VMs as needed
2. Remove cooling shroud and heatsinks (see R730 Owner's Manual)
3. Swap CPUs — note orientation notch on socket
4. Apply thermal paste to new CPUs
5. Reinstall heatsinks and shroud
6. Boot and verify in iDRAC/BIOS that both E5-2699 v4 are detected

> **Note:** The old E5-2680 v3 pair are spares — shelf them, don't put
> them in larvikite (it already has the faster E5-2690 v3).

### 0.2 Memory Redistribution

Move larvikite's 4x 32GB DDR4-2400 sticks to labradorite. Backfill
larvikite with 16GB sticks freed from labradorite. Goal: 2 DIMMs per
channel (2 DPC) on labradorite to unlock DDR4-2400 speeds.

**R730 Channel Mapping (from Dell Owner's Manual):**

| | Channel 0 | Channel 1 | Channel 2 | Channel 3 |
|--|-----------|-----------|-----------|-----------|
| CPU1 | A1, A5, A9 | A2, A6, A10 | A3, A7, A11 | A4, A8, A12 |
| CPU2 | B1, B5, B9 | B2, B6, B10 | B3, B7, B11 | B4, B8, B12 |

**Population rule:** White tab slots first (1-4), then black (5-8).
Green slots (9-12) stay empty for 2 DPC. Larger DIMMs go in white slots.

**Current labradorite config (BEFORE — 21x 16GB = 336GB @ 1866):**

| Channel | CPU1 | DPC | CPU2 | DPC |
|---------|------|-----|------|-----|
| Ch0 | A1✓ A5✓ A9✓ | 3 | B1✓ B5✓ B9✓ | 3 |
| Ch1 | A2✗ A6✗ A10✗ | **0 (dead!)** | B2✓ B6✓ B10✓ | 3 |
| Ch2 | A3✓ A7✓ A11✓ | 3 | B3✓ B7✓ B11✓ | 3 |
| Ch3 | A4✓ A8✓ A12✓ | 3 | B4✓ B8✓ B12✓ | 3 |

**Labradorite AFTER — 4x 32GB + 12x 16GB = 320GB @ 2400 MT/s, 2 DPC:**

| Slot | Size | Notes |
|------|------|-------|
| A1 (white) | **32GB** | CPU1 Ch0, slot 1 |
| A2 (white) | **32GB** | CPU1 Ch1, slot 1 |
| A3 (white) | 16GB | CPU1 Ch2, slot 1 |
| A4 (white) | 16GB | CPU1 Ch3, slot 1 |
| A5 (black) | 16GB | CPU1 Ch0, slot 2 |
| A6 (black) | 16GB | CPU1 Ch1, slot 2 |
| A7 (black) | 16GB | CPU1 Ch2, slot 2 |
| A8 (black) | 16GB | CPU1 Ch3, slot 2 |
| A9 (green) | — | CPU1 Ch0, slot 3 — **empty for 2 DPC** |
| A10 (green) | — | CPU1 Ch1, slot 3 — **empty for 2 DPC** |
| A11 (green) | — | CPU1 Ch2, slot 3 — **empty for 2 DPC** |
| A12 (green) | — | CPU1 Ch3, slot 3 — **empty for 2 DPC** |
| B1 (white) | **32GB** | CPU2 Ch0, slot 1 |
| B2 (white) | **32GB** | CPU2 Ch1, slot 1 |
| B3 (white) | 16GB | CPU2 Ch2, slot 1 |
| B4 (white) | 16GB | CPU2 Ch3, slot 1 |
| B5 (black) | 16GB | CPU2 Ch0, slot 2 |
| B6 (black) | 16GB | CPU2 Ch1, slot 2 |
| B7 (black) | 16GB | CPU2 Ch2, slot 2 |
| B8 (black) | 16GB | CPU2 Ch3, slot 2 |
| B9 (green) | — | CPU2 Ch0, slot 3 — **empty for 2 DPC** |
| B10 (green) | — | CPU2 Ch1, slot 3 — **empty for 2 DPC** |
| B11 (green) | — | CPU2 Ch2, slot 3 — **empty for 2 DPC** |
| B12 (green) | — | CPU2 Ch3, slot 3 — **empty for 2 DPC** |

**Larvikite gets the freed 16GB sticks** — 8 of 9 sticks used, 9th is a spare.
Same 128GB capacity, same 2133 MT/s (E5-2690 v3 max), but all 8 channels
active instead of 4 — roughly doubles memory parallelism.

**R530 Channel Mapping:**

| | Channel 0 | Channel 1 | Channel 2 | Channel 3 |
|--|-----------|-----------|-----------|-----------|
| CPU1 | A1, A5 | A2, A6 | A3, A7 | A4, A8 |
| CPU2 | B1 | B2 | B3 | B4 |

**Larvikite AFTER — 8x 16GB = 128GB @ 2133 MT/s, 1 DPC:**

| Slot | Size | Notes |
|------|------|-------|
| A1 (white) | 16GB | CPU1 Ch0 |
| A2 (white) | 16GB | CPU1 Ch1 |
| A3 (white) | 16GB | CPU1 Ch2 |
| A4 (white) | 16GB | CPU1 Ch3 |
| A5 (black) | — | |
| A6 (black) | — | |
| A7 (black) | — | |
| A8 (black) | — | |
| B1 (white) | 16GB | CPU2 Ch0 |
| B2 (white) | 16GB | CPU2 Ch1 |
| B3 (white) | 16GB | CPU2 Ch2 |
| B4 (white) | 16GB | CPU2 Ch3 |

**Effective bandwidth improvement (labradorite):**
- Fixed dead channel on CPU1 (was 0 DPC, now 2 DPC)
- All channels from 1866 → 2400 MT/s
- Combined improvement: **~35-40% bandwidth gain**
- Estimated 14B model speed: **13-16 tok/s** (up from 10-12)

### 0.3 Benchmarking (Before and After)

A benchmark script is included (`benchmark.sh`) that captures memory bandwidth,
CPU info, NUMA topology, and optionally Ollama inference speed. Run it on both
nodes before and after the upgrade.

**Before the upgrade (baseline):**

```bash
# Copy benchmark.sh to both nodes
scp benchmark.sh root@labradorite:/root/
scp benchmark.sh root@larvikite:/root/

# Run on labradorite (system-level only, Ollama not set up yet)
ssh root@labradorite 'chmod +x /root/benchmark.sh && /root/benchmark.sh'

# Run on larvikite
ssh root@larvikite 'chmod +x /root/benchmark.sh && /root/benchmark.sh'
```

**After the upgrade + Ollama setup:**

```bash
# System-level retest on labradorite
ssh root@labradorite '/root/benchmark.sh'

# System-level retest on larvikite (got memory redistribution)
ssh root@larvikite '/root/benchmark.sh'

# LLM benchmark from inside the dragonglass LXC
pct enter 200
# Copy benchmark.sh into the LXC first, then:
./benchmark.sh --with-ollama
```

**Comparing results:**

```bash
# Quick comparison of key metrics
grep -E 'Triad:|tok/s|Configured Memory Speed|Model name' \
  ./benchmark-results/labradorite-*.txt

# Full diff
diff benchmark-results/labradorite-*-BEFORE.txt benchmark-results/labradorite-*-AFTER.txt
```

**Key metrics to watch:**
- **STREAM Triad** — raw memory bandwidth in MB/s (expect ~35-40% improvement)
- **Configured Memory Speed** — should go from 1866 to 2400 MT/s
- **Ollama tok/s** — generation speed per model (expect ~30% improvement)
- **Prompt eval tok/s** — prompt processing speed (benefits from extra cores)

### 0.4 Post-Upgrade Verification

```bash
# After boot, verify CPUs
lscpu | grep "Model name"
# Should show: Intel(R) Xeon(R) CPU E5-2699 v4 @ 2.20GHz

# Verify memory speed
dmidecode -t memory | grep "Configured Memory Speed" | head -4
# Should show: 2400 MT/s

# Verify total memory
free -h
# Should show ~320GB total

# Quick stress test
stress-ng --cpu 44 --timeout 60s --metrics-brief
```

---

## Part 1: LXC Container on Labradorite

### 1.1 Create the LXC Container

From the Proxmox web UI or CLI on labradorite:

```bash
# Download a Debian 12 template if not already cached
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Create the container
# Adjust storage target (alpha or beta) as needed
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname dragonglass \
  --memory 65536 \
  --swap 4096 \
  --cores 8 \
  --rootfs alpha:50 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --start 1
```

> **Note:** Adjust `--net0` bridge and IP config to match your network. If you use
> static IPs, replace `ip=dhcp` with `ip=10.x.x.x/24,gw=10.x.x.1` as appropriate.

> **Resource rationale:** 64GB RAM is generous headroom for a 14B model (~9GB) plus
> Open WebUI, Docker overhead, and potential future model upgrades. 8 cores is
> plenty for single-user inference. Scale down if needed — 32GB and 4 cores would
> also work for 14B models.

### 1.2 Initial Container Setup

```bash
# Enter the container
pct enter 200

# Update and install essentials
apt update && apt upgrade -y
apt install -y curl wget git sudo ca-certificates gnupg lsb-release

# Install Docker (for Open WebUI)
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker
```

### 1.3 Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh

# Verify it's running
systemctl status ollama

# Bind to all interfaces so Open WebUI (Docker) can reach it
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF

systemctl daemon-reload
systemctl restart ollama
```

### 1.4 Pull Initial Models

```bash
# Primary coding model — best quality-to-size ratio for your hardware
ollama pull qwen2.5-coder:14b

# Reasoning model for more complex tasks
ollama pull deepseek-r1:14b

# Quick/lightweight model for simple tasks
ollama pull qwen2.5-coder:7b

# Optional: test a generation
ollama run qwen2.5-coder:14b "Write a Python function to parse CIDR notation"
```

> **Expected performance on labradorite (CPU inference, DDR4-2400, 8 channels, post-upgrade):**
>
> | Model | RAM Usage | Speed (approx) |
> |-------|-----------|----------------|
> | qwen2.5-coder:7b (Q4) | ~4.5GB | 25-32 tok/s |
> | qwen2.5-coder:14b (Q4) | ~9GB | 13-16 tok/s |
> | deepseek-r1:14b (Q4) | ~9GB | 13-16 tok/s |
>
> These are estimates. Benchmark after setup with:
> `curl http://localhost:11434/api/generate -d '{"model":"qwen2.5-coder:14b","prompt":"Hello","stream":false}' | jq '.eval_count / .eval_duration * 1e9'`

### 1.5 Deploy Open WebUI

```bash
# Generate a persistent secret key
export WEBUI_SECRET=$(openssl rand -hex 32)
echo "WEBUI_SECRET_KEY=${WEBUI_SECRET}" >> /root/.env

# Create docker-compose directory
mkdir -p /opt/open-webui
cat > /opt/open-webui/docker-compose.yml << 'YAML'
version: "3.8"

services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
      - WEBUI_AUTH=true
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - open-webui-data:/app/backend/data
    restart: unless-stopped

volumes:
  open-webui-data:
YAML

# Create .env for docker-compose
cat > /opt/open-webui/.env << EOF
WEBUI_SECRET_KEY=${WEBUI_SECRET}
EOF

# Start it
cd /opt/open-webui
docker compose up -d

# Verify
docker compose logs -f
# Wait for "Uvicorn running on http://0.0.0.0:8080"
# Ctrl+C to exit logs
```

### 1.6 Access Open WebUI

1. Open browser on your Windows workstation: `http://dragonglass:3000`
   (or use the container's IP if hostname resolution isn't set up)
2. Create your admin account on first visit
3. Select a local model from the dropdown (e.g., qwen2.5-coder:14b)
4. Start chatting

> **Claude stays in its own tab at claude.ai.** Open WebUI is local models only.
> Two bookmarks, two tools, each doing what it's best at.

### 1.7 Verify the Full Stack

```bash
# Test Ollama directly
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5-coder:14b","prompt":"Write a bash one-liner to find all files modified in the last 24 hours","stream":false}' \
  | jq -r '.response'

# Test from your Windows browser
# Navigate to http://dragonglass:3000
# Select qwen2.5-coder:14b from the model dropdown
# Send a test message
```

---

## Part 2: ComfyUI Image Generation on Windows

### 2.1 Prerequisites

- Windows 10/11 with WSL2 enabled
- NVIDIA drivers installed (Game Ready or Studio — you already have these for the 2080 Ti)
- Docker Desktop with WSL2 backend, OR Docker inside WSL2 directly

### 2.2 Install NVIDIA Container Toolkit in WSL2

```powershell
# From PowerShell, ensure WSL2 is set up with Ubuntu
wsl --install -d Ubuntu-24.04
```

```bash
# Inside WSL2 Ubuntu:

# Add NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

# Install Docker inside WSL2
curl -fsSL https://get.docker.com | sh
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify GPU access
sudo docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
# Should show your 2080 Ti
```

### 2.3 Deploy ComfyUI

```bash
# Create working directory
mkdir -p ~/comfyui && cd ~/comfyui

cat > docker-compose.yml << 'YAML'
version: "3.8"

services:
  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest
    container_name: comfyui
    ports:
      - "8188:8188"
    volumes:
      - ./models:/opt/ComfyUI/models
      - ./output:/opt/ComfyUI/output
      - ./input:/opt/ComfyUI/input
      - ./custom_nodes:/opt/ComfyUI/custom_nodes
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    restart: unless-stopped
YAML

docker compose up -d
```

> **Note:** The ai-dock image is one popular option. If it doesn't suit,
> alternatives include `yanwk/comfyui-boot` or building from the official
> ComfyUI repo. Check current recommendations at r/comfyui as images
> evolve quickly.

### 2.4 Download Models

```bash
# SD 1.5 — lightweight, runs great on 11GB, good for proving the workflow
cd ~/comfyui/models/checkpoints
wget https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors

# SDXL — higher quality, tighter fit on 11GB but doable
wget https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors

# ControlNet models (for spatial consistency)
cd ~/comfyui/models/controlnet

# Canny edge detection (locks structure while regenerating detail)
wget https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth

# Depth map (perspective/spatial relationships)
wget https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11f1p_sd15_depth.pth

# Inpainting model
cd ~/comfyui/models/checkpoints
wget https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors
```

> **VRAM management on 2080 Ti:**
> - Close Unity, YouTube, and other GPU-hungry apps before generating
> - Start with SD 1.5 (needs ~4GB for model, leaves room for generation)
> - SDXL will need most of your available VRAM — close everything else first
> - ComfyUI has `--lowvram` and `--novram` flags if you hit OOM errors
> - Generation is bursty: VRAM is only claimed during the 30-60s generation window

### 2.5 Install Essential Custom Nodes

Access ComfyUI at `http://localhost:8188`, then install via ComfyUI Manager
or clone directly:

```bash
cd ~/comfyui/custom_nodes

# ComfyUI Manager (install/manage other nodes from the UI)
git clone https://github.com/ltdrdata/ComfyUI-Manager.git

# ControlNet preprocessors (Canny, depth, OpenPose, etc.)
git clone https://github.com/Fannovel16/comfyui_controlnet_aux.git

# IP-Adapter (style consistency across generations)
git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git

# Restart ComfyUI to load new nodes
docker compose restart
```

### 2.6 Core Workflows for Game Concept Art

**Workflow 1: Iterative Concept Art Refinement (Inpainting)**
1. Generate initial concept from text prompt
2. Mask region to refine (e.g., doorway, lighting, texture)
3. Regenerate ONLY the masked region with new prompt
4. Repeat until satisfied — no regression on unmasked areas

**Workflow 2: Spatial-Accurate Overhead Maps (ControlNet + Depth)**
1. Sketch rough room layout (even in MS Paint)
2. Feed sketch as ControlNet Canny input
3. Generate detailed art constrained to your layout
4. Structure stays locked, detail gets generated on top

**Workflow 3: Seamless Texture Generation**
1. Use SD 1.5 with tiling-specific models or LoRAs
2. Generate material textures (stone, wood, metal, fabric)
3. Output is seamlessly tileable for game engine import

**Workflow 4: Character Consistency (IP-Adapter + LoRA)**
1. Create reference images for key characters
2. Use IP-Adapter to maintain visual consistency across poses/scenes
3. Optional: train a LoRA on your art style for the project

---

## Part 3: Day-to-Day Usage Guide

### Model Selection Cheat Sheet

| Task | Where | Model |
|------|-------|-------|
| Code skeleton / boilerplate | Open WebUI → local | qwen2.5-coder:14b |
| "What does this config do" | Open WebUI → local | qwen2.5-coder:14b |
| Runbook / doc drafting | Open WebUI → local | qwen2.5-coder:14b |
| Quick syntax question | Open WebUI → local | qwen2.5-coder:7b |
| Chain-of-thought reasoning | Open WebUI → local | deepseek-r1:14b |
| CloudFormation deep debugging | claude.ai | Claude Pro (Opus/Sonnet) |
| Multi-system infra analysis | claude.ai | Claude Pro (Opus/Sonnet) |
| PKI / complex pipeline issues | claude.ai | Claude Pro (Opus/Sonnet) |
| Concept art generation | ComfyUI (localhost:8188) | SD 1.5 / SDXL |
| Texture generation | ComfyUI (localhost:8188) | SD 1.5 + tiling |
| Inpainting / refinement | ComfyUI (localhost:8188) | SD 1.5 + ControlNet |

### When to Reach for Claude

Ask yourself: "Does this require holding a lot of interconnected context and
reasoning across multiple systems?" If yes → Claude. If it's a single-concept
question or generation task → local.

---

## Part 4: Maintenance

### Updating Models

```bash
# SSH into labradorite, enter the dragonglass LXC
pct enter 200

# Update Ollama models
ollama pull qwen2.5-coder:14b
ollama pull deepseek-r1:14b

# Check for new models worth trying
ollama list
```

### Updating Open WebUI

```bash
cd /opt/open-webui
docker compose pull
docker compose up -d
```

### Updating ComfyUI (on Windows, in WSL2)

```bash
cd ~/comfyui
docker compose pull
docker compose up -d
```

### Monitoring LXC Resource Usage

```bash
# From labradorite host
pct exec 200 -- free -h
pct exec 200 -- ollama ps  # shows loaded models and VRAM/RAM usage
```

---

## Part 5: Future Upgrades (When/If)

These are not required. The spec above is the complete, zero-cost solution.

| Trigger | Upgrade | Cost | Benefit |
|---------|---------|------|---------|
| Local 14B feels too dumb | Mac Mini M4 Pro 48GB | ~$2,000 | 32B models at 2x speed |
| Image gen too slow / want FLUX | RTX 5090 (replaces 2080 Ti) | ~$2,000 | 32GB VRAM, FLUX support, faster gen |
| Both of the above | RTX 5090 build (replaces Mac Mini AND 2080 Ti) | ~$5-6,000 | One box for everything |
| Open-weight models match Claude | Cancel Claude Pro | -$20/mo | Fully local, $0/mo |

---

## Quick-Start Checklist

**Phase 0 — Setup + Baseline**
- [ ] Order 2x E5-2699 v4 (SR2JS) + thermal paste
- [x] Run `operations/proxmox/inventory.sh` on cluster — confirm host/VM mapping
- [x] Create LXC container `dragonglass` (ID 200) on labradorite
- [x] Install Docker in the LXC
- [x] Install Ollama, bind to 0.0.0.0
- [x] Pull qwen2.5-coder:14b, deepseek-r1:14b, qwen2.5-coder:7b
- [x] Deploy Open WebUI via docker-compose
- [x] Access from Windows browser at http://dragonglass.local:3000, create admin account
- [x] Test local model chat through Open WebUI
- [ ] Copy benchmark.sh to both nodes + inside dragonglass
- [ ] **Benchmark A — VMs running (normal daily state):**
  - [ ] `benchmark.sh --host labradorite-vms-on` on labradorite
  - [ ] `benchmark.sh --with-ollama --host dragonglass-vms-on` inside dragonglass
- [ ] **Benchmark B — VMs stopped (isolated):**
  - [ ] Stop all non-dragonglass VMs/CTs on labradorite
  - [ ] `benchmark.sh --host labradorite-vms-off` on labradorite
  - [ ] `benchmark.sh --with-ollama --host dragonglass-vms-off` inside dragonglass
  - [ ] Restart VMs
- [ ] **Compare A vs B** — if tok/s difference is negligible, VMs can stay; if significant, plan migration
- [ ] **Run benchmark.sh on larvikite (BEFORE baseline)**

**Phase 1 — Hardware Upgrade**
- [ ] Shut down labradorite (migrate VMs first only if Phase 0 showed they matter)
- [ ] Shut down larvikite
- [ ] Swap CPUs in labradorite, apply thermal paste
- [ ] Pull 4x 32GB from larvikite → labradorite white slots
- [ ] Populate labradorite per optimized 2 DPC layout (see 0.2)
- [ ] Backfill larvikite with freed 16GB sticks
- [ ] Boot both, verify CPUs and DDR4-2400 speed in BIOS/dmidecode
- [ ] Restore VMs if migrated
- [ ] **Run benchmark.sh on labradorite (AFTER)**
- [ ] **Run benchmark.sh on larvikite (AFTER)**
- [ ] **Run benchmark.sh --with-ollama inside dragonglass (AFTER)**
- [ ] Compare STREAM Triad and tok/s results — confirm improvement

**Phase 2 — Image Generation (ComfyUI)**
- [ ] Set up WSL2 + NVIDIA Container Toolkit on Windows
- [ ] Deploy ComfyUI in WSL2 Docker
- [ ] Download SD 1.5 checkpoint + ControlNet models
- [ ] Test basic text-to-image generation
- [ ] Test inpainting workflow (mask + regenerate region)

**Phase 3 — Cut Over**
- [ ] Cancel ChatGPT subscription
- [ ] Downgrade Claude to Pro ($20/mo)
- [ ] Run for 1 month, evaluate whether local speed is sufficient

**Phase 4 — Backups**
- [ ] Design backup strategy for dragonglass (Open WebUI data, custom modelfiles, workflows)
- [ ] Implement and test backup schedule
- [ ] Verify restore process

**Phase 5 — GPU Offload (stretch goal)**
- [ ] Install Ollama on Windows PC (RTX 2080 Ti, 11GB VRAM)
- [ ] Bind to network: `OLLAMA_HOST=0.0.0.0:11434`
- [ ] Pull models (7B fits fully in VRAM, 14B mostly fits)
- [ ] Add PC as second Ollama backend in Open WebUI admin settings
- [ ] Test GPU inference speed vs CPU baseline
- [ ] Dual-backend workflow: GPU when PC is on, CPU fallback when off

**Phase 6 — Dedicated Server GPU (if Phase 5 proves value)**

*Goal: always-on GPU inference fast enough for agentic coding (tool use, inline edits, multi-step reasoning) — not just chat. Target model: 32B-class (e.g. Qwen2.5-Coder:32B) with reliable tool-call support.*

GPU options (pick based on budget and Phase 5 learnings):

| Card | VRAM | Bus | 14B tok/s | 32B Q4 tok/s | Street Price | Notes |
|------|------|-----|-----------|--------------|--------------|-------|
| Tesla V100-PCIE-32GB | 32GB HBM2 | PCIe | 40-60 | 15-25 | $300-500 | Passive, server-native, cheapest path to 32GB |
| RTX 3090 | 24GB GDDR6X | PCIe | 50-80 | 10-15 (tight) | $600-800 | Active cooling, needs airflow planning in R730 |
| RTX 4090 | 24GB GDDR6X | PCIe | 80-120 | 15-25 (tight) | $1200-1500 | Fastest single-GPU option, 450W TDP, may need PSU upgrade |
| RTX A6000 | 48GB GDDR6 | PCIe | 50-70 | 25-35 | $1500-2500 | 48GB fits 70B Q4, passive, built for servers |

*32B Q4 is ~18-20GB — fits comfortably in 32GB+ cards, tight on 24GB (leaves no room for context). 24GB cards top out at 14B comfortably or 32B with aggressive quantization.*

Hardware install:
- [ ] Select and acquire GPU based on budget/performance target
- [ ] Install in labradorite R730 PCIe x16 slot (riser 3 confirmed, PCIe power confirmed)
- [ ] Enable IOMMU in BIOS for GPU passthrough
- [ ] Configure Proxmox PCI passthrough to dragonglass LXC
- [ ] Install NVIDIA drivers + CUDA inside container
- [ ] IPMI fan control script to override Dell thermal panic (non-Dell GPU = 100% fans)
- [ ] Benchmark: tok/s on 14B and 32B models vs CPU baseline

Agentic coding eval:
- [ ] Install Aider in dragonglass (`pip install aider-chat`)
- [ ] Configure Aider to use local Ollama backend
- [ ] Pull Qwen2.5-Coder:32B (or best available 32B coder at the time)
- [ ] Test suite: give Aider a small repo and run these tasks, score pass/fail
  - [ ] "Add input validation to function X" — expects targeted inline edit, not full-file regen
  - [ ] "Write tests for module Y" — expects new file creation
  - [ ] "Find and fix the bug in Z" — expects read → diagnose → patch cycle
  - [ ] "Refactor class A to use composition instead of inheritance" — multi-file coordinated edits
- [ ] Compare tool-call success rate: 14B vs 32B vs 2080 Ti offload (Phase 5 baseline)
- [ ] If 32B agentic eval passes >80% of tasks: retire 2080 Ti offload, server GPU is primary
- [ ] If not: evaluate whether a larger model (70B Q4 on 48GB card) or a different agentic framework improves results
