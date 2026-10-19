#!/usr/bin/env bash
# ==============================================================================
# Native macOS Apple Silicon / macOS Latest Workstation Provisioning Engine
# Screen Sharing (VNC / ARD) + Tailscale + noVNC Web Gateway + Cloudflare Tunnel
# ==============================================================================

set -euo pipefail

echo "=========================================================="
echo "🍏 Initializing Native macOS Screen Sharing Workstation"
echo "=========================================================="

PASSWORD="${ENV_PASS:-s0sss101}"

# 1. Prevent display sleep, screen locking, and idle sleep
echo "[1/6] Configuring power management and display wake locks..."
sudo pmset -a disablesleep 1 sleep 0 displaysleep 0 disksleep 0 2>/dev/null || true
defaults write com.apple.screensaver idleTime 0 2>/dev/null || true
nohup caffeinate -d -i -m -u >/dev/null 2>&1 &

# 2. Configure credentials & user accounts
echo "[2/6] Configuring user credentials and access rights..."
# Reset password for runner
sudo sysadminctl -resetPasswordFor runner -newPassword "$PASSWORD" 2>/dev/null || true

# Also create secondary admin user 'macuser' with the same password
sudo sysadminctl -addUser macuser -fullName "Mac User" -password "$PASSWORD" -admin 2>/dev/null || true

# Grant screen sharing and remote administration group access
sudo dscl . -append /Groups/com.apple.access_screensharing GroupMembership runner 2>/dev/null || true
sudo dscl . -append /Groups/com.apple.access_screensharing GroupMembership macuser 2>/dev/null || true
sudo dscl . -append /Groups/admin GroupMembership runner 2>/dev/null || true
sudo dscl . -append /Groups/admin GroupMembership macuser 2>/dev/null || true

# 3. Enable Apple Remote Desktop (ARD) and Screen Sharing
echo "[3/6] Activating Apple Remote Desktop (ARD) & VNC service..."
KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

# Enable Remote Management for all users with full privileges
sudo "$KICKSTART" -activate -configure -access -on \
  -allowAccessFor -allUsers -privs -all 2>/dev/null || true

# Configure legacy VNC password compatibility for Remmina, TigerVNC, and noVNC
sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$PASSWORD" 2>/dev/null || true

# Restart ARDAgent daemon
sudo "$KICKSTART" -restart -agent -console 2>/dev/null || true

# Ensure screensharing launch daemon is enabled and loaded
sudo launchctl enable system/com.apple.screensharing 2>/dev/null || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

sleep 2
echo "Verifying local Screen Sharing / VNC port status:"
netstat -an | grep 5900 || sudo lsof -i :5900 || true

# 4. Optional web-based noVNC bridge on port 8900
echo "[4/6] Setting up local Web GUI accelerator (noVNC + websockify)..."
python3 -m pip install --quiet --break-system-packages websockify 2>/dev/null || pip3 install --quiet websockify 2>/dev/null || true
curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz | tar -xz -C /tmp 2>/dev/null || true
rm -rf /tmp/novnc
mv /tmp/noVNC-1.6.0 /tmp/novnc 2>/dev/null || true
cp /tmp/novnc/vnc.html /tmp/novnc/index.html 2>/dev/null || true

# Launch websockify in background
nohup python3 -m websockify --web /tmp/novnc 8900 localhost:5900 > /tmp/websockify.log 2>&1 &

# 5. Start Cloudflare Tunnel for instant one-click browser access
echo "[5/6] Launching Cloudflare web tunnel..."
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz | tar -xz -C /tmp 2>/dev/null || true
else
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz | tar -xz -C /tmp 2>/dev/null || true
fi

CF_URL=""
if [ -f /tmp/cloudflared ]; then
  chmod +x /tmp/cloudflared
  xattr -d com.apple.quarantine /tmp/cloudflared 2>/dev/null || true
  sudo mv /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
  nohup cloudflared tunnel --url http://localhost:8900 --no-autoupdate > /tmp/cf.log 2>&1 &

  for i in $(seq 1 30); do
    sleep 1
    CF_URL=$(grep -o 'https://[-a-zA-Z0-9.]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null | head -n 1 || true)
    if [ -n "$CF_URL" ]; then
      break
    fi
  done
fi

echo "CLOUDFLARE_URL=${CF_URL}" > /tmp/macos_env.txt

# 6. Final verification
echo "[6/6] macOS Workstation Environment Ready."
echo "=========================================================="
echo "⚡ Native macOS Screen Sharing Live on Port 5900 (VNC)"
echo "⚡ Web GUI Live on Port 8900 (noVNC)"
if [ -n "$CF_URL" ]; then
  echo "⚡ Public Instant Web Access: $CF_URL"
fi
echo "=========================================================="
