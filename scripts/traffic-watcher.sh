#!/bin/sh
#
# VPN Streaming Traffic Watcher v4.0
# Auto-VPN: Aktiviert/Deaktiviert Tunnel basierend auf Device-Traffic
#
# Laeuft als Daemon, prueft periodisch ob Devices Traffic haben
#

CONFIG_DIR="/etc/vpn-streaming"
CONFIG_FILE="$CONFIG_DIR/config"
DEVICES_FILE="$CONFIG_DIR/devices.json"
VPN_CONTROL="$CONFIG_DIR/scripts/vpn-control.sh"
STATE_DIR="/tmp/vpn_traffic_state"
LOG_TAG="vpn-traffic"

CHECK_INTERVAL=30  # Sekunden zwischen Checks

log() { logger -t "$LOG_TAG" "$1"; }

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

init_state() {
    mkdir -p "$STATE_DIR"
}

# Speichere Packet-Count fuer Device
save_packet_count() {
    local ip="$1"
    local count="$2"
    local timestamp=$(date +%s)
    echo "$count:$timestamp" > "$STATE_DIR/$(echo $ip | tr '.' '_')"
}

# Lade letzten Packet-Count fuer Device
get_last_packet_count() {
    local ip="$1"
    local file="$STATE_DIR/$(echo $ip | tr '.' '_')"
    if [ -f "$file" ]; then
        cat "$file" | cut -d':' -f1
    else
        echo "0"
    fi
}

# Lade letzten Timestamp fuer Device
get_last_timestamp() {
    local ip="$1"
    local file="$STATE_DIR/$(echo $ip | tr '.' '_')"
    if [ -f "$file" ]; then
        cat "$file" | cut -d':' -f2
    else
        echo "0"
    fi
}

# =============================================================================
# TRAFFIC DETECTION
# =============================================================================

# Aktueller Packet-Count aus iptables (alle Packets von dieser Source-IP)
get_current_packet_count() {
    local ip="$1"

    # Zaehle Packets in mangle PREROUTING von dieser IP
    # Falls keine Regel existiert, nutze conntrack
    local count=$(iptables -t mangle -L PREROUTING -n -v 2>/dev/null | grep "^[[:space:]]*[0-9]" | grep "$ip" | awk '{sum+=$1} END {print sum}')

    if [ -z "$count" ] || [ "$count" = "0" ]; then
        # Fallback: conntrack
        count=$(conntrack -L 2>/dev/null | grep -c "$ip" || echo "0")
    fi

    echo "${count:-0}"
}

# Pruefe ob Device aktiven Traffic hat
has_active_traffic() {
    local ip="$1"
    local idle_timeout="$2"

    local current=$(get_current_packet_count "$ip")
    local last=$(get_last_packet_count "$ip")
    local last_ts=$(get_last_timestamp "$ip")
    local now=$(date +%s)

    # Speichere neuen Count
    save_packet_count "$ip" "$current"

    # Wenn Packets dazugekommen sind -> Traffic aktiv
    if [ "$current" -gt "$last" ]; then
        log "Device $ip: Traffic aktiv (packets: $last -> $current)"
        return 0
    fi

    # Kein neuer Traffic - pruefe Idle-Zeit
    local idle_seconds=$((now - last_ts))
    local timeout_seconds=$((idle_timeout * 60))

    if [ "$idle_seconds" -lt "$timeout_seconds" ]; then
        # Noch innerhalb Idle-Timeout
        return 0
    fi

    log "Device $ip: Idle timeout erreicht (${idle_seconds}s > ${timeout_seconds}s)"
    return 1
}

# =============================================================================
# DEVICE MANAGEMENT
# =============================================================================

# Lese Device-Info aus JSON
get_device_field() {
    local ip="$1"
    local field="$2"

    if [ -f "$DEVICES_FILE" ]; then
        local device=$(grep -o "{[^}]*\"ip\":\"$ip\"[^}]*}" "$DEVICES_FILE" | head -1)
        echo "$device" | grep -o "\"$field\":[^,}]*" | sed "s/\"$field\"://;s/\"//g"
    fi
}

# Alle Device-IPs mit Auto-VPN enabled
get_auto_vpn_devices() {
    if [ -f "$DEVICES_FILE" ]; then
        # Finde alle Devices mit auto_vpn:1 oder auto_vpn:true
        grep -o '{[^}]*"auto_vpn":[1t][^}]*}' "$DEVICES_FILE" | grep -o '"ip":"[^"]*"' | sed 's/"ip":"//;s/"//'
    fi
}

# Pruefe ob Device aktiv (VPN laeuft)
is_device_active() {
    local ip="$1"

    # Pruefe ob iptables MARK Regel existiert
    iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q "$ip"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

log "Traffic Watcher v4.0 gestartet (Interval: ${CHECK_INTERVAL}s)"

init_state

while true; do
    # Lade globale Auto-VPN Einstellung
    . "$CONFIG_FILE" 2>/dev/null
    auto_vpn_global="${auto_vpn_global:-0}"

    if [ "$auto_vpn_global" != "1" ]; then
        # Auto-VPN global deaktiviert
        sleep $CHECK_INTERVAL
        continue
    fi

    # Pruefe alle Devices mit Auto-VPN
    for ip in $(get_auto_vpn_devices); do
        tunnel=$(get_device_field "$ip" "tunnel")
        idle_timeout=$(get_device_field "$ip" "idle_timeout")
        idle_timeout="${idle_timeout:-15}"

        [ -z "$tunnel" ] && continue

        device_active=$(is_device_active "$ip" && echo "1" || echo "0")

        if has_active_traffic "$ip" "$idle_timeout"; then
            # Traffic aktiv
            if [ "$device_active" != "1" ]; then
                log "Auto-VPN: Aktiviere $ip (Traffic erkannt)"
                "$VPN_CONTROL" device-enable "$ip" >/dev/null 2>&1
            fi
        else
            # Idle
            if [ "$device_active" = "1" ]; then
                log "Auto-VPN: Deaktiviere $ip (Idle timeout)"
                "$VPN_CONTROL" device-disable "$ip" >/dev/null 2>&1
            fi
        fi
    done

    sleep $CHECK_INTERVAL
done
