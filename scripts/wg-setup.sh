#!/bin/sh
#
# WireGuard Setup Script
# ======================
# Richtet WireGuard Interface per UCI ein oder entfernt es
#
# Basiert auf bewaehrter RUTX50/RUTC50 Konfiguration
# Getestet und korrigiert: 2026-01-08
#
# WICHTIG fuer Teltonika RUTOS WebUI Kompatibilitaet:
#   - Peer muss benannt sein (nicht anonym @wireguard_XXX[0])
#   - addresses und allowed_ips muessen als 'list' gesetzt werden
#   - tunlink='any' ist erforderlich
#
# Verwendung:
#   wg-setup.sh add <NAME> <config.conf>   - Interface hinzufuegen
#   wg-setup.sh del <NAME>                 - Interface entfernen
#   wg-setup.sh show <NAME>                - Interface anzeigen
#   wg-setup.sh list                       - Alle WG Interfaces auflisten
#
# Beispiele:
#   wg-setup.sh add WG /tmp/wg-home.conf
#   wg-setup.sh add VPN /tmp/vpn.conf
#   wg-setup.sh del VPN
#

set -e

# Farben (deaktiviert fuer OpenWrt Kompatibilitaet)
RED=''
GREEN=''
YELLOW=''
NC=''

log() {
    echo "${GREEN}[WG-SETUP]${NC} $1"
}

warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo "${RED}[ERROR]${NC} $1"
    exit 1
}

# Hilfe anzeigen
show_help() {
    echo ""
    echo "WireGuard Setup Script"
    echo "======================"
    echo ""
    echo "Verwendung:"
    echo "  $0 add <NAME> <config.conf>   - Interface hinzufuegen"
    echo "  $0 del <NAME>                 - Interface entfernen"
    echo "  $0 show <NAME>                - Interface anzeigen"
    echo "  $0 list                       - Alle WG Interfaces auflisten"
    echo ""
    echo "Beispiele:"
    echo "  $0 add WG /tmp/wg-home.conf"
    echo "  $0 add VPN /tmp/vpn.conf"
    echo "  $0 del VPN"
    echo ""
}

# .conf Datei parsen
parse_conf() {
    local conf_file="$1"

    # Interface Sektion
    PRIVATE_KEY=$(grep -E "^PrivateKey\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ')
    ADDRESS=$(grep -E "^Address\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ')
    DNS=$(grep -E "^DNS\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ' || echo "")
    MTU=$(grep -E "^MTU\s*=" "$conf_file" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)
    LISTEN_PORT=$(grep -E "^ListenPort\s*=" "$conf_file" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)

    # Peer Sektion
    PUBLIC_KEY=$(grep -E "^PublicKey\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ')
    ENDPOINT=$(grep -E "^Endpoint\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ')
    ALLOWED_IPS=$(grep -E "^AllowedIPs\s*=" "$conf_file" | cut -d'=' -f2- | tr -d ' ')
    PERSISTENT_KEEPALIVE=$(grep -E "^PersistentKeepalive\s*=" "$conf_file" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)
    if [ -z "$PERSISTENT_KEEPALIVE" ]; then
        PERSISTENT_KEEPALIVE="25"
    fi
    PRESHARED_KEY=$(grep -E "^PresharedKey\s*=" "$conf_file" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true)

    # Endpoint aufteilen
    ENDPOINT_HOST=$(echo "$ENDPOINT" | cut -d':' -f1)
    ENDPOINT_PORT=$(echo "$ENDPOINT" | cut -d':' -f2)

    # ListenPort Default = EndpointPort falls nicht gesetzt
    if [ -z "$LISTEN_PORT" ]; then
        LISTEN_PORT="$ENDPOINT_PORT"
    fi

    # MTU Default
    if [ -z "$MTU" ]; then
        MTU="1420"
    fi

    # Validierung
    if [ -z "$PRIVATE_KEY" ]; then error "PrivateKey nicht gefunden in $conf_file"; fi
    if [ -z "$ADDRESS" ]; then error "Address nicht gefunden in $conf_file"; fi
    if [ -z "$PUBLIC_KEY" ]; then error "PublicKey nicht gefunden in $conf_file"; fi
    if [ -z "$ENDPOINT" ]; then error "Endpoint nicht gefunden in $conf_file"; fi
    if [ -z "$ALLOWED_IPS" ]; then error "AllowedIPs nicht gefunden in $conf_file"; fi
}

# Lokales Netz aus Routing ermitteln
get_local_network() {
    # Versuche br-lan Netz zu ermitteln
    local lan_ip=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')
    if [ -n "$lan_ip" ]; then
        # Extrahiere Netzwerk (z.B. 192.168.110.0/24 aus 192.168.110.1/24)
        echo "$lan_ip" | sed 's/\.[0-9]*\//.0\//'
    fi
}

# Pruefe ob AllowedIPs das lokale Netz enthalten
check_allowed_ips() {
    local name="$1"
    local allowed="$2"
    local local_net=$(get_local_network)

    if [ -n "$local_net" ]; then
        local local_prefix=$(echo "$local_net" | cut -d'/' -f1 | cut -d'.' -f1-3)
        local match=$(echo "$allowed" | grep "$local_prefix" 2>/dev/null || true)
        if [ -n "$match" ]; then
            echo ""
            warn "ACHTUNG: AllowedIPs enthalten moeglicherweise das lokale Netz!"
            warn "  Lokales Netz: $local_net"
            warn "  AllowedIPs: $allowed"
            warn ""
            warn "  Das kann dazu fuehren, dass SSH/Web nicht mehr erreichbar ist!"
            warn "  Empfehlung: route_allowed_ips='0' setzen"
            echo ""
            printf "Trotzdem fortfahren? (ja/nein): "
            read answer
            case "$answer" in
                ja|Ja|JA|y|Y|yes|Yes|YES)
                    return 0
                    ;;
                *)
                    echo "Abgebrochen."
                    exit 0
                    ;;
            esac
        fi
    fi
}

# WireGuard Interface hinzufuegen
add_interface() {
    local name="$1"
    local conf_file="$2"

    [ -z "$name" ] && error "Kein Interface-Name angegeben"
    [ -z "$conf_file" ] && error "Keine Config-Datei angegeben"
    [ ! -f "$conf_file" ] && error "Config-Datei nicht gefunden: $conf_file"

    # Pruefen ob Interface schon existiert
    if uci get network.$name >/dev/null 2>&1; then
        warn "Interface $name existiert bereits!"
        printf "Ueberschreiben? (ja/nein): "
        read answer
        case "$answer" in
            ja|Ja|JA|y|Y|yes|Yes|YES)
                del_interface "$name" "quiet"
                ;;
            *)
                echo "Abgebrochen."
                exit 0
                ;;
        esac
    fi

    # Config parsen
    log "Parse Config: $conf_file"
    parse_conf "$conf_file"

    # Warnung bei lokalem Netz in AllowedIPs
    check_allowed_ips "$name" "$ALLOWED_IPS"

    log "Erstelle Interface: $name"

    # Network Interface erstellen (exakt wie bewaehrte RUTX Config)
    uci set network.$name=interface
    uci set network.$name.proto='wireguard'
    uci set network.$name.private_key="$PRIVATE_KEY"
    uci set network.$name.mtu="$MTU"
    uci set network.$name.listen_port="$LISTEN_PORT"
    uci set network.$name.area_type='wan'
    uci set network.$name.disabled='0'
    uci set network.$name.metric='7'

    # DNS hinzufuegen falls vorhanden
    if [ -n "$DNS" ]; then
        for dns in $(echo "$DNS" | tr ',' ' '); do
            uci add_list network.$name.dns="$dns"
        done
        log "  DNS: $DNS"
    fi

    # Adressen hinzufuegen (kann mehrere sein, kommagetrennt)
    for addr in $(echo "$ADDRESS" | tr ',' ' '); do
        uci add_list network.$name.addresses="$addr"
    done

    log "  Address: $ADDRESS"
    log "  MTU: $MTU"
    log "  ListenPort: $LISTEN_PORT"

    # Peer als benannte Section hinzufuegen (nicht anonym!)
    # WICHTIG: Peer-Name muss eindeutig sein fuer jedes Interface
    # Format: ${name}_Peer (z.B. WG_Stream_Peer, VPN_Peer)
    local peer_name="${name}_Peer"

    uci set network.$peer_name=wireguard_$name
    uci set network.$peer_name.endpoint_port="$ENDPOINT_PORT"
    uci set network.$peer_name.public_key="$PUBLIC_KEY"
    uci set network.$peer_name.persistent_keepalive="$PERSISTENT_KEEPALIVE"
    uci set network.$peer_name.endpoint_host="$ENDPOINT_HOST"
    uci set network.$peer_name.tunlink='any'

    # route_allowed_ips: 0 fuer Streaming (kein Default-Route), 1 fuer VPN
    if echo "$ALLOWED_IPS" | grep -q "0.0.0.0/0"; then
        uci set network.$peer_name.route_allowed_ips='0'
        log "  route_allowed_ips=0 (Streaming-Modus, keine Default-Route)"
    else
        uci set network.$peer_name.route_allowed_ips='1'
    fi

    # PresharedKey falls vorhanden
    if [ -n "$PRESHARED_KEY" ]; then
        uci set network.$peer_name.preshared_key="$PRESHARED_KEY"
    fi

    # AllowedIPs hinzufuegen (MUSS list sein fuer WebUI!)
    for ip in $(echo "$ALLOWED_IPS" | tr ',' ' '); do
        uci add_list network.$peer_name.allowed_ips="$ip"
    done

    log "  Peer: $peer_name"

    log "  Endpoint: $ENDPOINT"
    log "  AllowedIPs: $ALLOWED_IPS"

    uci commit network

    # Firewall Rule fuer WireGuard UDP Port (WICHTIG!)
    log "Erstelle Firewall Rule: Allow-wireguard_$name-traffic"

    uci add firewall rule
    uci set firewall.@rule[-1].name="Allow-wireguard_$name-traffic"
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port="$LISTEN_PORT"
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci set firewall.@rule[-1].family='ipv4'

    # Firewall Zone - pruefen ob bereits vorhanden
    local zone_exists=0
    local zone_idx=0
    while uci get firewall.@zone[$zone_idx] >/dev/null 2>&1; do
        local zn=$(uci get firewall.@zone[$zone_idx].name 2>/dev/null || echo "")
        if [ "$zn" = "wireguard" ]; then
            zone_exists=1
            # Interface zur bestehenden Zone hinzufuegen
            local current_networks=$(uci get firewall.@zone[$zone_idx].network 2>/dev/null || echo "")
            if ! echo "$current_networks" | grep -q "$name"; then
                uci set firewall.@zone[$zone_idx].network="$current_networks $name"
                log "  Interface zur bestehenden Zone 'wireguard' hinzugefuegt"
            fi
            break
        fi
        zone_idx=$((zone_idx + 1))
    done

    if [ $zone_exists -eq 0 ]; then
        log "Erstelle Firewall Zone: wireguard"

        uci add firewall zone
        uci set firewall.@zone[-1].name='wireguard'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='0'
        uci set firewall.@zone[-1].network="$name"

        # Forwarding WG -> LAN
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='wireguard'
        uci set firewall.@forwarding[-1].dest='lan'

        # Forwarding LAN -> WG
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='wireguard'
    fi

    uci commit firewall

    log "Fertig! Aktiviere mit:"
    echo ""
    echo "  /etc/init.d/network reload"
    echo "  /etc/init.d/firewall reload"
    echo ""
    echo "Oder Reboot fuer saubere Aktivierung."
    echo ""
}

# Prueft ob noch WireGuard Interfaces existieren
any_wireguard_interfaces() {
    uci show network 2>/dev/null | grep -q "proto='wireguard'"
}

# WireGuard Interface entfernen
del_interface() {
    local name="$1"
    local quiet="$2"

    if [ -z "$name" ]; then
        error "Kein Interface-Name angegeben"
    fi

    # Pruefen ob Interface existiert
    if ! uci get network.$name >/dev/null 2>&1; then
        if [ "$quiet" != "quiet" ]; then
            warn "Interface $name existiert nicht"
        fi
        return 0
    fi

    if [ "$quiet" != "quiet" ]; then
        log "Entferne Interface: $name"
    fi

    # Benannte Peer Section entfernen (Format: ${name}_Peer)
    local peer_name="${name}_Peer"
    if uci get network.$peer_name >/dev/null 2>&1; then
        uci delete network.$peer_name
        if [ "$quiet" != "quiet" ]; then
            log "  Peer '$peer_name' entfernt"
        fi
    fi

    # Legacy: Auch 'Connect' entfernen falls vorhanden (alte Configs)
    if uci get network.Connect >/dev/null 2>&1; then
        local connect_type=$(uci get network.Connect 2>/dev/null || echo "")
        if [ "$connect_type" = "wireguard_$name" ]; then
            uci delete network.Connect
            if [ "$quiet" != "quiet" ]; then
                log "  Legacy Peer 'Connect' entfernt"
            fi
        fi
    fi

    # Auch anonyme Peers entfernen (fuer Kompatibilitaet mit alten Configs)
    while uci -q get network.@wireguard_$name[0] >/dev/null 2>&1; do
        uci delete network.@wireguard_$name[0]
        if [ "$quiet" != "quiet" ]; then
            log "  Anonymer Peer entfernt"
        fi
    done

    # Interface entfernen
    uci delete network.$name
    uci commit network
    if [ "$quiet" != "quiet" ]; then
        log "  Network Interface entfernt"
    fi

    # Firewall Rule fuer dieses Interface entfernen
    local rule_idx=0
    while uci get firewall.@rule[$rule_idx] >/dev/null 2>&1; do
        local rn=$(uci get firewall.@rule[$rule_idx].name 2>/dev/null || echo "")
        if [ "$rn" = "Allow-wireguard_$name-traffic" ]; then
            uci delete firewall.@rule[$rule_idx]
            if [ "$quiet" != "quiet" ]; then
                log "  Firewall Rule entfernt"
            fi
            break
        fi
        rule_idx=$((rule_idx + 1))
    done

    # Firewall Zone und Forwardings NUR entfernen wenn KEINE WG Interfaces mehr existieren
    if ! any_wireguard_interfaces; then
        if [ "$quiet" != "quiet" ]; then
            log "  Keine WireGuard Interfaces mehr - entferne Firewall Zone"
        fi

        # Firewall Zone 'wireguard' entfernen
        local zone_idx=0
        while uci get firewall.@zone[$zone_idx] >/dev/null 2>&1; do
            local zn=$(uci get firewall.@zone[$zone_idx].name 2>/dev/null || echo "")
            if [ "$zn" = "wireguard" ]; then
                uci delete firewall.@zone[$zone_idx]
                if [ "$quiet" != "quiet" ]; then
                    log "  Firewall Zone 'wireguard' entfernt"
                fi
                break
            fi
            zone_idx=$((zone_idx + 1))
        done

        # Forwardings entfernen (src oder dest = 'wireguard')
        # Rueckwaerts iterieren wegen Index-Verschiebung
        local fwd_count=$(uci show firewall 2>/dev/null | grep -c "=forwarding" || echo 0)
        local i=$((fwd_count - 1))

        while [ $i -ge 0 ]; do
            local src=$(uci get firewall.@forwarding[$i].src 2>/dev/null || echo "")
            local dest=$(uci get firewall.@forwarding[$i].dest 2>/dev/null || echo "")
            if [ "$src" = "wireguard" ] || [ "$dest" = "wireguard" ]; then
                uci delete firewall.@forwarding[$i]
                if [ "$quiet" != "quiet" ]; then
                    log "  Forwarding entfernt"
                fi
            fi
            i=$((i - 1))
        done
    else
        if [ "$quiet" != "quiet" ]; then
            log "  Andere WireGuard Interfaces vorhanden - Firewall Zone bleibt"
        fi
    fi

    uci commit firewall

    if [ "$quiet" != "quiet" ]; then
        log "Fertig! Aktiviere mit:"
        echo ""
        echo "  /etc/init.d/network reload"
        echo "  /etc/init.d/firewall reload"
        echo ""
    fi
}

# WireGuard Interface anzeigen
show_interface() {
    local name="$1"

    if [ -z "$name" ]; then
        error "Kein Interface-Name angegeben"
    fi

    if ! uci get network.$name >/dev/null 2>&1; then
        error "Interface $name existiert nicht"
    fi

    echo ""
    echo "=== Network Interface: $name ==="
    uci show network.$name 2>/dev/null
    echo ""
    echo "=== Peers ==="
    # Benannte Peer Section (neues Format: ${name}_Peer)
    local peer_name="${name}_Peer"
    if uci get network.$peer_name >/dev/null 2>&1; then
        uci show network.$peer_name 2>/dev/null
    fi
    # Legacy: Connect Peer
    if uci get network.Connect >/dev/null 2>&1; then
        local connect_type=$(uci get network.Connect 2>/dev/null || echo "")
        if [ "$connect_type" = "wireguard_$name" ]; then
            uci show network.Connect 2>/dev/null
        fi
    fi
    # Anonyme Peers (sollten nicht mehr vorkommen)
    uci show network | grep "@wireguard_$name" 2>/dev/null || true
    echo ""
    echo "=== Firewall Rule ==="
    uci show firewall | grep "Allow-wireguard_$name-traffic" 2>/dev/null || echo "(keine)"
    echo ""
    echo "=== Firewall Zone ==="
    uci show firewall | grep -E "name='wireguard'|network='$name'" 2>/dev/null || echo "(keine)"
    echo ""
    echo "=== Forwardings ==="
    uci show firewall | grep -E "forwarding.*'wireguard'" 2>/dev/null || echo "(keine)"
    echo ""
    echo "=== Live Status ==="
    wg show "$name" 2>/dev/null || echo "(Interface nicht aktiv)"
    echo ""
}

# Alle WireGuard Interfaces auflisten
list_interfaces() {
    echo ""
    echo "WireGuard Interfaces:"
    echo "====================="

    local found=0
    for iface in $(uci show network 2>/dev/null | grep "proto='wireguard'" | cut -d'.' -f2 | cut -d'=' -f1); do
        found=1
        local status="inaktiv"
        if wg show "$iface" >/dev/null 2>&1; then
            status="aktiv"
        fi
        echo "  - $iface ($status)"
    done

    if [ $found -eq 0 ]; then echo "  (keine)"; fi
    echo ""
}

# Hauptprogramm
main() {
    local action="$1"
    shift 2>/dev/null || true

    case "$action" in
        add|a)
            add_interface "$@"
            ;;
        del|delete|d|rm|remove)
            del_interface "$@"
            ;;
        show|s)
            show_interface "$@"
            ;;
        list|l|ls)
            list_interfaces
            ;;
        help|h|-h|--help)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

main "$@"
