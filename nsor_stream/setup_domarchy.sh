#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "⚡ Initializing Domarchy (Dockerized Omarchy Arch QEMU)"
echo "=========================================================="

# 1. Clean disk space to ensure 75GB+ free space
echo "[1/6] Maximizing runner NVMe storage..."
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache
df -h /

# 2. Install host accelerators (aria2 for high-speed download, xrdp for RDP bridging)
echo "[2/6] Installing aria2, xrdp and cloudflared..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y aria2 xrdp

# Install cloudflared for one-click browser GUI link
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared

# 3. Configure XRDP as high-performance VNC Proxy (Port 3389 -> QEMU Port 5900)
echo "[3/6] Configuring XRDP to QEMU VNC bridge..."
sudo tee /etc/xrdp/xrdp.ini > /dev/null << 'EOF'
[globals]
ini_version=1
port=3389
fork=true
crypt_level=low
max_bpp=24

[vnc]
name=Domarchy-Arch
lib=libvnc.so
ip=127.0.0.1
port=5900
username=na
password=
EOF

sudo systemctl enable xrdp
sudo systemctl restart xrdp

# 4. Multi-stream parallel download of the 6.3 GB Omarchy ISO
echo "[4/6] Pre-caching Omarchy ISO (6.27 GB) with 16 parallel threads..."
sudo mkdir -p /mnt/domarchy_data /mnt/domarchy_shared
sudo chmod -R 777 /mnt/domarchy_data /mnt/domarchy_shared

# 16 connections for blazing fast 150-200 MB/s download
aria2c -x 16 -s 16 -k 1M -j 16 \
  "https://iso.omarchy.org/omarchy-4.0.0.iso" \
  -d /mnt/domarchy_data \
  -o omarchy.iso

ls -lh /mnt/domarchy_data/omarchy.iso

# 5. Launch Domarchy Docker Container with KVM Acceleration
echo "[5/6] Launching Domarchy QEMU Engine..."
sudo chmod 666 /dev/kvm 2>/dev/null || true

KVM_FLAG=""
if [ -e /dev/kvm ]; then
  echo ">>> Hardware KVM Acceleration detected: ENABLED"
  KVM_FLAG="--device /dev/kvm"
else
  echo ">>> Hardware KVM not found: Falling back to TCG"
fi

docker run -d \
  --name domarchy \
  --restart unless-stopped \
  $KVM_FLAG \
  -p 8900:8900 \
  -p 5900:5900 \
  -e MEMORY=10G \
  -e CPUS=4 \
  -v /mnt/domarchy_data:/data \
  -v /mnt/domarchy_shared:/shared \
  overthinkinglabs/domarchy:latest

sleep 5
docker ps

# 6. Start Cloudflare Tunnel for instant one-click browser link
echo "[6/6] Launching Cloudflare public web bridge..."
nohup cloudflared tunnel --url http://localhost:8900 --no-autoupdate > /tmp/cf.log 2>&1 &

CF_URL=""
for i in $(seq 1 20); do
  sleep 1
  CF_URL=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /tmp/cf.log | head -n 1 || true)
  if [ -n "$CF_URL" ]; then
    break
  fi
done

echo "CLOUDFLARE_URL=${CF_URL}" >> /tmp/domarchy_env.txt
echo "=========================================================="
echo "⚡ Domarchy Live at: ${CF_URL}"
echo "=========================================================="
