#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "⚡ Initializing Ultra-Fast Ubuntu XRDP Workstation"
echo "=========================================================="

# 1. Update and install packages non-interactively
echo "[1/5] Installing XFCE4, XRDP, xorgxrdp, and essential tools..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xfce4 \
  xfce4-terminal \
  xfce4-goodies \
  xrdp \
  xorgxrdp \
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

# Bulletproof startwm.sh with dedicated dbus-run-session
sudo tee /etc/xrdp/startwm.sh > /dev/null << 'EOF'
#!/bin/sh
if test -r /etc/profile; then
    . /etc/profile
fi
if test -r ~/.profile; then
    . ~/.profile
fi

unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Launch XFCE4 within clean D-Bus session
exec dbus-run-session -- xfce4-session
EOF
sudo chmod +x /etc/xrdp/startwm.sh

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

# Ensure user directories and disabled compositing
for u in runner runneradmin; do
  sudo id -u $u &>/dev/null || sudo useradd -m -s /bin/bash -G sudo $u
  echo "exec dbus-run-session -- xfce4-session" | sudo tee /home/$u/.xsession > /dev/null
  sudo chmod +x /home/$u/.xsession

  # Disable XFCE window compositing (prevents blank/white screen & tearing in RDP)
  sudo mkdir -p /home/$u/.config/xfce4/xfconf/xfce-perchannel-xml
  sudo tee /home/$u/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

  # Desktop shortcuts
  sudo mkdir -p /home/$u/Desktop
  sudo tee /home/$u/Desktop/google-chrome.desktop > /dev/null << 'EOF'
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

  sudo tee /home/$u/Desktop/terminal.desktop > /dev/null << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
StartupNotify=true
EOF

  sudo chmod +x /home/$u/Desktop/*.desktop
  sudo chown -R $u:$u /home/$u
done

# Restart XRDP Service
sudo systemctl enable xrdp
sudo systemctl restart xrdp
echo "[5/5] XRDP is active and running on port 3389."
