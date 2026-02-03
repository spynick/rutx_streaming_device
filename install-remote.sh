#!/bin/sh
#
# VPN Streaming - Remote Installer
# =================================
#
# Einzeiler-Installation:
#   curl -sL https://raw.githubusercontent.com/spynick/rutx_streaming_vpn/main/install-remote.sh | sh
#
# Oder mit wget:
#   wget -qO- https://raw.githubusercontent.com/spynick/rutx_streaming_vpn/main/install-remote.sh | sh
#

set -e

REPO_URL="https://raw.githubusercontent.com/spynick/rutx_streaming_vpn/main"
INSTALL_DIR="/tmp/vpn-streaming-install"

echo ""
echo "=============================================="
echo "  VPN Streaming - Remote Installation"
echo "=============================================="
echo ""

# Cleanup
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[INFO] Lade Dateien herunter..."

# Verzeichnisse erstellen
mkdir -p scripts domains www/api profiles/openvpn profiles/wireguard

# Scripts
for f in install.sh vpn-control.sh update-ips.sh rules-watcher.sh cleanup.sh wg-setup.sh init.d-vpn-streaming-rules; do
    echo "  - scripts/$f"
    wget -q "$REPO_URL/scripts/$f" -O "scripts/$f" || curl -sL "$REPO_URL/scripts/$f" -o "scripts/$f"
done

# Domains
for f in de_streaming.txt ch_streaming.txt at_streaming.txt; do
    echo "  - domains/$f"
    wget -q "$REPO_URL/domains/$f" -O "domains/$f" 2>/dev/null || curl -sL "$REPO_URL/domains/$f" -o "domains/$f" 2>/dev/null || true
done

# WebUI
for f in index.html style.css app.js; do
    echo "  - www/$f"
    wget -q "$REPO_URL/www/$f" -O "www/$f" || curl -sL "$REPO_URL/www/$f" -o "www/$f"
done

# API
echo "  - www/api/vpn-streaming"
wget -q "$REPO_URL/www/api/vpn-streaming" -O "www/api/vpn-streaming" || curl -sL "$REPO_URL/www/api/vpn-streaming" -o "www/api/vpn-streaming"

# OpenVPN Profile (public, ohne Credentials)
echo "[INFO] Lade OpenVPN Profile..."
for f in vpn_AT-Wien_expressvpn.ovpn vpn_AT-Wien_nordvpn.ovpn \
         vpn_CH-Zuerich_nordvpn.ovpn vpn_CH-Zuerich-1_expressvpn.ovpn vpn_CH-Zuerich-2_expressvpn.ovpn \
         vpn_DE-Frankfurt_nordvpn.ovpn vpn_DE-Frankfurt-1_expressvpn.ovpn vpn_DE-Frankfurt-3_expressvpn.ovpn \
         vpn_DE-Nuernberg_expressvpn.ovpn; do
    echo "  - profiles/openvpn/$f"
    wget -q "$REPO_URL/profiles/openvpn/$f" -O "profiles/openvpn/$f" 2>/dev/null || \
    curl -sL "$REPO_URL/profiles/openvpn/$f" -o "profiles/openvpn/$f" 2>/dev/null || true
done

echo ""
echo "[INFO] Starte Installation..."
echo ""

chmod +x scripts/*.sh
cd scripts
./install.sh

echo ""
echo "[INFO] Aufraumen..."
rm -rf "$INSTALL_DIR"

echo ""
echo "=============================================="
echo "  Installation abgeschlossen!"
echo "=============================================="
echo ""
echo "WebUI: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1'):8080/"
echo ""
echo "Naechste Schritte:"
echo "  1. OpenVPN Credentials in WebUI eintragen (ExpressVPN/NordVPN)"
echo "  2. WireGuard Profile hochladen (.conf mit Private Keys)"
echo "  3. Streaming Device IPs konfigurieren"
echo ""
