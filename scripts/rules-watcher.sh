#!/bin/sh
#
# VPN Streaming Rules Watcher
# Laeuft als root und setzt iptables Regeln basierend auf Trigger-Datei
#

CONFIG_FILE="/etc/vpn-streaming/config"
TRIGGER_FILE="/tmp/vpn_rules_trigger"
LOG_TAG="vpn-rules"

log() {
    logger -t "$LOG_TAG" "$1"
}

get_mark_for_country() {
    case "$1" in
        at) echo "0x10" ;;
        ch) echo "0x11" ;;
        de) echo "0x12" ;;
        *) echo "0x10" ;;
    esac
}

apply_rules() {
    log "Wende iptables Regeln an..."
    
    # Config laden
    . "$CONFIG_FILE" 2>/dev/null || return 1
    
    local tunnels="$wireguard_tunnels"
    local device_list="$devices"
    
    [ -z "$tunnels" ] && { log "Keine Tunnel konfiguriert"; return 0; }
    [ -z "$device_list" ] && { log "Keine Devices konfiguriert"; return 0; }
    
    # Alte Regeln entfernen
    for ip in $(echo "$device_list" | tr ',' ' '); do
        for country in de ch at; do
            local ipset_name="${country}_ips"
            local mark=$(get_mark_for_country "$country")
            iptables -t mangle -D PREROUTING -s $ip -m set --match-set $ipset_name dst -j MARK --set-mark $mark 2>/dev/null
        done
    done
    
    # Neue Regeln setzen
    for ip in $(echo "$device_list" | tr ',' ' '); do
        for country in $(echo "$tunnels" | tr ',' ' ' | tr 'A-Z' 'a-z'); do
            local ipset_name="${country}_ips"
            local mark=$(get_mark_for_country "$country")
            if ipset list "$ipset_name" >/dev/null 2>&1; then
                iptables -t mangle -A PREROUTING -s $ip -m set --match-set $ipset_name dst -j MARK --set-mark $mark
                log "Regel: $ip -> $ipset_name -> $mark"
            else
                log "WARNUNG: ipset $ipset_name existiert nicht"
            fi
        done
    done
    
    log "iptables Regeln angewendet"
}

remove_rules() {
    log "Entferne iptables Regeln..."
    
    . "$CONFIG_FILE" 2>/dev/null || return 1
    local device_list="$devices"
    
    for ip in $(echo "$device_list" | tr ',' ' '); do
        for country in de ch at; do
            local ipset_name="${country}_ips"
            local mark=$(get_mark_for_country "$country")
            iptables -t mangle -D PREROUTING -s $ip -m set --match-set $ipset_name dst -j MARK --set-mark $mark 2>/dev/null
        done
    done
    
    log "iptables Regeln entfernt"
}

# Auto-VPN Daemon starten (als root)
start_autovpn() {
    local pid_file="/tmp/vpn-autovpn.pid"
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log "Auto-VPN Daemon laeuft bereits (PID $old_pid)"
            return 0
        fi
    fi
    /etc/vpn-streaming/scripts/vpn-autovpn.sh &
    log "Auto-VPN Daemon gestartet"
}

# Auto-VPN Daemon stoppen
stop_autovpn() {
    local pid_file="/tmp/vpn-autovpn.pid"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "$pid_file"
            log "Auto-VPN Daemon gestoppt"
        fi
    fi
}

# Trigger-Datei mit korrekten Permissions erstellen
touch /tmp/vpn_rules_trigger
chmod 666 /tmp/vpn_rules_trigger

# Hauptschleife - wartet auf Trigger-Datei
log "Rules Watcher gestartet"

while true; do
    if [ -f "$TRIGGER_FILE" ]; then
        action=$(cat "$TRIGGER_FILE")
        rm -f "$TRIGGER_FILE"

        case "$action" in
            apply) apply_rules ;;
            remove) remove_rules ;;
            autovpn_start) start_autovpn ;;
            autovpn_stop) stop_autovpn ;;
            vpn_on)
                # last_activity resetten damit Auto-VPN nicht sofort Idle-Timeout triggert
                echo "traffic=0" > /tmp/vpn_auto_traffic
                echo "last_activity=$(date +%s)" >> /tmp/vpn_auto_traffic
                /etc/vpn-streaming/scripts/vpn-control.sh on >/dev/null 2>&1
                log "VPN gestartet"
                ;;
            vpn_off) /etc/vpn-streaming/scripts/vpn-control.sh off >/dev/null 2>&1; log "VPN gestoppt" ;;
            *) log "Unbekannte Aktion: $action" ;;
        esac
    fi
    sleep 1
done
