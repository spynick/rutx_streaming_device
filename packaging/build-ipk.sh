#!/bin/sh
#
# Build Script für vpn-streaming.ipk
# ===================================
#
# Erstellt ein installierbares opkg Package aus dem Repo
#
# Verwendung:
#   ./build-ipk.sh [version]
#
# Beispiel:
#   ./build-ipk.sh 1.0.0
#
# Output:
#   vpn-streaming_<version>_all.ipk
#

set -e

# Version aus Parameter oder default
VERSION="${1:-1.0.0}"
PACKAGE_NAME="vpn-streaming"
ARCH="all"

# Verzeichnisse
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="/tmp/ipk-build-$$"
OUTPUT_DIR="$SCRIPT_DIR"

echo ""
echo "=========================================="
echo "  Building $PACKAGE_NAME v$VERSION"
echo "=========================================="
echo ""

# Cleanup alte Builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/control"
mkdir -p "$BUILD_DIR/data"

# -----------------------------------------------------------------------------
# Control Files erstellen
# -----------------------------------------------------------------------------

echo "[INFO] Erstelle control files..."

# control - Paket-Metadaten
cat > "$BUILD_DIR/control/control" << EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Stefan Heidler
Section: net
Priority: optional
Depends: ipset, uhttpd
Description: VPN Streaming für Teltonika RUTX Router
 Multi-Provider OpenVPN (ExpressVPN, NordVPN) und
 Multi-Tunnel WireGuard (Surfshark DE/CH/AT) mit
 automatischem Split-Routing für Streaming Devices.
 Standalone WebUI auf Port 8080.
EOF

# postinst - Nach Installation
cat > "$BUILD_DIR/control/postinst" << 'EOF'
#!/bin/sh

echo "[vpn-streaming] Post-Installation..."

# Install-Script ausführen (non-interactive)
if [ -x /etc/vpn-streaming/scripts/install-postinst.sh ]; then
    /etc/vpn-streaming/scripts/install-postinst.sh
fi

echo "[vpn-streaming] Installation abgeschlossen!"
echo ""
echo "WebUI erreichbar unter: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1'):8080/"
echo ""

exit 0
EOF
chmod 755 "$BUILD_DIR/control/postinst"

# prerm - Vor Deinstallation
cat > "$BUILD_DIR/control/prerm" << 'EOF'
#!/bin/sh

echo "[vpn-streaming] Deinstallation..."

# Cleanup Script ausführen
if [ -x /etc/vpn-streaming/scripts/cleanup.sh ]; then
    /etc/vpn-streaming/scripts/cleanup.sh --yes --no-reboot
fi

exit 0
EOF
chmod 755 "$BUILD_DIR/control/prerm"

# conffiles - Config-Dateien die bei Upgrade erhalten bleiben
cat > "$BUILD_DIR/control/conffiles" << 'EOF'
/etc/vpn-streaming/config
/etc/vpn-streaming/profiles/openvpn/
/etc/vpn-streaming/profiles/wireguard/
/etc/openvpn/expressvpn_auth.txt
/etc/openvpn/nordvpn_auth.txt
EOF

# -----------------------------------------------------------------------------
# Data Files zusammenstellen
# -----------------------------------------------------------------------------

echo "[INFO] Kopiere Dateien..."

# Hauptverzeichnis
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/scripts"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/domains"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/profiles/openvpn"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/profiles/wireguard"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/www"
mkdir -p "$BUILD_DIR/data/etc/vpn-streaming/www/api"
mkdir -p "$BUILD_DIR/data/etc/init.d"

# Scripts
cp "$REPO_DIR/scripts/vpn-control.sh" "$BUILD_DIR/data/etc/vpn-streaming/scripts/"
cp "$REPO_DIR/scripts/update-ips.sh" "$BUILD_DIR/data/etc/vpn-streaming/scripts/"
cp "$REPO_DIR/scripts/rules-watcher.sh" "$BUILD_DIR/data/etc/vpn-streaming/scripts/"
cp "$REPO_DIR/scripts/cleanup.sh" "$BUILD_DIR/data/etc/vpn-streaming/scripts/"

# Post-Install Script (speziell für opkg)
cat > "$BUILD_DIR/data/etc/vpn-streaming/scripts/install-postinst.sh" << 'POSTINST'
#!/bin/sh
#
# Post-Installation für opkg
# Wird nach dem Entpacken der Dateien ausgeführt
#

set -e

CONFIG_FILE="/etc/vpn-streaming/config"
SCRIPTS_DIR="/etc/vpn-streaming/scripts"
PROFILES_DIR="/etc/vpn-streaming/profiles"

echo "[vpn-streaming] Konfiguriere System..."

# Default Config erstellen falls nicht vorhanden
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'DEFCONF'
mode=off
openvpn_profile=
openvpn_enabled=0
wireguard_tunnels=
wireguard_enabled=0
devices=
expressvpn_user=
expressvpn_pass=
nordvpn_user=
nordvpn_pass=
DEFCONF
    chmod 666 "$CONFIG_FILE"
fi

# Scripts ausführbar machen
chmod +x "$SCRIPTS_DIR"/*.sh

# CGI ausführbar machen
chmod +x /etc/vpn-streaming/www/api/vpn-streaming

# Init Script aktivieren
if [ -f /etc/init.d/vpn-streaming-rules ]; then
    chmod +x /etc/init.d/vpn-streaming-rules
    /etc/init.d/vpn-streaming-rules enable
    /etc/init.d/vpn-streaming-rules start
fi

# uhttpd Config für WebUI (Port 8080)
if ! uci -q get uhttpd.vpnstreaming >/dev/null 2>&1; then
    echo "[vpn-streaming] Erstelle uhttpd Config..."
    uci set uhttpd.vpnstreaming=uhttpd
    uci set uhttpd.vpnstreaming.listen_http='0.0.0.0:8080'
    uci set uhttpd.vpnstreaming.home='/etc/vpn-streaming/www'
    uci set uhttpd.vpnstreaming.cgi_prefix='/api'
    uci set uhttpd.vpnstreaming.no_symlinks='0'
    uci set uhttpd.vpnstreaming.redirect_https='0'
    uci commit uhttpd
    /etc/init.d/uhttpd restart
fi

# Routing Tables eintragen
RT_TABLES="/etc/iproute2/rt_tables"
if [ -f "$RT_TABLES" ]; then
    grep -q "^110" "$RT_TABLES" || echo "110 vpn_at" >> "$RT_TABLES"
    grep -q "^111" "$RT_TABLES" || echo "111 vpn_ch" >> "$RT_TABLES"
    grep -q "^112" "$RT_TABLES" || echo "112 vpn_de" >> "$RT_TABLES"
    grep -q "^200" "$RT_TABLES" || echo "200 vpn_streaming" >> "$RT_TABLES"
fi

# Cronjob für IP-Update
CRON_FILE="/etc/crontabs/root"
if [ -f "$CRON_FILE" ]; then
    if ! grep -q "update-ips.sh" "$CRON_FILE"; then
        echo "*/30 * * * * /etc/vpn-streaming/scripts/update-ips.sh >/dev/null 2>&1" >> "$CRON_FILE"
        /etc/init.d/cron restart 2>/dev/null || true
    fi
fi

# OpenVPN Profile patchen (auth-user-pass)
for ovpn in "$PROFILES_DIR/openvpn/"*.ovpn 2>/dev/null; do
    [ -f "$ovpn" ] || continue
    name=$(basename "$ovpn")
    provider=""
    case "$name" in
        *expressvpn*) provider="expressvpn" ;;
        *nordvpn*) provider="nordvpn" ;;
    esac
    if [ -n "$provider" ]; then
        auth_file="/etc/openvpn/${provider}_auth.txt"
        sed -i "s|^auth-user-pass.*|auth-user-pass $auth_file|" "$ovpn"
        if ! grep -q "^auth-user-pass" "$ovpn"; then
            echo "auth-user-pass $auth_file" >> "$ovpn"
        fi
    fi
done

echo "[vpn-streaming] System konfiguriert."
POSTINST
chmod 755 "$BUILD_DIR/data/etc/vpn-streaming/scripts/install-postinst.sh"

# Domain Listen
cp "$REPO_DIR/domains/"*.txt "$BUILD_DIR/data/etc/vpn-streaming/domains/" 2>/dev/null || true

# WebUI
cp "$REPO_DIR/www/index.html" "$BUILD_DIR/data/etc/vpn-streaming/www/"
cp "$REPO_DIR/www/style.css" "$BUILD_DIR/data/etc/vpn-streaming/www/"
cp "$REPO_DIR/www/app.js" "$BUILD_DIR/data/etc/vpn-streaming/www/"
cp "$REPO_DIR/www/api/vpn-streaming" "$BUILD_DIR/data/etc/vpn-streaming/www/api/"

# Init.d Script
cat > "$BUILD_DIR/data/etc/init.d/vpn-streaming-rules" << 'INITD'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PIPE="/tmp/vpn_service_pipe"
SCRIPT="/etc/vpn-streaming/scripts/rules-watcher.sh"

start_service() {
    [ -p "$PIPE" ] || mkfifo "$PIPE"
    chmod 666 "$PIPE"

    procd_open_instance
    procd_set_param command "$SCRIPT"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    echo "stop" > "$PIPE" 2>/dev/null || true
}
INITD
chmod 755 "$BUILD_DIR/data/etc/init.d/vpn-streaming-rules"

# -----------------------------------------------------------------------------
# IPK bauen
# -----------------------------------------------------------------------------

echo "[INFO] Erstelle Archive..."

# control.tar.gz
cd "$BUILD_DIR/control"
tar czf "$BUILD_DIR/control.tar.gz" ./*

# data.tar.gz
cd "$BUILD_DIR/data"
tar czf "$BUILD_DIR/data.tar.gz" ./*

# debian-binary
echo "2.0" > "$BUILD_DIR/debian-binary"

# IPK erstellen (ar-Archiv)
cd "$BUILD_DIR"
OUTPUT_FILE="$OUTPUT_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.ipk"
ar r "$OUTPUT_FILE" debian-binary control.tar.gz data.tar.gz 2>/dev/null

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "[OK] Package erstellt: $OUTPUT_FILE"
echo ""
echo "Installation auf Router:"
echo "  scp $OUTPUT_FILE root@<router>:/tmp/"
echo "  ssh root@<router> 'opkg install /tmp/${PACKAGE_NAME}_${VERSION}_${ARCH}.ipk'"
echo ""
