#!/bin/sh
#
# VPN Streaming Service Wrapper v5.0
# FIFO-basierte IPC - keine Befehle gehen verloren
#
# Laeuft als root, verarbeitet privilegierte Befehle
#

FIFO_CMD="/tmp/vpn_service_cmd"      # Befehle rein
FIFO_RESPONSE="/tmp/vpn_service_resp"  # Antworten raus
CONFIG_FILE="/etc/vpn-streaming/config"
LOG_TAG="vpn-service"
RT_TABLES_FILE="/etc/iproute2/rt_tables"

log() { logger -t "$LOG_TAG" "$1"; }

# =============================================================================
# FIFO SETUP
# =============================================================================

setup_fifos() {
    rm -f "$FIFO_CMD" "$FIFO_RESPONSE"

    mkfifo "$FIFO_CMD"
    mkfifo "$FIFO_RESPONSE"
    chmod 666 "$FIFO_CMD" "$FIFO_RESPONSE"

    log "FIFOs erstellt: $FIFO_CMD, $FIFO_RESPONSE"
}

cleanup() {
    log "Service Wrapper beendet"
    rm -f "$FIFO_CMD" "$FIFO_RESPONSE"
    exit 0
}

# Antwort senden
send_response() {
    echo "$1" > "$FIFO_RESPONSE"
}

# Signal Handler
trap cleanup INT TERM

# =============================================================================
# TUNNEL MANAGEMENT
# =============================================================================

start_openvpn_tunnel() {
    local profile="$1"
    local idx="$2"
    local fwmark="$3"
    local table="$4"

    log "Starte OpenVPN Tunnel: $profile (idx=$idx, fwmark=$fwmark, table=$table)"

    # UCI Section finden
    local section=""
    for s in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
        local name=$(uci -q get openvpn.$s.name)
        if [ "$name" = "$profile" ] || [ "$s" = "$profile" ]; then
            section="$s"
            break
        fi
    done

    if [ -z "$section" ]; then
        log "ERROR: OpenVPN Section nicht gefunden fuer: $profile"
        return 1
    fi

    log "UCI Section: $section"

    local tunnel=$(uci -q get openvpn.$section.dev)
    if [ -z "$tunnel" ]; then
        log "ERROR: Kein dev konfiguriert fuer $section"
        return 1
    fi

    local pidfile="/var/run/openvpn-$section.pid"
    local config="/var/run/openvpn/openvpn-$section.conf"

    # Pruefen ob Tunnel bereits laeuft
    if ip link show "$tunnel" 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
        log "Tunnel $tunnel bereits aktiv - nur Routing einrichten"
        uci set openvpn.$section.enable=1
        uci commit openvpn
    elif [ -f "$pidfile" ] && kill -0 $(cat "$pidfile" 2>/dev/null) 2>/dev/null; then
        log "Tunnel $section laeuft bereits (PID $(cat $pidfile))"
        uci set openvpn.$section.enable=1
        uci commit openvpn
    else
        if [ ! -f "$config" ]; then
            log "ERROR: Config $config nicht gefunden"
            return 1
        fi

        log "Aktiviere Tunnel $section via UCI"

        # Alle Tunnel disable, dann nur unsere Config-Tunnel enable
        for s in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
            uci set openvpn.$s.enable=0
        done

        for tunnel_line in $(grep "^tunnel_[0-9]" "$CONFIG_FILE" 2>/dev/null); do
            local tprofile=$(echo "$tunnel_line" | cut -d"'" -f2 | cut -d: -f1)
            for s in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
                local name=$(uci -q get openvpn.$s.name)
                if [ "$name" = "$tprofile" ]; then
                    uci set openvpn.$s.enable=1
                    log "Config-Tunnel: $s ($tprofile)"
                fi
            done
        done

        uci set openvpn.$section.enable=1
        uci commit openvpn
        /etc/init.d/openvpn reload

        # Warten auf Tunnel (max 15s)
        local timeout=15
        while [ $timeout -gt 0 ]; do
            ip link show "$tunnel" >/dev/null 2>&1 && break
            sleep 1
            timeout=$((timeout - 1))
        done

        if ! ip link show "$tunnel" >/dev/null 2>&1; then
            log "ERROR: Tunnel $tunnel nicht gestartet nach 15s"
            return 1
        fi

        log "OpenVPN $section gestartet"
    fi

    # Routing Table
    local table_name="vpn_tunnel_$idx"
    grep -q "^$table[[:space:]]" "$RT_TABLES_FILE" 2>/dev/null || \
        echo "$table $table_name" >> "$RT_TABLES_FILE"

    # Routes und Rules
    ip route replace default dev "$tunnel" table "$table"
    ip rule del fwmark "$fwmark" table "$table" 2>/dev/null
    ip rule add fwmark "$fwmark" table "$table" priority "$table"

    echo "$tunnel" > "/tmp/vpn_tunnel_$idx"
    log "Tunnel $profile ($tunnel) bereit"
    return 0
}

stop_openvpn_tunnel() {
    local profile="$1"
    local idx="$2"
    local fwmark="$3"
    local table="$4"

    log "Stoppe Tunnel: $profile (idx=$idx)"

    local section=""
    for s in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
        local name=$(uci -q get openvpn.$s.name)
        if [ "$name" = "$profile" ] || [ "$s" = "$profile" ]; then
            section="$s"
            break
        fi
    done

    if [ -n "$section" ]; then
        local pidfile="/var/run/openvpn-$section.pid"

        # UCI disable ZUERST
        uci set openvpn.$section.enable=0

        # Andere Config-Tunnel aktiv halten
        for tunnel_line in $(grep "^tunnel_[0-9]" "$CONFIG_FILE" 2>/dev/null); do
            local tprofile=$(echo "$tunnel_line" | cut -d"'" -f2 | cut -d: -f1)
            [ "$tprofile" = "$profile" ] && continue
            for s in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
                local name=$(uci -q get openvpn.$s.name)
                if [ "$name" = "$tprofile" ]; then
                    uci set openvpn.$s.enable=1
                fi
            done
        done

        uci commit openvpn
        /etc/init.d/openvpn reload
        log "UCI committed, reload ausgefuehrt"

        sleep 5

        # Falls noch laufend: killen
        local pid=$(ps | grep "openvpn($section)" | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$pid" ]; then
            log "Manueller kill: $pid"
            kill "$pid" 2>/dev/null
            rm -f "$pidfile"
        fi
    fi

    # Routing aufraeumen
    ip rule del fwmark "$fwmark" table "$table" 2>/dev/null
    ip route flush table "$table" 2>/dev/null
    rm -f "/tmp/vpn_tunnel_$idx"

    log "Tunnel $profile gestoppt"
}

# =============================================================================
# DEVICE ROUTING
# =============================================================================

start_wireguard_tunnel() {
    local profile="$1"
    local idx="$2"
    local fwmark="$3"
    local table="$4"

    log "WireGuard Tunnel: $profile (idx=$idx, fwmark=$fwmark, table=$table)"

    # Interface aktivieren und hochfahren falls nicht aktiv
    if ! ip link show "$profile" 2>/dev/null | grep -q "UP"; then
        log "WireGuard $profile nicht aktiv - starte via UCI + ifup"
        uci set network.$profile.disabled='0'
        uci commit network
        ifup "$profile" 2>/dev/null

        # Warten auf Interface (max 10s)
        local timeout=10
        while [ $timeout -gt 0 ]; do
            ip link show "$profile" 2>/dev/null | grep -q "UP" && break
            sleep 1
            timeout=$((timeout - 1))
        done
    fi

    if ! ip link show "$profile" 2>/dev/null | grep -q "UP"; then
        log "ERROR: WireGuard Interface $profile nicht gestartet"
        return 1
    fi

    # Routing Table einrichten
    local table_name="vpn_tunnel_$idx"
    grep -q "^$table[[:space:]]" "$RT_TABLES_FILE" 2>/dev/null || \
        echo "$table $table_name" >> "$RT_TABLES_FILE"

    # Default Route durch WG Interface
    ip route replace default dev "$profile" table "$table"
    ip rule del fwmark "$fwmark" table "$table" 2>/dev/null
    ip rule add fwmark "$fwmark" table "$table" priority "$table"

    echo "$profile" > "/tmp/vpn_tunnel_$idx"
    log "WireGuard $profile bereit (table=$table, fwmark=$fwmark)"
    return 0
}

stop_wireguard_tunnel() {
    local profile="$1"
    local idx="$2"
    local fwmark="$3"
    local table="$4"

    log "WireGuard Routing entfernen: $profile (idx=$idx)"

    ip rule del fwmark "$fwmark" table "$table" 2>/dev/null
    ip route flush table "$table" 2>/dev/null
    rm -f "/tmp/vpn_tunnel_$idx"

    # Interface herunterfahren und in UCI deaktivieren
    ifdown "$profile" 2>/dev/null
    uci set network.$profile.disabled='1'
    uci commit network
    log "WireGuard $profile gestoppt und in UCI deaktiviert"
}

add_device_routing() {
    local ip="$1"
    local fwmark="$2"
    local table="$3"

    log "Routing: $ip -> mark $fwmark -> table $table"

    # Alte Regeln entfernen (alle MARK-Regeln fuer diese IP)
    remove_all_marks_for_ip "$ip"

    # Neue Regel
    iptables -t mangle -A PREROUTING -s "$ip" -j MARK --set-mark "$fwmark"
}

remove_device_routing() {
    local ip="$1"
    local fwmark="$2"

    log "Remove Routing: $ip (alle MARK-Regeln)"

    # ALLE MARK-Regeln fuer diese IP entfernen (nicht nur spezifischen fwmark)
    # Verhindert verwaiste Regeln bei Index-Drift zwischen Enable/Disable
    remove_all_marks_for_ip "$ip"
}

# Hilfsfunktion: Alle iptables MARK-Regeln fuer eine IP entfernen
# iptables -D ... -j MARK (ohne --set-mark) funktioniert auf OpenWrt nicht,
# daher parsen wir die Regeln und entfernen sie einzeln
remove_all_marks_for_ip() {
    local ip="$1"
    local marks=$(iptables -t mangle -S PREROUTING 2>/dev/null | \
        grep "\-s ${ip}/32 .* MARK" | \
        sed -n 's/.*--set-xmark \(0x[0-9a-f]*\)\/.*/\1/p')

    for mark in $marks; do
        iptables -t mangle -D PREROUTING -s "$ip" -j MARK --set-mark "$mark" 2>/dev/null
        log "  Entfernt: $ip mark $mark"
    done
}

# =============================================================================
# COMMAND PROCESSOR
# =============================================================================

process_command() {
    local cmd="$1"

    [ -z "$cmd" ] && return

    log "CMD: $cmd"

    local action=$(echo "$cmd" | cut -d: -f1)
    local param1=$(echo "$cmd" | cut -d: -f2)
    local param2=$(echo "$cmd" | cut -d: -f3)
    local param3=$(echo "$cmd" | cut -d: -f4)
    local param4=$(echo "$cmd" | cut -d: -f5)
    local result="OK"

    case "$action" in
        tunnel_start)
            # WireGuard oder OpenVPN?
            if uci -q get network.$param1.proto 2>/dev/null | grep -q wireguard; then
                start_wireguard_tunnel "$param1" "$param2" "$param3" "$param4" || result="ERROR"
            else
                start_openvpn_tunnel "$param1" "$param2" "$param3" "$param4" || result="ERROR"
            fi
            send_response "$result"
            ;;
        tunnel_stop)
            if uci -q get network.$param1.proto 2>/dev/null | grep -q wireguard; then
                stop_wireguard_tunnel "$param1" "$param2" "$param3" "$param4"
            else
                stop_openvpn_tunnel "$param1" "$param2" "$param3" "$param4"
            fi
            send_response "$result"
            ;;
        routing_add)
            add_device_routing "$param1" "$param2" "$param3"
            send_response "$result"
            ;;
        routing_remove)
            remove_device_routing "$param1" "$param2"
            send_response "$result"
            ;;
        ping)
            send_response "PONG"
            ;;
        *)
            log "Unbekannt: $cmd"
            send_response "UNKNOWN"
            ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================

setup_fifos

log "Service Wrapper v5.0 gestartet (Request/Response FIFO)"

# CMD FIFO bidirektional oeffnen
exec 3<>"$FIFO_CMD"

# Hauptschleife
while true; do
    if read -r cmd <&3; then
        process_command "$cmd"
    fi
done
