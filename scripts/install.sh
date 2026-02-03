#!/bin/sh
#
# VPN Streaming v5.0 - Install Script
# =====================================
# Device-basiertes Multi-Tunnel VPN Routing fuer RUTX Router
#
# Unterstuetzt: OpenVPN (NordVPN, etc.) + WireGuard Tunnel
# Steuerung: WebUI (Port 8080) + Home Assistant Integration
#
# Ausfuehrung:
#   Lokal:  scp -r scripts www profiles root@ROUTER:/tmp/vpn-install && \
#           ssh root@ROUTER '/tmp/vpn-install/scripts/install.sh'
#   Remote: wget -qO- URL/install-remote.sh | sh
#

set -e

# =============================================================================
# KONFIGURATION
# =============================================================================

VERSION="5.0.0"
INSTALL_DIR="/etc/vpn-streaming"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
WEB_DIR="$INSTALL_DIR/www"
CGI_DIR="$WEB_DIR/api"
CONFIG_FILE="$INSTALL_DIR/config"
DEVICES_FILE="$INSTALL_DIR/devices.json"

# Geschuetzte WireGuard Interface-Namen (werden nie angefasst)
PROTECTED_WG="WG MGMT HOME VPN wg mgmt home vpn"

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

log()  { echo "[INFO]  $1"; }
warn() { echo "[WARN]  $1"; }
err()  { echo "[ERROR] $1"; exit 1; }

check_root() {
    [ "$(id -u)" = "0" ] || err "Muss als root ausgefuehrt werden"
}

check_system() {
    [ -f /etc/openwrt_release ] || err "Kein OpenWrt/RutOS System"
    log "System: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
}

# Datei aus lokalem Verzeichnis kopieren
get_file() {
    local filename="$1"
    local target="$2"
    local src_dir="$(dirname "$0")"

    if [ -f "$src_dir/$filename" ]; then
        cp "$src_dir/$filename" "$target"
    elif [ -f "$src_dir/../$filename" ]; then
        cp "$src_dir/../$filename" "$target"
    else
        return 1
    fi
}

# =============================================================================
# INSTALLATION
# =============================================================================

install_directories() {
    log "Erstelle Verzeichnisse..."
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$CGI_DIR"
    mkdir -p "$INSTALL_DIR/profiles/openvpn"
    mkdir -p "$INSTALL_DIR/profiles/wireguard"
}

install_scripts() {
    log "Installiere Scripts..."

    # vpn-control.sh (Hauptscript - API + Device/Tunnel Management)
    get_file "scripts/vpn-control.sh" "$SCRIPTS_DIR/vpn-control.sh" || \
        err "vpn-control.sh nicht gefunden"
    chmod +x "$SCRIPTS_DIR/vpn-control.sh"
    log "  vpn-control.sh"

    # service-wrapper.sh (FIFO IPC - laeuft als root, verarbeitet privilegierte Befehle)
    get_file "scripts/service-wrapper.sh" "$SCRIPTS_DIR/service-wrapper.sh" || \
        err "service-wrapper.sh nicht gefunden"
    chmod +x "$SCRIPTS_DIR/service-wrapper.sh"
    log "  service-wrapper.sh"

    # wg-setup.sh (WireGuard Profile Import - optional)
    if get_file "scripts/wg-setup.sh" "$SCRIPTS_DIR/wg-setup.sh"; then
        chmod +x "$SCRIPTS_DIR/wg-setup.sh"
        log "  wg-setup.sh"
    fi

    # cleanup.sh (Deinstallation - optional)
    if get_file "scripts/cleanup.sh" "$SCRIPTS_DIR/cleanup.sh"; then
        chmod +x "$SCRIPTS_DIR/cleanup.sh"
        log "  cleanup.sh"
    fi
}

install_webui() {
    log "Installiere WebUI..."
    local count=0

    for file in index.html app.js style.css; do
        if get_file "www/$file" "$WEB_DIR/$file"; then
            count=$((count + 1))
        fi
    done

    log "  $count Dateien"
}

install_cgi() {
    log "Installiere CGI API..."
    get_file "www/api/vpn-streaming" "$CGI_DIR/vpn-streaming" || \
        err "CGI Script nicht gefunden"
    chmod +x "$CGI_DIR/vpn-streaming"
}

install_profiles() {
    log "Installiere Profile..."
    local src="$(dirname "$0")/../profiles"
    local ovpn=0 wg=0

    if [ -d "$src/openvpn" ]; then
        for f in "$src/openvpn/"*.ovpn; do
            [ -f "$f" ] || continue
            cp "$f" "$INSTALL_DIR/profiles/openvpn/"
            ovpn=$((ovpn + 1))
        done
    fi

    if [ -d "$src/wireguard" ]; then
        for f in "$src/wireguard/"*.conf; do
            [ -f "$f" ] || continue
            cp "$f" "$INSTALL_DIR/profiles/wireguard/"
            wg=$((wg + 1))
        done
    fi

    log "  $ovpn OpenVPN, $wg WireGuard"
}

# =============================================================================
# KONFIGURATION
# =============================================================================

create_config() {
    log "Erstelle Konfiguration..."

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
# VPN Streaming v5.0 Configuration
device_count=0
tunnel_index=0
auto_vpn_global=0
# Active tunnels: tunnel_<idx>=profile:fwmark:table:refcount
EOF
        log "  config erstellt"
    else
        log "  config bereits vorhanden (uebersprungen)"
    fi

    if [ ! -f "$DEVICES_FILE" ]; then
        echo '{"devices":[]}' > "$DEVICES_FILE"
        log "  devices.json erstellt"
    else
        log "  devices.json bereits vorhanden (uebersprungen)"
    fi

    chmod 666 "$CONFIG_FILE" "$DEVICES_FILE"
}

setup_init_service() {
    log "Installiere Service (procd)..."

    cat > /etc/init.d/vpn-streaming << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /etc/vpn-streaming/scripts/service-wrapper.sh
    procd_set_param respawn
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/vpn-streaming
    /etc/init.d/vpn-streaming enable
    log "  Service aktiviert (startet bei Boot)"
}

setup_uhttpd() {
    log "Konfiguriere uhttpd (Port 8080)..."

    if ! uci -q get uhttpd.vpnstreaming >/dev/null 2>&1; then
        uci set uhttpd.vpnstreaming=uhttpd
        uci set uhttpd.vpnstreaming.home="$WEB_DIR"
        uci set uhttpd.vpnstreaming.cgi_prefix="/api"
        uci set uhttpd.vpnstreaming.listen_http="0.0.0.0:8080"
        uci set uhttpd.vpnstreaming.max_requests="5"
        uci set uhttpd.vpnstreaming.rfc1918_filter="0"
        uci set uhttpd.vpnstreaming.redirect_https="0"
        uci commit uhttpd
        log "  uhttpd Section erstellt"
    else
        log "  uhttpd bereits konfiguriert"
    fi
}

setup_firewall() {
    log "Konfiguriere Firewall..."

    # Port 8080 oeffnen
    if ! uci show firewall 2>/dev/null | grep -q "vpn_streaming_web"; then
        uci add firewall rule
        uci set firewall.@rule[-1].name='vpn_streaming_web'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest_port='8080'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        log "  Port 8080 geoeffnet"
    else
        log "  Port 8080 bereits offen"
    fi
}

setup_sysupgrade() {
    log "Konfiguriere Firmware-Update-Schutz..."

    local conf="/etc/sysupgrade.conf"
    local changed=0

    for path in "/etc/vpn-streaming/" "/etc/openvpn/nordvpn_auth.txt" "/etc/iproute2/rt_tables" "/etc/init.d/vpn-streaming"; do
        if ! grep -q "^${path}$" "$conf" 2>/dev/null; then
            echo "$path" >> "$conf"
            changed=1
        fi
    done

    if [ "$changed" = "1" ]; then
        log "  sysupgrade.conf aktualisiert"
    else
        log "  sysupgrade.conf bereits vollstaendig"
    fi
}

patch_openvpn_auth() {
    log "Patche OpenVPN auth-user-pass..."

    local patched=0

    # Profile in /etc/vuci-uploads/ (Teltonika Standard)
    for f in /etc/vuci-uploads/*.ovpn; do
        [ -f "$f" ] || continue
        local provider=""
        case "$(basename "$f")" in
            *nordvpn*|*NordVPN*) provider="nordvpn" ;;
            *expressvpn*|*ExpressVPN*) provider="expressvpn" ;;
            *surfshark*|*Surfshark*) provider="surfshark" ;;
        esac
        [ -z "$provider" ] && continue

        local auth_file="/etc/openvpn/${provider}_auth.txt"
        if grep -q "^auth-user-pass" "$f"; then
            sed -i "s|^auth-user-pass.*|auth-user-pass $auth_file|" "$f"
        else
            echo "auth-user-pass $auth_file" >> "$f"
        fi
        patched=$((patched + 1))
    done

    # Auch Profile im Install-Verzeichnis
    for f in "$INSTALL_DIR/profiles/openvpn/"*.ovpn; do
        [ -f "$f" ] || continue
        local provider=""
        case "$(basename "$f")" in
            *nordvpn*|*NordVPN*) provider="nordvpn" ;;
            *expressvpn*|*ExpressVPN*) provider="expressvpn" ;;
        esac
        [ -z "$provider" ] && continue

        local auth_file="/etc/openvpn/${provider}_auth.txt"
        if grep -q "^auth-user-pass" "$f"; then
            sed -i "s|^auth-user-pass.*|auth-user-pass $auth_file|" "$f"
        fi
    done

    log "  $patched Profile gepatcht"
}

setup_wireguard_profiles() {
    log "Importiere WireGuard Profile..."

    local created=0
    for conf in "$INSTALL_DIR/profiles/wireguard/"*.conf; do
        [ -f "$conf" ] || continue
        local filename=$(basename "$conf" .conf)

        # Interface-Name aus Dateiname: wg_streaming -> CH_Home_WG (manuell)
        # Oder wg-setup.sh nutzen falls vorhanden
        if [ -x "$SCRIPTS_DIR/wg-setup.sh" ]; then
            "$SCRIPTS_DIR/wg-setup.sh" "$conf" && created=$((created + 1))
        else
            log "  wg-setup.sh nicht vorhanden - ueberspringe $filename"
            log "  (WireGuard Profile muessen manuell oder via Teltonika WebUI importiert werden)"
        fi
    done

    log "  $created WireGuard Profile importiert"
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "  VPN Streaming v${VERSION} - Installation"
    echo "  Device-basiertes Multi-Tunnel Routing"
    echo "=============================================="
    echo ""

    check_root
    check_system

    # Dateien installieren
    install_directories
    install_scripts
    install_webui
    install_cgi
    install_profiles

    # Konfiguration
    create_config
    setup_init_service
    setup_uhttpd
    setup_firewall
    setup_sysupgrade
    patch_openvpn_auth

    # Services starten
    log "Starte Services..."
    /etc/init.d/uhttpd restart
    /etc/init.d/vpn-streaming restart
    sleep 2

    # Verify
    local pid=$(ps | grep "[s]ervice-wrapper" | awk '{print $1}' | head -1)
    if [ -n "$pid" ]; then
        log "Service-Wrapper laeuft (PID $pid)"
    else
        warn "Service-Wrapper nicht gestartet!"
    fi

    local router_ip=$(uci -q get network.lan.ipaddr || echo 'ROUTER-IP')

    echo ""
    echo "=============================================="
    echo "  Installation erfolgreich!"
    echo "=============================================="
    echo ""
    echo "WebUI:  http://${router_ip}:8080/"
    echo ""
    echo "Befehle:"
    echo "  $SCRIPTS_DIR/vpn-control.sh status"
    echo "  $SCRIPTS_DIR/vpn-control.sh devices"
    echo "  $SCRIPTS_DIR/vpn-control.sh tunnels"
    echo "  $SCRIPTS_DIR/vpn-control.sh device-enable <ip>"
    echo "  $SCRIPTS_DIR/vpn-control.sh device-disable <ip>"
    echo ""
    echo "Passwort setzen (WebUI oder CLI):"
    echo "  $SCRIPTS_DIR/vpn-control.sh credentials"
    echo "  $SCRIPTS_DIR/vpn-control.sh credentials-set /etc/openvpn/nordvpn_auth.txt USER PASS"
    echo ""
    echo "WireGuard Profile importieren:"
    echo "  $SCRIPTS_DIR/wg-setup.sh /pfad/zur/config.conf"
    echo ""
    echo "Firmware-Update: Dateien bleiben erhalten (sysupgrade.conf)"
    echo ""
}

main "$@"
