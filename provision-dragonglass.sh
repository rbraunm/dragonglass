#!/bin/bash
# =============================================================================
# Provision dragonglass LXC on labradorite
#
# Run this ON the Proxmox host (labradorite) as root.
# It creates the LXC container and installs Docker, Ollama, models,
# and Open WebUI inside it — everything needed before benchmarking.
#
# Usage:
#   chmod +x provision-dragonglass.sh
#   ./provision-dragonglass.sh
#
# After this completes:
#   1. Access Open WebUI at http://dragonglass:3000 and create admin account
#   2. Run benchmarks (see below)
# =============================================================================

set -euo pipefail

CTID=200
HOSTNAME="dragonglass"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

echo "============================================="
echo "  Provisioning dragonglass (CT $CTID)"
echo "============================================="

# ─────────────────────────────────────────────────
# Step 1: Download template if needed
# ─────────────────────────────────────────────────
echo ""
echo "[1/7] Checking for Debian 12 template..."
if ! pveam list local | grep -q "$TEMPLATE"; then
    echo "  Downloading template..."
    pveam update
    pveam download local "$TEMPLATE"
else
    echo "  Template already cached."
fi

# ─────────────────────────────────────────────────
# Step 2: Create the LXC container
# ─────────────────────────────────────────────────
echo ""
echo "[2/7] Creating LXC container $CTID..."
if pct status $CTID &>/dev/null; then
    echo "  ⚠ Container $CTID already exists!"
    echo "  Status: $(pct status $CTID)"
    read -p "  Destroy and recreate? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        pct stop $CTID 2>/dev/null || true
        pct destroy $CTID
        echo "  Destroyed. Recreating..."
    else
        echo "  Skipping creation, will provision inside existing container."
    fi
fi

if ! pct status $CTID &>/dev/null; then
    # ── Adjust storage and network to match your environment ──
    # storage: 'alpha' here — change to 'local-lvm' or whatever you use
    # network: bridge=vmbr0, ip=dhcp — change if you use static IPs
    pct create $CTID "local:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --memory 65536 \
        --swap 4096 \
        --cores 8 \
        --rootfs alpha:50 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --features nesting=1,keyctl=1 \
        --unprivileged 1 \
        --start 1

    echo "  Container created and started."
    echo "  Waiting for network..."
    sleep 10
else
    # Make sure it's running
    pct start $CTID 2>/dev/null || true
    sleep 5
fi

# ─────────────────────────────────────────────────
# Step 2b: AppArmor — allow Docker to run in unprivileged LXC
# ─────────────────────────────────────────────────
LXC_CONF="/etc/pve/lxc/${CTID}.conf"
if ! grep -q "lxc.apparmor.profile: unconfined" "$LXC_CONF" 2>/dev/null; then
    echo ""
    echo "[2b] Applying AppArmor unconfined profile for Docker support..."
    echo "lxc.apparmor.profile: unconfined" >> "$LXC_CONF"
    pct reboot $CTID
    echo "  Rebooting container..."
    sleep 10
else
    echo ""
    echo "[2b] AppArmor profile already set, skipping."
fi

# ─────────────────────────────────────────────────
# Step 3: Install essentials + Docker inside LXC
# ─────────────────────────────────────────────────
echo ""
echo "[3/7] Installing base packages and Docker..."
pct exec $CTID -- bash -c '
    # Fix locale warnings before anything else
    sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen en_US.UTF-8
    export LANG=en_US.UTF-8

    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq curl wget git sudo ca-certificates gnupg lsb-release gcc numactl python3 jq zstd
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo "  Docker version: $(docker --version)"
'

# ─────────────────────────────────────────────────
# Step 4: Install Ollama
# ─────────────────────────────────────────────────
echo ""
echo "[4/7] Installing Ollama..."
pct exec $CTID -- bash -c '
    curl -fsSL https://ollama.com/install.sh | sh

    # Bind to all interfaces so Docker (Open WebUI) can reach it
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/override.conf << EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF
    systemctl daemon-reload
    systemctl restart ollama

    # Wait for Ollama to be ready
    for i in $(seq 1 30); do
        if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
            echo "  Ollama is running."
            break
        fi
        sleep 1
    done
'

# ─────────────────────────────────────────────────
# Step 5: Pull models
# ─────────────────────────────────────────────────
echo ""
echo "[5/7] Pulling models (this will take a while)..."
echo "  Pulling qwen2.5-coder:14b..."
pct exec $CTID -- ollama pull qwen2.5-coder:14b

echo "  Pulling deepseek-r1:14b..."
pct exec $CTID -- ollama pull deepseek-r1:14b

echo "  Pulling qwen2.5-coder:7b..."
pct exec $CTID -- ollama pull qwen2.5-coder:7b

echo "  Models pulled:"
pct exec $CTID -- ollama list

# ─────────────────────────────────────────────────
# Step 6: Deploy Open WebUI
# ─────────────────────────────────────────────────
echo ""
echo "[6/7] Deploying Open WebUI..."
pct exec $CTID -- bash -c '
    WEBUI_SECRET=$(openssl rand -hex 32)

    mkdir -p /opt/open-webui
    cat > /opt/open-webui/docker-compose.yml << YAML
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://host.docker.internal:11434
      - WEBUI_SECRET_KEY=\${WEBUI_SECRET_KEY}
      - WEBUI_AUTH=true
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - open-webui-data:/app/backend/data
    restart: unless-stopped

volumes:
  open-webui-data:
YAML

    cat > /opt/open-webui/.env << EOF
WEBUI_SECRET_KEY=${WEBUI_SECRET}
EOF

    cd /opt/open-webui
    docker compose up -d

    echo "  Waiting for Open WebUI to start..."
    for i in $(seq 1 60); do
        if curl -s http://localhost:3000 >/dev/null 2>&1; then
            echo "  Open WebUI is up!"
            break
        fi
        sleep 2
    done
'

# ─────────────────────────────────────────────────
# Step 7: Quick smoke test
# ─────────────────────────────────────────────────
echo ""
echo "[7/7] Smoke test — hitting Ollama directly..."
echo "  (First inference loads the model into RAM — polling until ready...)"
pct exec $CTID -- bash -c '
    MAX_ATTEMPTS=24
    for i in $(seq 1 $MAX_ATTEMPTS); do
        RESPONSE=$(curl -s --max-time 10 http://localhost:11434/api/generate \
            -d "{\"model\":\"qwen2.5-coder:7b\",\"prompt\":\"Say hello in one sentence.\",\"stream\":false}" 2>/dev/null)
        if echo "$RESPONSE" | jq -e ".response" >/dev/null 2>&1; then
            REPLY=$(echo "$RESPONSE" | jq -r ".response" | head -3)
            TOK=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d[\"eval_count\"] / (d[\"eval_duration\"]/1e9):.1f} tok/s\")" 2>/dev/null || echo "N/A")
            echo "  Model says: $REPLY"
            echo "  Speed: $TOK"
            exit 0
        fi
        echo "  Attempt $i/$MAX_ATTEMPTS — model loading..."
        sleep 5
    done
    echo "  Smoke test failed after $MAX_ATTEMPTS attempts. Debug with:"
    echo "    pct exec 200 -- systemctl status ollama"
    echo "    pct exec 200 -- ollama list"
'

# ─────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  dragonglass provisioning complete!"
echo "============================================="
echo ""
echo "  Next steps:"
echo "  1. Open http://dragonglass:3000 in your browser"
echo "     (or use the container IP — check with: pct exec $CTID -- hostname -I)"
echo "  2. Create your admin account"
echo "  3. Test a chat with qwen2.5-coder:14b"
echo ""
echo "  Pre-upgrade benchmarks:"
echo "    # System-level on labradorite (run on host)"
echo "    ./benchmark.sh"
echo ""
echo "    # System-level on larvikite"
echo "    scp benchmark.sh root@larvikite:/root/"
echo "    ssh root@larvikite 'chmod +x /root/benchmark.sh && /root/benchmark.sh'"
echo ""
echo "    # LLM tok/s inside dragonglass"
echo "    # Copy benchmark.sh into the container first:"
echo "    pct push $CTID benchmark.sh /root/benchmark.sh"
echo "    pct exec $CTID -- chmod +x /root/benchmark.sh"
echo "    pct exec $CTID -- /root/benchmark.sh --with-ollama"
echo ""
