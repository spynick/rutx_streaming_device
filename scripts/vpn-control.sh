#!/bin/sh
#
# VPN Streaming Control Script v4.0
# Multi-Device Multi-Tunnel Support
#
# Jedes Device kann einem eigenen Tunnel zugewiesen werden.
# Tunnel werden per Referenzzaehlung verwaltet.
#

CONFIG_DIR="/etc/vpn-streaming"
CONFIG_FILE="$CONFIG_DIR/config"
DEVICES_FILE="$CONFIG_DIR/devices.json"
FIFO_CMD="/tmp/vpn_service_cmd"
FIFO_RESP="/tmp/vpn_service_resp"

# Routing Konfiguration
RT_TABLE_BASE=200
MARK_BASE=32768  # 0x8000

# Synchroner Befehl an Service-Wrapper
send_command() {
    local cmd="$1"
    local timeout=30
    
    # Befehl senden
    echo "$cmd" > "$FIFO_CMD"
    
    # Auf Antwort warten (mit timeout)
    local response
    response=$(timeout $timeout cat "$FIFO_RESP" 2>/dev/null)
    
    if [ -z "$response" ]; then
        logger -t vpn-streaming "TIMEOUT waiting for response: $cmd"
        return 1
    fi
    
    [ "$response" = "OK" ] || [ "$response" = "PONG" ]
}

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================

# Initialisiere leere Config falls nicht vorhanden
init_config() {
    [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
# VPN Streaming v4.0 Configuration
device_count=0
tunnel_index=0
EOF
        chmod 666 "$CONFIG_FILE"
    fi

    # Devices JSON initialisieren
    if [ ! -f "$DEVICES_FILE" ]; then
        echo '{"devices":[]}' > "$DEVICES_FILE"
        chmod 666 "$DEVICES_FILE"
    fi
}

load_config() {
    init_config
    . "$CONFIG_FILE" 2>/dev/null
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# VPN Streaming v4.0 Configuration
device_count=$device_count
tunnel_index=$tunnel_index
# Active tunnels: tunnel_<hash>=profile:fwmark:table:refcount
EOF

    # Tunnel-Zuordnungen speichern
    set | grep "^tunnel_" | grep -v "tunnel_count|tunnel_profile\|tunnel_index" >> "$CONFIG_FILE"

    chmod 666 "$CONFIG_FILE"
}

# =============================================================================
# DEVICE MANAGEMENT (JSON-basiert)
# =============================================================================

# Lese alle Devices als JSON
get_devices_json() {
    if [ -f "$DEVICES_FILE" ]; then
        cat "$DEVICES_FILE"
    else
        echo '{"devices":[]}'
    fi
}

# Finde Device by IP - gibt JSON-Objekt zurueck
get_device() {
    local ip="$1"
    local devices=$(get_devices_json)

    # Simple grep-basierte Suche (ohne jq)
    echo "$devices" | grep -o "{[^}]*\"ip\":\"$ip\"[^}]*}" | head -1
}

# Device hinzufuegen oder aktualisieren
set_device() {
    local ip="$1"
    local name="$2"
    local tunnel="$3"
    local auto_vpn="${4:-1}"
    local idle_timeout="${5:-15}"
    local active="${6:-false}"

    local timestamp=$(date +%s)

    # Neues Device-Objekt
    local new_device="{\"ip\":\"$ip\",\"name\":\"$name\",\"tunnel\":\"$tunnel\",\"auto_vpn\":$auto_vpn,\"idle_timeout\":$idle_timeout,\"active\":$active,\"last_activity\":$timestamp}"

    # Lade aktuelle Devices
    local content=$(cat "$DEVICES_FILE" 2>/dev/null)
    [ -z "$content" ] && content='{"devices":[]}'

    # Extrahiere Array-Inhalt (zwischen [ und ])
    local array_content=$(echo "$content" | sed 's/^{"devices":\[//;s/\]}$//')

    # Baue neue Liste
    local new_list=""
    local found=0

    # Verarbeite jedes Device (getrennt durch },{ )
    if [ -n "$array_content" ]; then
        # Ersetze },{ durch Newline fuer einfache Verarbeitung
        echo "$array_content" | sed 's/},{/}\n{/g' | while read -r device; do
            [ -z "$device" ] && continue
            # Prüfe ob dieses Device die gesuchte IP hat
            if echo "$device" | grep -q "\"ip\":\"$ip\""; then
                # Ueberspringe - wird durch neues ersetzt
                :
            else
                # Behalte dieses Device
                if [ -n "$new_list" ]; then
                    new_list="$new_list,$device"
                else
                    new_list="$device"
                fi
            fi
        done
    fi

    # Da while-Schleife in Subshell läuft, machen wir es anders:
    # Filtere einfach die IP raus und füge neu hinzu
    if echo "$array_content" | grep -q "\"ip\":\"$ip\""; then
        # Device existiert - ersetze es
        # Entferne das alte Device-Objekt
        local other=$(echo "$array_content" | sed 's/},{/}\n{/g' | grep -v "\"ip\":\"$ip\"" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$other" ]; then
            echo "{\"devices\":[$other,$new_device]}" > "$DEVICES_FILE"
        else
            echo "{\"devices\":[$new_device]}" > "$DEVICES_FILE"
        fi
    else
        # Neues Device
        if [ -z "$array_content" ] || [ "$array_content" = "" ]; then
            echo "{\"devices\":[$new_device]}" > "$DEVICES_FILE"
        else
            echo "{\"devices\":[$array_content,$new_device]}" > "$DEVICES_FILE"
        fi
    fi

    chmod 666 "$DEVICES_FILE"
}

# Device entfernen
remove_device() {
    local ip="$1"
    local devices=$(get_devices_json)

    # Alle Devices ausser dem zu loeschenden
    local remaining=$(echo "$devices" | grep -o '{[^}]*"ip":"[^"]*"[^}]*}' | grep -v "\"ip\":\"$ip\"" | tr '\n' ',' | sed 's/,$//')

    if [ -n "$remaining" ]; then
        echo "{\"devices\":[$remaining]}" > "$DEVICES_FILE"
    else
        echo '{"devices":[]}' > "$DEVICES_FILE"
    fi

    chmod 666 "$DEVICES_FILE"
}

# Alle Device-IPs auflisten
list_device_ips() {
    get_devices_json | grep -o '"ip":"[^"]*"' | sed 's/"ip":"//;s/"//'
}

# Tunnel fuer Device abfragen
get_device_tunnel() {
    local ip="$1"
    local device=$(get_device "$ip")
    echo "$device" | grep -o '"tunnel":"[^"]*"' | sed 's/"tunnel":"//;s/"//'
}

# =============================================================================
# TUNNEL MANAGEMENT
# =============================================================================

# Generiere eindeutigen Index fuer Tunnel
# WICHTIG: Diese Funktion liest/schreibt tunnel_index direkt in die Config-Datei
# um Subshell-Probleme zu vermeiden
# Finde existierenden Tunnel Index (OHNE neuen zu erstellen)
find_tunnel_index() {
    local profile="$1"
    local existing=$(grep "^tunnel_[0-9]" "$CONFIG_FILE" | grep "=.$profile:" | head -1)
    if [ -n "$existing" ]; then
        echo "$existing" | sed "s/tunnel_\([0-9]*\)=.*/\1/"
        return 0
    fi
    return 1
}

get_tunnel_index() {
    local profile="$1"

    # Lade aktuelle Config
    . "$CONFIG_FILE" 2>/dev/null
    tunnel_index=${tunnel_index:-0}

    # Suche existierenden Tunnel mit diesem Profil
    local existing=$(grep "^tunnel_[0-9]" "$CONFIG_FILE" | grep "='$profile:" | head -1)
    if [ -n "$existing" ]; then
        # Extrahiere Index aus Variable-Name (tunnel_1='...' -> 1)
        local idx=$(echo "$existing" | sed "s/tunnel_\([0-9]*\)=.*/\1/")
        echo "$idx"
        return
    fi

    # Neuer Index - direkt in Config-Datei aktualisieren
    local new_index=$((tunnel_index + 1))
    sed -i "s/^tunnel_index=.*/tunnel_index=$new_index/" "$CONFIG_FILE"
    echo "$new_index"
}

# fwmark fuer Tunnel (0x8001, 0x8002, ...)
get_tunnel_fwmark() {
    local index="$1"
    printf "0x%x" $((MARK_BASE + index))
}

# Routing Table fuer Tunnel (201, 202, ...)
get_tunnel_table() {
    local index="$1"
    echo $((RT_TABLE_BASE + index))
}

# Tunnel aktivieren (mit Referenzzaehlung)
activate_tunnel() {
    local profile="$1"

    load_config

    local idx=$(get_tunnel_index "$profile")

    # WICHTIG: Config neu laden da get_tunnel_index tunnel_index geaendert haben koennte
    load_config

    local fwmark=$(get_tunnel_fwmark "$idx")
    local table=$(get_tunnel_table "$idx")
    local var_name="tunnel_$idx"

    # Aktuelle Daten laden
    eval "local current=\$$var_name"
    local refcount=0

    if [ -n "$current" ]; then
        refcount=$(echo "$current" | cut -d':' -f4)
    fi

    refcount=$((refcount + 1))

    # Speichere: profile:fwmark:table:refcount
    eval "$var_name=\"$profile:$fwmark:$table:$refcount\""
    save_config

    # Wenn erster User -> Tunnel starten
    if [ "$refcount" -eq 1 ]; then
        logger -t vpn-streaming "Aktiviere Tunnel: $profile (idx=$idx, mark=$fwmark, table=$table)"
        if ! send_command "tunnel_start:$profile:$idx:$fwmark:$table"; then
            logger -t vpn-streaming "ERROR: Tunnel $profile konnte nicht gestartet werden"
            # Rollback: refcount zuruecksetzen
            eval "unset $var_name"
            tunnel_index=$((tunnel_index - 1))
            save_config
            return 1
        fi
        return 0
    else
        logger -t vpn-streaming "Tunnel $profile bereits aktiv (refcount=$refcount)"
        return 0  # Tunnel war schon aktiv - kein Fehler
    fi
}

# Tunnel deaktivieren (mit Referenzzaehlung)
deactivate_tunnel() {
    local profile="$1"

    load_config

    local idx=$(find_tunnel_index "$profile")
    local var_name="tunnel_$idx"

    eval "local current=\$$var_name"
    [ -z "$current" ] && return 1

    local fwmark=$(echo "$current" | cut -d':' -f2)
    local table=$(echo "$current" | cut -d':' -f3)
    local refcount=$(echo "$current" | cut -d':' -f4)

    refcount=$((refcount - 1))

    if [ "$refcount" -le 0 ]; then
        # Letzter User -> Tunnel stoppen
        logger -t vpn-streaming "Deaktiviere Tunnel: $profile (keine User mehr)"
        unset "$var_name"
        save_config
        send_command "tunnel_stop:$profile:$idx:$fwmark:$table"
        return 0
    else
        # Noch andere User
        eval "$var_name=\"$profile:$fwmark:$table:$refcount\""
        save_config
        logger -t vpn-streaming "Tunnel $profile noch aktiv (refcount=$refcount)"
        return 1
    fi
}

# Finde Tunnel-Interface fuer Profil
find_tunnel_interface() {
    local profile="$1"

    # OpenVPN: tun_c_*
    for tun in $(ip link 2>/dev/null | grep -oE 'tun_c_[0-9]+'); do
        echo "$tun"
        return
    done

    # WireGuard: Interface-Name aus Profil (spaeter)
    # ...
}

# =============================================================================
# DEVICE ROUTING
# =============================================================================

# Routing fuer ein Device aktivieren
setup_device_routing() {
    local ip="$1"
    local tunnel_profile="$2"

    local idx=$(get_tunnel_index "$tunnel_profile")
    local fwmark=$(get_tunnel_fwmark "$idx")
    local table=$(get_tunnel_table "$idx")

    logger -t vpn-streaming "Setup Routing: $ip -> $tunnel_profile (mark=$fwmark, table=$table)"

    # Trigger fuer service-wrapper (laeuft als root)
    send_command "routing_add:$ip:$fwmark:$table"
}

# Routing fuer ein Device entfernen
clear_device_routing() {
    local ip="$1"
    local tunnel_profile="$2"

    local idx=$(get_tunnel_index "$tunnel_profile")
    local fwmark=$(get_tunnel_fwmark "$idx")

    logger -t vpn-streaming "Clear Routing: $ip"

    send_command "routing_remove:$ip:$fwmark"
}

# =============================================================================
# DEVICE ACTIVATION/DEACTIVATION
# =============================================================================

# Device aktivieren (startet Tunnel falls noetig)
enable_device() {
    local ip="$1"

    local device=$(get_device "$ip")
    [ -z "$device" ] && { echo '{"success":false,"error":"Device nicht gefunden"}'; return 1; }

    local tunnel=$(echo "$device" | grep -o '"tunnel":"[^"]*"' | sed 's/"tunnel":"//;s/"//')
    [ -z "$tunnel" ] && { echo '{"success":false,"error":"Kein Tunnel zugewiesen"}'; return 1; }

    # Pruefen ob Device schon aktiv ist - dann nur Routing, kein refcount++
    local already_active=$(echo "$device" | grep -o '"active":true')
    if [ -n "$already_active" ]; then
        logger -t vpn-streaming "Device $ip ist bereits aktiv - nur Routing"
        setup_device_routing "$ip" "$tunnel"
        echo "{\"success\":true,\"device\":\"$ip\",\"tunnel\":\"$tunnel\",\"enabled\":true}"
        return 0
    fi

    logger -t vpn-streaming "Aktiviere Device: $ip -> $tunnel"

    # Tunnel aktivieren (startet falls noetig)
    activate_tunnel "$tunnel"
    local tunnel_result=$?

    # Pruefen ob Tunnel erfolgreich gestartet wurde
    if [ $tunnel_result -ne 0 ]; then
        logger -t vpn-streaming "ERROR: Tunnel $tunnel konnte nicht gestartet werden"
        echo "{\"success\":false,\"error\":\"Tunnel konnte nicht gestartet werden - Credentials pruefen!\"}"
        return 1
    fi

    # Warten bis Tunnel bereit
    sleep 5

    # Routing fuer Device setzen
    setup_device_routing "$ip" "$tunnel"

    # Device als aktiv markieren
    local name=$(echo "$device" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
    local idle_timeout=$(echo "$device" | grep -o '"idle_timeout":[0-9]*' | sed 's/"idle_timeout"://')

    # Update device mit active=true
    set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout" true

    echo "{\"success\":true,\"device\":\"$ip\",\"tunnel\":\"$tunnel\",\"enabled\":true}"
}

# Device deaktivieren
disable_device() {
    local ip="$1"

    local device=$(get_device "$ip")
    [ -z "$device" ] && { echo '{"success":false,"error":"Device nicht gefunden"}'; return 1; }

    local tunnel=$(echo "$device" | grep -o '"tunnel":"[^"]*"' | sed 's/"tunnel":"//;s/"//')

    logger -t vpn-streaming "Deaktiviere Device: $ip"

    # Routing entfernen
    [ -n "$tunnel" ] && clear_device_routing "$ip" "$tunnel"

    # Tunnel deaktivieren (stoppt falls keine User mehr)
    [ -n "$tunnel" ] && deactivate_tunnel "$tunnel"

    # Device als inaktiv markieren
    local name=$(echo "$device" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
    local idle_timeout=$(echo "$device" | grep -o '"idle_timeout":[0-9]*' | sed 's/"idle_timeout"://')
    set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout" false

    echo "{\"success\":true,\"device\":\"$ip\",\"enabled\":false}"
}

# =============================================================================
# API FUNCTIONS
# =============================================================================

# GET /status - Kompletter Status
api_status() {
    load_config

    local devices_json=$(get_devices_json)

    # Aktive Tunnel zaehlen
    local active_tunnels=$(set | grep "^tunnel_" | grep -v "tunnel_count|tunnel_profile\|tunnel_index" | wc -l)

    # OpenVPN Profile aus UCI
    local ovpn_profiles="[]"
    local ovpn_list=""
    for section in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
        local name=$(uci -q get openvpn.$section.name)
        [ -z "$name" ] && name="$section"
        [ -n "$ovpn_list" ] && ovpn_list="$ovpn_list,"
        ovpn_list="$ovpn_list{\"id\":\"$section\",\"name\":\"$name\"}"
    done
    [ -n "$ovpn_list" ] && ovpn_profiles="[$ovpn_list]"

    cat << EOF
{
  "success": true,
  "data": {
    "version": "4.0",
    "devices": $(cat "$DEVICES_FILE" 2>/dev/null || echo '{"devices":[]}'),
    "tunnels": {
      "active_count": $active_tunnels,
      "available": $ovpn_profiles
    }
  }
}
EOF
}

# GET /devices - Alle Devices
api_devices_list() {
    echo "{\"success\":true,\"devices\":$(get_devices_json)}"
}

# POST /devices - Device hinzufuegen oder aktualisieren
api_device_add() {
    local ip="$1"
    local name="$2"
    local tunnel="$3"
    local auto_vpn="${4:-1}"
    local idle_timeout="${5:-15}"

    [ -z "$ip" ] && { echo '{"success":false,"error":"IP fehlt"}'; return 1; }
    [ -z "$name" ] && name="Device_$ip"
    [ -z "$tunnel" ] && tunnel=""

    # Pruefen ob Device existiert und aktiv war
    local old_device=$(get_device "$ip")
    local was_active="false"
    local old_tunnel=""

    if [ -n "$old_device" ]; then
        was_active=$(echo "$old_device" | grep -o '"active":[^,}]*' | sed 's/"active"://')
        old_tunnel=$(echo "$old_device" | grep -o '"tunnel":"[^"]*"' | sed 's/"tunnel":"//;s/"//')
    fi

    # Wenn Device aktiv war und Tunnel sich aendert -> Tunnel wechseln
    if [ "$was_active" = "true" ] && [ -n "$old_tunnel" ] && [ "$old_tunnel" != "$tunnel" ]; then
        logger -t vpn-streaming "Tunnel-Wechsel: $ip von $old_tunnel nach $tunnel"
        # Alten Tunnel deaktivieren
        clear_device_routing "$ip" "$old_tunnel"
        deactivate_tunnel "$old_tunnel"
        # Neuen Tunnel aktivieren
        if [ -n "$tunnel" ]; then
            activate_tunnel "$tunnel"
            sleep 3
            setup_device_routing "$ip" "$tunnel"
            set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout" true
        else
            set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout" false
        fi
    else
        # Normales Update (nicht aktiv oder gleicher Tunnel)
        local keep_active="false"
        [ "$was_active" = "true" ] && keep_active="true"
        set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout" "$keep_active"
    fi

    echo "{\"success\":true,\"device\":{\"ip\":\"$ip\",\"name\":\"$name\",\"tunnel\":\"$tunnel\"}}"
}

# DELETE /devices/{ip}
api_device_remove() {
    local ip="$1"

    # Erst deaktivieren falls aktiv
    disable_device "$ip" >/dev/null 2>&1

    remove_device "$ip"

    echo "{\"success\":true,\"removed\":\"$ip\"}"
}

# POST /devices/{ip}/tunnel - Tunnel zuweisen
api_device_set_tunnel() {
    local ip="$1"
    local tunnel="$2"

    local device=$(get_device "$ip")
    [ -z "$device" ] && { echo '{"success":false,"error":"Device nicht gefunden"}'; return 1; }

    local name=$(echo "$device" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
    local idle_timeout=$(echo "$device" | grep -o '"idle_timeout":[0-9]*' | sed 's/"idle_timeout"://')

    set_device "$ip" "$name" "$tunnel" "$auto_vpn" "$idle_timeout"

    echo "{\"success\":true,\"device\":\"$ip\",\"tunnel\":\"$tunnel\"}"
}

# POST /devices/{ip}/enable
api_device_enable() {
    enable_device "$1"
}

# POST /devices/{ip}/disable
api_device_disable() {
    disable_device "$1"
}

# GET /tunnels - Verfuegbare Tunnel
api_tunnels_list() {
    local tunnels="[]"
    local list=""

    for section in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d. -f2 | cut -d= -f1); do
        local name=$(uci -q get openvpn.$section.name)
        [ -z "$name" ] && name="$section"

        # Country/Provider extrahieren
        local country=$(echo "$name" | cut -d'_' -f1)
        local location=$(echo "$name" | sed 's/_[^_]*VPN$//' | tr '_' ' ')
        local provider=$(echo "$name" | grep -o '[^_]*VPN$')

        [ -n "$list" ] && list="$list,"
        list="$list{\"id\":\"$section\",\"name\":\"$name\",\"country\":\"$country\",\"location\":\"$location\",\"provider\":\"$provider\",\"type\":\"openvpn\"}"
    done

    # WireGuard Tunnel (Management-Interfaces ueberspringen)
    for section in $(uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1); do
        local proto=$(uci -q get network.$section.proto)
        [ "$proto" != "wireguard" ] && continue
        case "$section" in WG|MGMT|HOME|VPN|wg|mgmt|home|vpn) continue ;; esac

        local name="$section"
        local country=$(echo "$name" | cut -d'_' -f1)
        local location=$(echo "$name" | sed 's/_WG$//' | tr '_' ' ')
        local provider="WireGuard"

        [ -n "$list" ] && list="$list,"
        list="$list{\"id\":\"$section\",\"name\":\"$name\",\"country\":\"$country\",\"location\":\"$location\",\"provider\":\"$provider\",\"type\":\"wireguard\"}"
    done

    [ -n "$list" ] && tunnels="[$list]"

    echo "{\"success\":true,\"tunnels\":$tunnels}"
}

# GET /tunnels/active - Aktive Tunnel
api_tunnels_active() {
    load_config

    local active="[]"
    local list=""

    for var in $(set | grep "^tunnel_[0-9]" | cut -d'=' -f1); do
        eval "local data=\$$var"
        local profile=$(echo "$data" | cut -d':' -f1)
        local fwmark=$(echo "$data" | cut -d':' -f2)
        local table=$(echo "$data" | cut -d':' -f3)
        local refcount=$(echo "$data" | cut -d':' -f4)

        [ -n "$list" ] && list="$list,"
        list="$list{\"profile\":\"$profile\",\"fwmark\":\"$fwmark\",\"table\":$table,\"users\":$refcount}"
    done

    [ -n "$list" ] && active="[$list]"

    echo "{\"success\":true,\"active\":$active}"
}

# =============================================================================
# CREDENTIAL MANAGEMENT
# =============================================================================

# Erkennt Provider anhand der auth-user-pass Referenzen in .ovpn Dateien
# Gibt pro Auth-Datei einen Provider-Eintrag zurueck
api_credentials_list() {
    local list=""

    # OpenVPN: auth-user-pass Dateien aus .ovpn Profilen sammeln
    local auth_files=""
    for ovpn in /etc/vuci-uploads/*.ovpn; do
        [ -f "$ovpn" ] || continue
        local auth=$(grep "^auth-user-pass " "$ovpn" 2>/dev/null | awk '{print $2}' | head -1)
        [ -z "$auth" ] && continue

        # Duplikate vermeiden
        echo "$auth_files" | grep -q "$auth" && continue
        auth_files="$auth_files $auth"

        # Provider-Name aus Dateiname ableiten
        local provider=""
        case "$auth" in
            *nordvpn*) provider="NordVPN" ;;
            *surfshark*) provider="Surfshark" ;;
            *express*) provider="ExpressVPN" ;;
            *proton*) provider="ProtonVPN" ;;
            *cyberghost*) provider="CyberGhost" ;;
            *) provider=$(basename "$auth" | sed 's/_auth.*//;s/\.txt//') ;;
        esac

        # Pruefen ob Credentials gesetzt sind
        local has_creds="false"
        local username=""
        if [ -f "$auth" ]; then
            local lines=$(wc -l < "$auth" 2>/dev/null)
            if [ "$lines" -ge 2 ]; then
                has_creds="true"
                username=$(head -1 "$auth" 2>/dev/null)
            fi
        fi

        # Anzahl Profile die diese Auth-Datei nutzen
        local profile_count=$(grep -rl "auth-user-pass $auth" /etc/vuci-uploads/ 2>/dev/null | wc -l)

        [ -n "$list" ] && list="$list,"
        list="$list{\"provider\":\"$provider\",\"auth_file\":\"$auth\",\"has_credentials\":$has_creds,\"username\":\"$username\",\"profile_count\":$profile_count}"
    done

    echo "{\"success\":true,\"credentials\":[$list]}"
}

# Credentials setzen: provider_auth_file username password
api_credentials_set() {
    local auth_file="$1"
    local username="$2"
    local password="$3"

    if [ -z "$auth_file" ] || [ -z "$username" ] || [ -z "$password" ]; then
        echo '{"success":false,"error":"auth_file, username und password erforderlich"}'
        return 1
    fi

    # Sicherheitscheck: nur bekannte Pfade erlauben
    case "$auth_file" in
        /etc/openvpn/*) ;;
        *) echo '{"success":false,"error":"Ungueltiger auth_file Pfad"}'; return 1 ;;
    esac

    # Verzeichnis existiert?
    local dir=$(dirname "$auth_file")
    [ -d "$dir" ] || mkdir -p "$dir"

    # Auth-Datei schreiben (Username Zeile 1, Password Zeile 2)
    printf "%s\n%s\n" "$username" "$password" > "$auth_file"
    chmod 600 "$auth_file"

    logger -t vpn-streaming "Credentials gesetzt fuer: $auth_file (user=$username)"

    echo "{\"success\":true,\"auth_file\":\"$auth_file\",\"username\":\"$username\"}"
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

json_error() {
    echo "{\"success\":false,\"error\":\"$1\"}"
    exit 1
}

case "$1" in
    # Status
    status)
        api_status
        ;;

    # Device Management
    devices)
        api_devices_list
        ;;
    device-add)
        api_device_add "$2" "$3" "$4" "$5" "$6"
        ;;
    device-remove)
        api_device_remove "$2"
        ;;
    device-tunnel)
        api_device_set_tunnel "$2" "$3"
        ;;
    device-enable)
        api_device_enable "$2"
        ;;
    device-disable)
        api_device_disable "$2"
        ;;

    # Tunnel Management
    tunnels)
        api_tunnels_list
        ;;
    tunnels-active)
        api_tunnels_active
        ;;

    # Credential Management
    credentials)
        api_credentials_list
        ;;
    credentials-set)
        api_credentials_set "$2" "$3" "$4"
        ;;

    # Legacy/Compat
    on)
        # Aktiviere alle Devices mit zugewiesenem Tunnel
        for ip in $(list_device_ips); do
            tunnel=$(get_device_tunnel "$ip")
            [ -n "$tunnel" ] && enable_device "$ip"
        done
        echo '{"success":true}'
        ;;
    off)
        # Deaktiviere alle Devices
        for ip in $(list_device_ips); do
            disable_device "$ip" >/dev/null
        done
        echo '{"success":true}'
        ;;

    *)
        echo "VPN Streaming Control v4.0"
        echo ""
        echo "Usage: $0 <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  status                    Show full status"
        echo "  devices                   List all devices"
        echo "  device-add <ip> [name] [tunnel]"
        echo "  device-remove <ip>        Remove device"
        echo "  device-tunnel <ip> <tunnel>  Assign tunnel to device"
        echo "  device-enable <ip>        Enable VPN for device"
        echo "  device-disable <ip>       Disable VPN for device"
        echo "  tunnels                   List available tunnels"
        echo "  tunnels-active            List active tunnels"
        echo "  on                        Enable all devices"
        echo "  off                       Disable all devices"
        exit 1
        ;;
esac
