#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "⚡ Initializing Native macOS Screen Sharing Workstation"
echo "=========================================================="

PASSWORD="${ENV_PASS:-s0sss101}"

# 1. Prevent display and system sleep
echo "[1/5] Configuring power management and display wake locks..."
sudo pmset -a disablesleep 1 sleep 0 displaysleep 0 2>/dev/null || true

# 2. Configure credentials
echo "[2/5] Configuring credentials..."
printf "%s\n%s\n" "$PASSWORD" "$PASSWORD" | sudo passwd runner 2>/dev/null || true

# 3. Enable Apple Remote Desktop (ARD) and Screen Sharing
echo "[3/5] Activating Apple Remote Desktop (ARD) service..."
# Enable Remote Management for all users with full privileges
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on \
  -allowAccessFor -allUsers -privs -all || true

# Configure legacy VNC password compatibility for Remmina, TigerVNC, and web clients
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$PASSWORD" || true

# Restart ARDAgent daemon
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -restart -agent -console || true

# Ensure screensharing launch daemon is enabled and loaded
sudo launchctl enable system/com.apple.screensharing 2>/dev/null || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

sleep 2
echo "Verifying local Screen Sharing / VNC port status:"
netstat -an | grep 5900 || sudo lsof -i :5900 || true

# 4. Optional web-based noVNC bridge on port 8900
echo "[4/5] Setting up local Web GUI accelerator..."
python3 -m pip install --quiet --break-system-packages websockify 2>/dev/null || pip3 install --quiet websockify 2>/dev/null || true
curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz | tar xz -C /tmp
rm -rf /tmp/novnc
mv /tmp/noVNC-1.6.0 /tmp/novnc
cp /tmp/novnc/vnc.html /tmp/novnc/index.html

# Launch websockify in background
nohup python3 -m websockify --web /tmp/novnc 8900 localhost:5900 > /tmp/websockify.log 2>&1 &

# 5. Start Cloudflare Tunnel for one-click browser access
echo "[5/5] Launching Cloudflare web tunnel..."
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64 -o /tmp/cloudflared 2>/dev/null || true
else
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64 -o /tmp/cloudflared 2>/dev/null || true
fi

CF_URL=""
if [ -f /tmp/cloudflared ]; then
  chmod +x /tmp/cloudflared
  xattr -d com.apple.quarantine /tmp/cloudflared 2>/dev/null || true
  sudo mv /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
  nohup cloudflared tunnel --url http://localhost:8900 --no-autoupdate > /tmp/cf.log 2>&1 &

  for i in $(seq 1 25); do
    sleep 1
    CF_URL=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null | head -n 1 || true)
    if [ -n "$CF_URL" ]; then
      break
    fi
  done
fi

echo "CLOUDFLARE_URL=${CF_URL}" > /tmp/macos_env.txt
echo "=========================================================="
echo "⚡ Native macOS Screen Sharing Live on Port 5900"
if [ -n "$CF_URL" ]; then
  echo "⚡ Web GUI Live at: ${CF_URL}"
fi
echo "=========================================================="
