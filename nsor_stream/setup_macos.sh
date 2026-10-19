#!/usr/bin/env bash
# ==============================================================================
# Native macOS Apple Silicon / macOS Latest Workstation Provisioning Engine
# Screen Sharing (VNC / ARD) + Tailscale + noVNC Web Gateway + Cloudflare Tunnel
# ==============================================================================

set -euo pipefail

# Ensure Homebrew and standard tool paths are available in PATH
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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

# 2. Configure credentials, auto-login & TCC Screen Recording permissions
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

# Grant TCC ScreenCapture, Accessibility and Input permissions to Screen Sharing services
python3 -c "
import sqlite3, time, os

now = int(time.time())
services = ['kTCCServiceScreenCapture', 'kTCCServiceAccessibility', 'kTCCServicePostEvent', 'kTCCServiceListenEvent']
clients = [
    ('com.apple.screensharing.agent', 0),
    ('com.apple.screensharing.daemon', 0),
    ('com.apple.RemoteDesktopAgent', 0),
    ('com.apple.AppleVNCServer', 0),
    ('/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent', 1),
    ('/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd', 1),
    ('/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent', 1),
]

for db_path in ['/Library/Application Support/com.apple.TCC/TCC.db', '/Users/runner/Library/Application Support/com.apple.TCC/TCC.db']:
    if not os.path.exists(db_path):
        continue
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        for s in services:
            for c, ct in clients:
                try:
                    cur.execute('''
                        INSERT OR REPLACE INTO access (
                            service, client, client_type, auth_value, auth_reason, auth_version,
                            indirect_object_identifier, last_modified
                        ) VALUES (?, ?, ?, 2, 1, 1, 'UNUSED', ?)
                    ''', (s, c, ct, now))
                except Exception:
                    pass
        conn.commit()
        conn.close()
    except Exception:
        pass
" 2>/dev/null || true
sudo killall tccd 2>/dev/null || true

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

pkill -f "python3.*vnc_bridge.py" 2>/dev/null || true
nohup python3 "$BRIDGE_SCRIPT" 5901 > /tmp/vnc_bridge.log 2>&1 &
sleep 1

# Configure PF redirection so connections to Port 5900 are routed through vnc_bridge (5901)
sudo sysctl -w net.inet.ip.forwarding=1 2>/dev/null || true

apply_pf_rules() {
  local ts_ip
  local utun_dev
  local en0_ip

  ts_ip=$(ifconfig 2>/dev/null | grep -E 'inet 100\.' | head -n 1 | awk '{print $2}' || true)
  en0_ip=$(ipconfig getifaddr en0 2>/dev/null || ifconfig en0 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
  
  cat << 'PFECHO' > /tmp/pf_vnc.conf
rdr pass on lo0 proto tcp from any to any port 5900 -> 127.0.0.1 port 5901
PFECHO

  if [ -n "$ts_ip" ]; then
    utun_dev=$(ifconfig 2>/dev/null | grep -B 2 "$ts_ip" | grep -E '^[a-z0-9]+:' | head -n 1 | cut -d: -f1 || true)
    if [ -n "$utun_dev" ]; then
      echo "rdr pass on $utun_dev inet proto tcp from any to any port 5900 -> $ts_ip port 5901" >> /tmp/pf_vnc.conf
    fi
  fi

  if [ -n "$en0_ip" ]; then
    echo "rdr pass on en0 inet proto tcp from any to any port 5900 -> $en0_ip port 5901" >> /tmp/pf_vnc.conf
  fi

  sudo pfctl -ef /tmp/pf_vnc.conf 2>/dev/null || true
}

apply_pf_rules

# Background watcher to ensure PF redirect stays active when Tailscale connects
nohup bash -c '
for i in $(seq 1 60); do
  ts_ip=$(ifconfig 2>/dev/null | grep -E "inet 100\." | head -n 1 | awk "{print \$2}" || true)
  if [ -n "$ts_ip" ]; then
    utun_dev=$(ifconfig 2>/dev/null | grep -B 2 "$ts_ip" | grep -E "^[a-z0-9]+:" | head -n 1 | cut -d: -f1 || true)
    if [ -n "$utun_dev" ]; then
      en0_ip=$(ipconfig getifaddr en0 2>/dev/null || ifconfig en0 2>/dev/null | grep "inet " | awk "{print \$2}" || true)
      cat << PFECHO > /tmp/pf_vnc.conf
rdr pass on lo0 proto tcp from any to any port 5900 -> 127.0.0.1 port 5901
rdr pass on $utun_dev inet proto tcp from any to any port 5900 -> $ts_ip port 5901
PFECHO
      if [ -n "$en0_ip" ]; then
        echo "rdr pass on en0 inet proto tcp from any to any port 5900 -> $en0_ip port 5901" >> /tmp/pf_vnc.conf
      fi
      sudo pfctl -ef /tmp/pf_vnc.conf 2>/dev/null || true
      break
    fi
  fi
  sleep 3
done
' >/dev/null 2>&1 &

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

old_types = '''        const clientTypes = [
            securityTypeNone,
            securityTypeVNCAuth,
            securityTypeRA2ne,
            securityTypeTight,
            securityTypeVeNCrypt,
            securityTypeXVP,
            securityTypeARD,
            securityTypeMSLogonII,
            securityTypePlain,
        ];'''

new_types = '''        const clientTypes = [
            securityTypeNone,
            securityTypeVNCAuth,
        ];'''

if old_types in content:
    content = content.replace(old_types, new_types)
else:
    import re
    content = re.sub(r'const clientTypes = \[[^\]]*\];', new_types.strip(), content, count=1)

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
<meta http-equiv="refresh" content="0; url=vnc_lite.html?autoconnect=true&password=${PASSWORD}&scale=true&resize=scale">
<script>window.location.replace("vnc_lite.html?autoconnect=true&password=${PASSWORD}&scale=true&resize=scale");</script>
</head>
<body style="background:#1a1a1a;color:#eee;font-family:sans-serif;text-align:center;padding:50px;">
  <h2>Connecting to macOS Workstation...</h2>
  <p><a href="vnc_lite.html?autoconnect=true&password=${PASSWORD}&scale=true&resize=scale" style="color:#4da6ff;">Click here for Lightweight Viewer</a></p>
  <p><a href="vnc.html?autoconnect=true&password=${PASSWORD}&scale=true&resize=scale" style="color:#4da6ff;">Click here for Full UI Viewer</a></p>
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
echo "⚡ Native Screen Sharing: Port 5900 (Redirected to Bridge)"
echo "⚡ Universal VNC Bridge:  Port 5901 (Remmina / TigerVNC)"
echo "⚡ Web GUI (noVNC):       Port 8900"
if [ -n "$CF_URL" ]; then
  echo "⚡ Public Instant Web Access: $CF_URL"
fi
echo "=========================================================="
