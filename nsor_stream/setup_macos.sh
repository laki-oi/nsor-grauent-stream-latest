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
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Prevent display sleep, screen locking, and idle sleep
echo "[1/6] Configuring power management and display wake locks..."
sudo pmset -a disablesleep 1 sleep 0 displaysleep 0 disksleep 0 2>/dev/null || true
defaults write com.apple.screensaver idleTime 0 2>/dev/null || true
defaults write com.apple.screensaver askForPassword 0 2>/dev/null || true
defaults write com.apple.screensaver askForPasswordDelay 0 2>/dev/null || true
nohup caffeinate -d -i -m -u >/dev/null 2>&1 &

# 2. Configure credentials & user accounts
echo "[2/6] Configuring user credentials and access rights..."
# Update password for runner
sudo dscl . -passwd /Users/runner "$PASSWORD" 2>/dev/null || true

# Update /etc/kcpassword so runner auto-logins with $PASSWORD without lock
python3 -c "
magic = bytes.fromhex('7d895223d2bcddeaa3b91f')
password = '${PASSWORD}'.encode('utf-8')
pad_len = len(magic) - (len(password) % len(magic))
if pad_len == 0: pad_len = len(magic)
padded = password + b'\x00' * pad_len
encoded = bytes([b ^ magic[i % len(magic)] for i, b in enumerate(padded)])
with open('/etc/kcpassword', 'wb') as f:
    f.write(encoded)
" 2>/dev/null || true
sudo chmod 600 /etc/kcpassword 2>/dev/null || true
sudo chown root:wheel /etc/kcpassword 2>/dev/null || true

# Configure loginwindow for seamless autoLoginUser
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser runner 2>/dev/null || true
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false 2>/dev/null || true

# Also create/ensure secondary admin user 'macuser' with the same password for SSH
sudo sysadminctl -addUser macuser -fullName "Mac User" -password "$PASSWORD" -admin 2>/dev/null || true
sudo dscl . -passwd /Users/macuser "$PASSWORD" 2>/dev/null || true

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

# 4. Launch Universal RFB / VNC Compatibility Bridge (Port 5901)
echo "[4/6] Launching Universal RFB Compatibility Bridge on port 5901..."
BRIDGE_SCRIPT="${DIR}/vnc_bridge.py"
if [ ! -f "$BRIDGE_SCRIPT" ]; then
  BRIDGE_SCRIPT="/tmp/vnc_bridge.py"
  curl -fsSL "https://raw.githubusercontent.com/laki-oi/nsor-grauent-stream-latest/main/nsor_stream/vnc_bridge.py" -o "$BRIDGE_SCRIPT" 2>/dev/null || true
fi

nohup python3 "$BRIDGE_SCRIPT" 5901 > /tmp/vnc_bridge.log 2>&1 &
sleep 1

# Optional PF redirection for port 5900 -> 5901 so Remmina connecting to 5900 gets bridge
echo "rdr pass on en0 proto tcp from any to any port 5900 -> 127.0.0.1 port 5901" > /tmp/pf_vnc.conf 2>/dev/null || true
echo "rdr pass on utun+ proto tcp from any to any port 5900 -> 127.0.0.1 port 5901" >> /tmp/pf_vnc.conf 2>/dev/null || true
sudo pfctl -ef /tmp/pf_vnc.conf 2>/dev/null || true

# 5. Set up local Web GUI accelerator (noVNC + websockify) on port 8900
echo "[5/6] Setting up Web GUI accelerator (noVNC + websockify)..."
python3 -m pip install --quiet --break-system-packages websockify 2>/dev/null || pip3 install --quiet websockify 2>/dev/null || true
curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz | tar -xz -C /tmp 2>/dev/null || true
rm -rf /tmp/novnc
mv /tmp/noVNC-1.6.0 /tmp/novnc 2>/dev/null || true

# Patch rfb.js to restrict supported security types to standard VNCAuth (Type 2)
# This completely prevents noVNC from attempting ARD auth which requires subtle crypto on HTTP
python3 -c "
with open('/tmp/novnc/core/rfb.js', 'r') as f:
    content = f.read()

# Replace _isSupportedSecurityType to only accept VNCAuth (2) and None (1)
target_func = '''    _isSupportedSecurityType(type) {
        const clientTypes = [
            securityTypeNone,
            securityTypeVNCAuth,
        ];

        return clientTypes.includes(type);
    }'''

import re
content = re.sub(
    r'_isSupportedSecurityType\(type\)\s*\{[^}]*\}',
    target_func.replace('\\', '\\\\'),
    content
)

with open('/tmp/novnc/core/rfb.js', 'w') as f:
    f.write(content)
" 2>/dev/null || true

# Add WebCrypto polyfill safeguard to vnc_lite.html and vnc.html
POLYFILL='<script>if(!window.crypto){window.crypto={};}if(!window.crypto.subtle){window.crypto.subtle={importKey:()=>Promise.reject(new Error("Subtle crypto unavailable on HTTP")),encrypt:()=>Promise.reject(new Error("Subtle crypto unavailable on HTTP")),decrypt:()=>Promise.reject(new Error("Subtle crypto unavailable on HTTP")),digest:()=>Promise.reject(new Error("Subtle crypto unavailable on HTTP")),generateKey:()=>Promise.reject(new Error("Subtle crypto unavailable on HTTP"))};}</script>'

if [ -f /tmp/novnc/vnc_lite.html ]; then
  sed -i.bak "s|<head>|<head>${POLYFILL}|g" /tmp/novnc/vnc_lite.html 2>/dev/null || true
fi
if [ -f /tmp/novnc/vnc.html ]; then
  sed -i.bak "s|<head>|<head>${POLYFILL}|g" /tmp/novnc/vnc.html 2>/dev/null || true
fi

# Configure default index.html to auto-redirect to vnc_lite.html with autologin
cat << EOF > /tmp/novnc/index.html
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="refresh" content="0; url=vnc_lite.html?password=${PASSWORD}&scale=true&resize=scale">
<script>window.location.replace("vnc_lite.html?password=${PASSWORD}&scale=true&resize=scale");</script>
</head>
<body style="background:#1a1a1a;color:#eee;font-family:sans-serif;text-align:center;padding:50px;">
  <h2>Connecting to macOS Workstation...</h2>
  <p><a href="vnc_lite.html?password=${PASSWORD}&scale=true&resize=scale" style="color:#4da6ff;">Click here if not redirected automatically</a></p>
</body>
</html>
EOF

# Launch websockify pointing to the universal bridge on 5901 (or fallback 5900)
pkill -f websockify 2>/dev/null || true
nohup python3 -m websockify --web /tmp/novnc 8900 localhost:5901 > /tmp/websockify.log 2>&1 &

# 6. Start Cloudflare Tunnel for instant one-click browser access
echo "[6/6] Launching Cloudflare web tunnel..."
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
  pkill -f cloudflared 2>/dev/null || true
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

echo "=========================================================="
echo "⚡ macOS Workstation Environment Ready."
echo "⚡ Native Screen Sharing: Port 5900 (Apple ARD)"
echo "⚡ Universal VNC Bridge:  Port 5901 (Remmina / TigerVNC)"
echo "⚡ Web GUI (noVNC):       Port 8900"
if [ -n "$CF_URL" ]; then
  echo "⚡ Public Instant Web Access: $CF_URL"
fi
echo "=========================================================="
