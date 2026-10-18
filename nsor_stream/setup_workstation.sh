#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "⚡ Initializing Ultra-Fast Ubuntu XRDP Workstation"
echo "=========================================================="

# 1. Update and install packages non-interactively
echo "[1/5] Installing XFCE4, XRDP, and essential tools..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  xfce4 \
  xfce4-terminal \
  xfce4-goodies \
  xrdp \
  dbus-x11 \
  x11-xserver-utils \
  pavucontrol \
  pulseaudio \
  fonts-dejavu \
  fonts-liberation \
  ca-certificates \
  curl \
  wget

# 2. Install Google Chrome for immediate browser testing
echo "[2/5] Installing Google Chrome..."
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
sudo apt-get install -y /tmp/chrome.deb || sudo apt-get -f install -y
rm -f /tmp/chrome.deb

# 3. Configure XRDP and XFCE4 desktop session
echo "[3/5] Configuring XRDP and XFCE desktop..."
sudo adduser xrdp ssl-cert

echo "exec startxfce4" > /home/runner/.xsession
chmod +x /home/runner/.xsession
chown runner:runner /home/runner/.xsession

# Prevent DBus/XDG desync in startwm.sh
sudo sed -i '1s/^/unset DBUS_SESSION_BUS_ADDRESS\nunset XDG_RUNTIME_DIR\n/' /etc/xrdp/startwm.sh

# Optimize xrdp.ini for low latency 60 FPS
sudo sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini
sudo sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
sudo sed -i 's/^xserverbpp=.*/xserverbpp=24/' /etc/xrdp/xrdp.ini

# Prevent session termination on disconnect
sudo sed -i 's/KillDisconnected=true/KillDisconnected=false/g' /etc/xrdp/sesman.ini 2>/dev/null || true

# 4. Disable Polkit popups (colord, packagekit)
echo "[4/5] Configuring Polkit authorization..."
sudo mkdir -p /etc/polkit-1/localauthority/50-local.d
sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null << 'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes

[Allow PackageKit all Users]
Identity=unix-user:*
Action=org.freedesktop.packagekit.system-sources-refresh
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/02-allow-all.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0 ||
        action.id.indexOf("org.freedesktop.packagekit.") === 0) {
        return polkit.Result.YES;
    }
});
EOF

# Desktop icons for Chrome and Terminal
mkdir -p /home/runner/Desktop
cat << 'EOF' > /home/runner/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Browse the Web
Exec=google-chrome-stable --no-sandbox %U
Icon=google-chrome
Path=/home/runner
Terminal=false
StartupNotify=true
EOF

cat << 'EOF' > /home/runner/Desktop/terminal.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
StartupNotify=true
EOF

chmod +x /home/runner/Desktop/*.desktop
chown -R runner:runner /home/runner/Desktop

# Start XRDP Service
sudo systemctl enable xrdp
sudo systemctl restart xrdp
echo "[5/5] XRDP is active and running on port 3389."
