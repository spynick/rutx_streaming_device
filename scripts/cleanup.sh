#!/bin/sh
#
# VPN Streaming - Cleanup Script
# ===============================
# Entfernt die komplette VPN Streaming Installation vom RUTX Router
#
# Ausfuehrung:
#   /etc/vpn-streaming/scripts/cleanup.sh
#
# ACHTUNG: Loescht ALLE VPN Streaming Daten inkl. Profile und Credentials!
#
# WICHTIG: Management VPNs werden NIEMALS angefasst!
# Geschuetzte Namen: WG, MGMT, HOME, VPN (und Varianten)
#

set -e

# =============================================================================
# KONFIGURATION
# =============================================================================

INSTALL_DIR="/etc/vpn-streaming"

# Unser Prefix fuer Streaming Tunnel (NUR diese werden entfernt!)
TUNNEL_PREFIX="SS"

# Geschuetzte WireGuard/Interface Namen (NIEMALS anfassen!)
# Diese Patterns schuetzen Management-VPNs vor versehentlichem Loeschen
# Inkl. 'wireguard' Zone die von wg-setup.sh erstellt wird
PROTECTED_PATTERNS="WG MGMT HOME VPN wg mgmt home vpn Connect connect wireguard"

# Unsere Routing Tables (nur diese werden bereinigt)
OUR_ROUTE_TABLES="vpn_streaming vpn_at vpn_ch vpn_de vpn_tv"

# Unsere fwmarks (nur diese werden entfernt)
OUR_FWMARKS="0x8000 0x10 0x11 0x12"

# Flag: Credentials behalten? (wird durch Benutzerabfrage gesetzt)
KEEP_CREDENTIALS=0

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

log() {
    echo "[CLEANUP] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1"
}

# Prueft ob ein Name geschuetzt ist
is_protected() {
    local name="$1"
    for pattern in $PROTECTED_PATTERNS; do
        # Exakter Match
        if [ "$name" = "$pattern" ]; then
            return 0
        fi
        # Prefix/Suffix Match (z.B. WG_backup, home_vpn)
        case "$name" in
            ${pattern}_*|*_${pattern}|${pattern}[0-9]*) return 0 ;;
        esac
    done
    return 1
}

# Prueft ob ein Interface/Name uns gehoert (SS_ Prefix)
is_our_tunnel() {
    local name="$1"
    case "$name" in
        ${TUNNEL_PREFIX}_*) return 0 ;;
        *) return 1 ;;
    esac
}

# Prueft ob noch WireGuard Interfaces existieren
any_wireguard_interfaces() {
    uci show network 2>/dev/null | grep -q "proto='wireguard'"
}

# =============================================================================
# BESTAETIGUNG
# =============================================================================

confirm() {
    echo ""
    echo "=============================================="
    echo "  VPN Streaming - CLEANUP"
    echo "=============================================="
    echo ""
    echo "ACHTUNG: Dies wird ALLES loeschen:"
    echo "  - Aktive VPN Verbindungen (nur ${TUNNEL_PREFIX}_* Tunnel)"
    echo "  - Alle Streaming Profile (OpenVPN + WireGuard)"
    echo "  - Alle Credentials"
    echo "  - WebUI und API"
    echo "  - Firewall Regeln (nur vpn_streaming)"
    echo "  - Routing Konfiguration (nur unsere Tables)"
    echo ""
    echo "GESCHUETZT (werden NICHT angefasst):"
    for pattern in $PROTECTED_PATTERNS; do
        echo "  - $pattern*"
    done
    echo ""
    printf "Fortfahren? (ja/nein): "
    read answer
    case "$answer" in
        ja|Ja|JA|y|Y|yes|Yes|YES)
            ;;
        *)
            echo "Abgebrochen."
            exit 0
            ;;
    esac

    # Separate Frage fuer Credentials
    echo ""
    echo "Sollen die VPN Credentials (Auth-Files) BEHALTEN werden?"
    echo "  /etc/openvpn/expressvpn_auth.txt"
    echo "  /etc/openvpn/nordvpn_auth.txt"
    echo ""
    printf "Credentials behalten? (ja/nein): "
    read cred_answer
    case "$cred_answer" in
        ja|Ja|JA|y|Y|yes|Yes|YES)
            KEEP_CREDENTIALS=1
            echo "-> Credentials werden BEHALTEN"
            ;;
        *)
            KEEP_CREDENTIALS=0
            echo "-> Credentials werden GELOESCHT"
            ;;
    esac
    echo ""
}

# =============================================================================
# 1. VPN VERBINDUNGEN STOPPEN
# =============================================================================

stop_vpn_connections() {
    log "Stoppe VPN Verbindungen..."

    # OpenVPN stoppen (alle vpn_* Sections die wir erstellt haben)
    local ovpn_changed=""
    for section in $(uci show openvpn 2>/dev/null | grep "=openvpn" | cut -d. -f2 | cut -d= -f1); do
        case "$section" in
            vpn_*)
                uci set openvpn.$section.enable='0' 2>/dev/null || true
                uci delete openvpn.$section 2>/dev/null || true
                ovpn_changed="1"
                log "  OpenVPN $section gestoppt und entfernt"
                ;;
        esac
    done
    if [ -n "$ovpn_changed" ]; then
        uci commit openvpn 2>/dev/null || true
        /etc/init.d/openvpn restart 2>/dev/null || true
    fi

    # WireGuard Interfaces stoppen (NUR SS_* Tunnel!)
    for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1); do
        # Geschuetzte Interfaces ueberspringen
        if is_protected "$iface"; then
            continue
        fi
        # Nur unsere Tunnel anfassen
        if is_our_tunnel "$iface"; then
            ifdown "$iface" 2>/dev/null || true
            log "  WireGuard $iface gestoppt"
        fi
    done
}

# =============================================================================
# 2. IPTABLES REGELN ENTFERNEN
# =============================================================================

cleanup_iptables() {
    log "Entferne iptables Regeln..."

    # Config laden fuer Device-Liste
    if [ -f "$INSTALL_DIR/config" ]; then
        . "$INSTALL_DIR/config"
    fi

    # OpenVPN MARK Regeln (0x8000)
    for ip in $(echo "$devices" | tr ',' ' '); do
        [ -z "$ip" ] && continue
        iptables -t mangle -D PREROUTING -s "$ip" -j MARK --set-mark 0x8000 2>/dev/null && \
            log "  Entfernt: $ip -> 0x8000" || true
    done

    # WireGuard ipset MARK Regeln (nur unsere ipsets)
    for ip in $(echo "$devices" | tr ',' ' '); do
        [ -z "$ip" ] && continue
        for country in de ch at; do
            for mark in 0x10 0x11 0x12; do
                iptables -t mangle -D PREROUTING -s "$ip" -m set --match-set ${country}_ips dst -j MARK --set-mark $mark 2>/dev/null || true
            done
        done
    done
    log "  WireGuard ipset Regeln entfernt"

    # FORWARD Regeln (nur fuer unsere SS_* Interfaces)
    for iface in SS_DE SS_CH SS_AT SS_de SS_ch SS_at; do
        for mark in 16 17 18 0x10 0x11 0x12; do
            iptables -D FORWARD -i br-lan -o "$iface" -m mark --mark $mark -j ACCEPT 2>/dev/null || true
        done
    done
    log "  FORWARD Regeln entfernt"
}

# =============================================================================
# 3. IP RULES ENTFERNEN (NUR UNSERE!)
# =============================================================================

cleanup_ip_rules() {
    log "Entferne IP Rules..."

    # Nur unsere fwmarks entfernen
    for mark in $OUR_FWMARKS; do
        if ip rule del fwmark $mark 2>/dev/null; then
            log "  Entfernt: fwmark $mark"
        fi
    done

    # WICHTIG: Kein aggressives "ip route flush table X"!
    # Das wuerde auch System-Routes in numerischen Tables loeschen.
    # Wir entfernen nur Routes in unseren BENANNTEN Tables.
    for table in $OUR_ROUTE_TABLES; do
        if ip route show table "$table" 2>/dev/null | grep -q .; then
            ip route flush table "$table" 2>/dev/null || true
            log "  Routes aus table $table entfernt"
        fi
    done

    log "  IP Rules bereinigt"
}

# =============================================================================
# 4. IPSETS LOESCHEN
# =============================================================================

cleanup_ipsets() {
    log "Loesche ipsets..."

    # Nur unsere Streaming-ipsets (lowercase und uppercase Varianten)
    for ipset_name in de_ips ch_ips at_ips DE_ips CH_ips AT_ips; do
        if ipset list "$ipset_name" >/dev/null 2>&1; then
            ipset destroy "$ipset_name" 2>/dev/null || true
            log "  Entfernt: $ipset_name"
        fi
    done

    # Temp-Dateien
    rm -f /tmp/vpn_ipset_counts 2>/dev/null || true
    rm -f /tmp/vpn_rules_trigger 2>/dev/null || true
    rm -f /tmp/vpn_active_* 2>/dev/null || true
}

# =============================================================================
# 5. SERVICES STOPPEN
# =============================================================================

cleanup_services() {
    log "Stoppe Services..."

    # Rules Watcher stoppen und deaktivieren
    if [ -f /etc/init.d/vpn-streaming-rules ]; then
        /etc/init.d/vpn-streaming-rules stop 2>/dev/null || true
        /etc/init.d/vpn-streaming-rules disable 2>/dev/null || true
        rm -f /etc/init.d/vpn-streaming-rules
        log "  vpn-streaming-rules Service entfernt"
    fi

    # Prozesse killen
    killall rules-watcher.sh 2>/dev/null || true
}

# =============================================================================
# 6. UCI CONFIG ENTFERNEN
# =============================================================================

cleanup_uci() {
    log "Entferne UCI Konfiguration..."

    # WireGuard Interfaces loeschen - NUR SS_* Tunnel!
    log "  Suche ${TUNNEL_PREFIX}_* WireGuard Interfaces..."
    for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1); do
        # Geschuetzte Interfaces NIEMALS anfassen
        if is_protected "$iface"; then
            warn "  UEBERSPRINGE geschuetztes Interface: $iface"
            continue
        fi

        # Nur unsere Tunnel entfernen
        if is_our_tunnel "$iface"; then
            # Erst Peers loeschen
            while uci -q get network.@wireguard_${iface}[0] >/dev/null 2>&1; do
                uci delete network.@wireguard_${iface}[0] 2>/dev/null || true
                log "    Peer von $iface entfernt"
            done
            # Dann Interface loeschen
            uci delete network.$iface 2>/dev/null || true
            log "  Entfernt: network.$iface"
        fi
    done
    uci commit network 2>/dev/null || true

    # Firewall Zone loeschen (nur vpn_streaming_zone)
    if uci get firewall.vpn_streaming_zone >/dev/null 2>&1; then
        uci delete firewall.vpn_streaming_zone 2>/dev/null || true
        log "  Entfernt: firewall.vpn_streaming_zone"
    fi
    if uci get firewall.lan_vpn_streaming_forward >/dev/null 2>&1; then
        uci delete firewall.lan_vpn_streaming_forward 2>/dev/null || true
        log "  Entfernt: firewall.lan_vpn_streaming_forward"
    fi

    # Firewall Rule fuer Port 8080 (nur vpn_streaming_web)
    local idx=0
    while uci get firewall.@rule[$idx] >/dev/null 2>&1; do
        local name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
        if [ "$name" = "vpn_streaming_web" ]; then
            uci delete firewall.@rule[$idx] 2>/dev/null || true
            log "  Entfernt: firewall rule vpn_streaming_web"
            break
        fi
        idx=$((idx + 1))
    done

    # Wenn KEINE WireGuard Interfaces mehr existieren, auch 'wireguard' Zone entfernen
    if ! any_wireguard_interfaces; then
        log "  Keine WireGuard Interfaces mehr vorhanden"

        # Firewall Zone 'wireguard' entfernen
        local zone_idx=0
        while uci get firewall.@zone[$zone_idx] >/dev/null 2>&1; do
            local zn=$(uci get firewall.@zone[$zone_idx].name 2>/dev/null || echo "")
            if [ "$zn" = "wireguard" ]; then
                uci delete firewall.@zone[$zone_idx] 2>/dev/null || true
                log "  Entfernt: Firewall Zone 'wireguard'"
                break
            fi
            zone_idx=$((zone_idx + 1))
        done

        # Forwardings fuer 'wireguard' entfernen
        local fwd_count=$(uci show firewall 2>/dev/null | grep -c "=forwarding" || echo 0)
        local i=$((fwd_count - 1))
        while [ $i -ge 0 ]; do
            local src=$(uci get firewall.@forwarding[$i].src 2>/dev/null || echo "")
            local dest=$(uci get firewall.@forwarding[$i].dest 2>/dev/null || echo "")
            if [ "$src" = "wireguard" ] || [ "$dest" = "wireguard" ]; then
                uci delete firewall.@forwarding[$i] 2>/dev/null || true
                log "  Entfernt: Forwarding wireguard"
            fi
            i=$((i - 1))
        done

        # Allow-wireguard Rules entfernen
        idx=0
        while uci get firewall.@rule[$idx] >/dev/null 2>&1; do
            local rname=$(uci get firewall.@rule[$idx].name 2>/dev/null || echo "")
            case "$rname" in
                Allow-wireguard_*-traffic)
                    uci delete firewall.@rule[$idx] 2>/dev/null || true
                    log "  Entfernt: Firewall Rule $rname"
                    # Nicht break, es koennten mehrere sein
                    ;;
                *)
                    idx=$((idx + 1))
                    ;;
            esac
        done
    else
        log "  WireGuard Interfaces noch vorhanden - Firewall Zone bleibt"
    fi

    uci commit firewall 2>/dev/null || true

    # uhttpd Konfiguration (nur vpnstreaming)
    if uci get uhttpd.vpnstreaming >/dev/null 2>&1; then
        uci delete uhttpd.vpnstreaming 2>/dev/null || true
        log "  Entfernt: uhttpd.vpnstreaming"
    fi

    # Alias aus main entfernen
    if uci get uhttpd.main.alias 2>/dev/null | grep -q "vpn-streaming"; then
        uci del_list uhttpd.main.alias="/vpn-streaming=$INSTALL_DIR/www" 2>/dev/null || true
        log "  Entfernt: uhttpd alias /vpn-streaming"
    fi
    uci commit uhttpd 2>/dev/null || true
}

# =============================================================================
# 7. CRONJOB ENTFERNEN
# =============================================================================

cleanup_cron() {
    log "Entferne Cronjob..."

    if crontab -l 2>/dev/null | grep -q "vpn-streaming"; then
        crontab -l 2>/dev/null | grep -v "vpn-streaming" | crontab -
        log "  Cronjob entfernt"
    fi
}

# =============================================================================
# 8. ROUTING TABLES AUS RT_TABLES ENTFERNEN
# =============================================================================

cleanup_rt_tables() {
    log "Bereinige /etc/iproute2/rt_tables..."

    if [ -f /etc/iproute2/rt_tables ]; then
        # Nur unsere eigenen Table-Namen entfernen
        for table in $OUR_ROUTE_TABLES; do
            sed -i "/${table}/d" /etc/iproute2/rt_tables 2>/dev/null || true
        done
        log "  Routing Table Eintraege entfernt"
    fi
}

# =============================================================================
# 9. OPENVPN AUTH FILES LOESCHEN
# =============================================================================

cleanup_openvpn_auth() {
    log "Loesche OpenVPN Auth Files..."

    # Nur Streaming-spezifische Auth Files
    for auth_file in expressvpn_auth.txt nordvpn_auth.txt surfshark_auth.txt; do
        if [ -f "/etc/openvpn/$auth_file" ]; then
            rm -f "/etc/openvpn/$auth_file"
            log "  Entfernt: $auth_file"
        fi
    done
}

# =============================================================================
# 10. INSTALLATIONSVERZEICHNIS LOESCHEN
# =============================================================================

cleanup_files() {
    log "Loesche Installationsverzeichnis..."

    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        log "  $INSTALL_DIR geloescht"
    fi
}

# =============================================================================
# 11. SERVICES NEU LADEN
# =============================================================================

reload_services() {
    log "Lade Services neu..."

    # Network und Firewall neu laden fuer konsistenten Zustand
    /etc/init.d/firewall reload 2>/dev/null || true
    log "  Firewall neu geladen"

    /etc/init.d/network reload 2>/dev/null || true
    log "  Network neu geladen"

    # uhttpd neu starten falls Config geaendert
    /etc/init.d/uhttpd restart 2>/dev/null || true
    log "  uhttpd neu gestartet"
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

main() {
    # Root Check
    if [ "$(id -u)" != "0" ]; then
        error "Dieses Script muss als root ausgefuehrt werden"
        exit 1
    fi

    # Parameter pruefen
    case "$1" in
        -y|--yes)
            # Automatischer Modus: Credentials werden BEHALTEN (sicherer Default)
            KEEP_CREDENTIALS=1
            log "Automatischer Modus (-y): Credentials werden behalten"
            ;;
        -y-delete-creds|--yes-delete-credentials)
            # Automatischer Modus: Credentials loeschen
            KEEP_CREDENTIALS=0
            log "Automatischer Modus: Credentials werden geloescht"
            ;;
        *)
            # Interaktiver Modus
            confirm
            ;;
    esac

    echo ""
    log "Starte Cleanup..."
    log ""
    log "Geschuetzte Interfaces werden NICHT angefasst!"
    echo ""

    stop_vpn_connections
    cleanup_iptables
    cleanup_ip_rules
    cleanup_ipsets
    cleanup_services
    cleanup_uci
    cleanup_cron
    cleanup_rt_tables
    if [ "$KEEP_CREDENTIALS" = "0" ]; then
        cleanup_openvpn_auth
    else
        log "Credentials werden behalten (Auth-Files)"
    fi
    cleanup_files
    reload_services

    echo ""
    echo "=============================================="
    echo "[OK] Cleanup abgeschlossen!"
    echo "=============================================="
    echo ""
    echo "VPN Streaming wurde vollstaendig entfernt."
    echo ""
    echo "Geloescht:"
    echo "  - VPN Verbindungen (nur ${TUNNEL_PREFIX}_* Tunnel)"
    echo "  - iptables/ip rules (nur unsere Marks)"
    echo "  - ipsets (de_ips, ch_ips, at_ips)"
    echo "  - UCI Config (nur vpn_streaming)"
    echo "  - Cronjob"
    if [ "$KEEP_CREDENTIALS" = "0" ]; then
        echo "  - Auth Files"
    fi
    echo "  - $INSTALL_DIR"
    if [ "$KEEP_CREDENTIALS" = "1" ]; then
        echo ""
        echo "BEHALTEN:"
        echo "  - /etc/openvpn/*_auth.txt (Credentials)"
    fi
    echo ""
    echo "NICHT angefasst:"
    echo "  - Management VPNs (WG, MGMT, HOME, VPN, etc.)"
    echo "  - System Routing Tables"
    echo "  - mwan3 Konfiguration"
    echo ""
    echo "Services wurden neu geladen - kein Reboot noetig."
    echo ""
}

main "$@"
