#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "⚡ Initializing Native macOS Screen Sharing Workstation"
echo "=========================================================="

PASSWORD="${ENV_PASS:-s0sss101}"

# 1. Prevent display and system sleep
echo "[1/5] Configuring power management and display wake locks..."
sudo pmset -a disablesleep 1 sleep 0 displaysleep 0 || true

# 2. Set credentials for user runner
echo "[2/5] Setting credentials for macOS user 'runner'..."
sudo dscl . -passwd /Users/runner "$PASSWORD"

# 3. Enable Apple Remote Desktop (ARD) and Screen Sharing
echo "[3/5] Activating Apple Remote Desktop (ARD) service..."
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on \
  -restart -agent -privs -all \
  -allowAccessFor -allUsers

# Enable universal VNC password compatibility for Remmina and TigerVNC
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -yes -setvncpw -vncpw "$PASSWORD"

# Ensure the native screen sharing launch daemon is loaded
sudo launchctl enable system/com.apple.screensharing || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

# 4. Optional web-based noVNC bridge on port 8900
echo "[4/5] Setting up local Web GUI accelerator..."
pip3 install --quiet websockify || true
curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz | tar xz -C /tmp
mv /tmp/noVNC-1.6.0 /tmp/novnc
cp /tmp/novnc/vnc.html /tmp/novnc/index.html
nohup websockify --web /tmp/novnc 8900 localhost:5900 > /tmp/websockify.log 2>&1 &

# 5. Start Cloudflare Tunnel for one-click browser access
echo "[5/5] Launching Cloudflare web tunnel..."
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64 -o /tmp/cloudflared
else
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64 -o /tmp/cloudflared
fi
chmod +x /tmp/cloudflared
sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
nohup cloudflared tunnel --url http://localhost:8900 --no-autoupdate > /tmp/cf.log 2>&1 &

CF_URL=""
for i in $(seq 1 20); do
  sleep 1
  CF_URL=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /tmp/cf.log | head -n 1 || true)
  if [ -n "$CF_URL" ]; then
    break
  fi
done

echo "CLOUDFLARE_URL=${CF_URL}" > /tmp/macos_env.txt
echo "=========================================================="
echo "⚡ Native macOS Screen Sharing Live on Port 5900"
if [ -n "$CF_URL" ]; then
  echo "⚡ Web GUI Live at: ${CF_URL}"
fi
echo "=========================================================="
