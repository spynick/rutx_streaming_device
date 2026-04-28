# VPN Streaming v5.0

Device-basiertes Multi-Tunnel VPN-Routing für Teltonika RUTX Router (OpenWrt/RutOS).

**Jedes Streaming-Gerät bekommt seinen eigenen VPN-Tunnel - inkl. DNS, DRM und CDN.**

## Features

- **Multi-Device Support** - Jedes Gerät kann einem eigenen VPN-Tunnel zugewiesen werden
- **Multi-Tunnel** - Mehrere VPN-Tunnel gleichzeitig aktiv (z.B. FireTV -> AT, AppleTV -> CH)
- **OpenVPN + WireGuard** - Beide Protokolle gleichzeitig nutzbar
- **Policy-Based Routing** - Traffic wird per iptables MARK und ip rule geroutet
- **Standalone WebUI** - Browser-Verwaltung auf Port 8080
- **Credentials Management** - VPN-Zugangsdaten per WebUI oder CLI verwalten
- **Firmware-Update-sicher** - Konfiguration überlebt sysupgrade (RutOS Updates)
- **Home Assistant Integration** - Dynamische Device-Steuerung via REST API
- **RUTOS-kompatibel** - UCI-Synchronisation mit nativer Router-Oberfläche
- **Geschützte Management-VPNs** - WG, MGMT, HOME, VPN werden nie angefasst

## Warum Device-basiert?

Wir haben Domain-basiertes Routing (dnsmasq/ipset) ausführlich getestet - es scheitert am DRM-Problem:

```
Domain-basiertes Routing:
  orf.at        -> VPN (AT)     OK
  akamai.net    -> VPN (AT)     OK
  widevine.com  -> KEIN VPN     FAIL!

Was passiert:
1. Browser lädt ORF Player    -> geht über VPN (AT-IP)
2. ORF gibt Lizenz-Token       -> gebunden an AT-IP
3. Widevine prüft Lizenz      -> geht NICHT über VPN (DE-IP)
4. Widevine sieht: Token sagt AT, Request kommt von DE
5. -> Lizenz verweigert, schwarzer Bildschirm
```

**Die Lösung: Device-basiertes Routing.** Kompletter Traffic vom Streaming-Gerät durch VPN - inkl. DNS, DRM, CDN, alles. Damit sehen alle Server dieselbe IP.

```
Device-basiertes Routing:
  FireTV 192.168.110.239 -> ALLES durch VPN

  orf.at        -> VPN (AT)     OK
  akamai.net    -> VPN (AT)     OK
  widevine.com  -> VPN (AT)     OK
  dns-anfragen  -> VPN (AT)     OK

-> Lizenz OK, Streaming funktioniert
```

## Architektur

### Übersicht

```
+------------------------------------------------------------------+
|                    RUTX Router (192.168.110.1)                    |
|                                                                   |
|   WebUI :8080          CGI API            vpn-control.sh          |
|   (Browser)    ----->  (uhttpd)   ----->  (CLI/API)               |
|                                               |                   |
|                                      FIFO (CMD/RESP)              |
|                                               |                   |
|                                               v                   |
|                                       service-wrapper.sh          |
|                                          (root daemon)            |
|                                               |                   |
|                          +--------------------+----+              |
|                          |                    |    |              |
|                     UCI/OpenVPN         iptables  ip rule/route   |
|                          |                    |    |              |
|                     tun_c_*/WG         MARK rules  table 201+    |
+------------------------------------------------------------------+
         |                              |
    VPN Tunnel 1                   VPN Tunnel 2
   (AT NordVPN)                  (CH WireGuard)
         |                              |
         v                              v
   NordVPN Server              WireGuard Endpoint
```

### Komponenten

| Datei | Beschreibung |
|-------|--------------|
| `scripts/vpn-control.sh` | CLI und API - Device/Tunnel Management, Credentials |
| `scripts/service-wrapper.sh` | Root-Daemon - UCI, iptables, ip rule/route (FIFO IPC) |
| `scripts/wg-setup.sh` | WireGuard Profile Import (UCI-kompatibel) |
| `scripts/install.sh` | Installer mit sysupgrade-Schutz |
| `scripts/cleanup.sh` | Vollständige Deinstallation |
| `www/index.html` | WebUI |
| `www/app.js` | Frontend-Logik |
| `www/style.css` | UI Styling |
| `www/api/vpn-streaming` | CGI API (HTTP -> vpn-control.sh) |

### IPC: Dual-FIFO Pattern

```
vpn-control.sh                    service-wrapper.sh (root)
      |                                    |
      |  echo "tunnel_start:..."           |
      |  -------> /tmp/vpn_service_cmd --> |
      |                                    | verarbeitet Befehl
      |                                    | (UCI, iptables, ...)
      |  <------- /tmp/vpn_service_resp <--|
      |  "OK"                              |
```

Vorteile gegenüber Trigger-Datei (v3):
- Keine Befehle gehen verloren
- Synchrone Verarbeitung (Request/Response)
- Kein Polling nötig
- 30 Sekunden Timeout

### Datenfluss: Device aktivieren

```
1. User klickt "Enable" in WebUI
2. Browser -> POST /api/vpn-streaming/devices/{ip}/enable
3. CGI Script -> vpn-control.sh device-enable {ip}
4. vpn-control.sh:
   a. Liest devices.json -> findet Tunnel-Zuweisung
   b. Prüft ob Tunnel bereits aktiv (Referenzzählung)
   c. Falls neuer Tunnel: send_command "tunnel_start:profile:idx:fwmark:table"
   d. send_command "routing_add:ip:fwmark:table"
5. service-wrapper.sh (root):
   a. tunnel_start -> UCI enable + OpenVPN reload (oder ifup für WireGuard)
   b. Wartet auf Interface (max 15s)
   c. Richtet Routing Table ein (ip route)
   d. routing_add -> iptables MARK Regel für Device-IP
6. Antwort -> Browser -> Status-Update
```

## Voraussetzungen

### Hardware

- Teltonika RUTX Router (getestet mit RUTX50)
- Streaming-Gerät mit fester IP (FireTV, Apple TV, etc.)

### Software

- RutOS (OpenWrt-basiert)
- uhttpd (normalerweise vorinstalliert)

### VPN Account

- **NordVPN** empfohlen (funktioniert für DE/AT/CH)
- ExpressVPN (nur DE)
- Alternativ: WireGuard-Tunnel zu eigenem Heimanschluss (Residential IP)

## Installation

### Variante 1: Remote Install (empfohlen)

Direkt auf dem Router via SSH:

```bash
ssh root@192.168.110.1
wget -qO- https://raw.githubusercontent.com/spynick/rutx_streaming_device/main/install-remote.sh | sh
```

### Variante 2: Manuell

```bash
# Von deinem Rechner:
scp -r rutx_streaming_device root@192.168.110.1:/tmp/vpn-install

# Auf dem Router:
ssh root@192.168.110.1
cd /tmp/vpn-install/scripts
chmod +x install.sh
./install.sh
```

### Was der Installer macht

1. Erstellt `/etc/vpn-streaming/` Verzeichnisstruktur
2. Installiert Scripts, WebUI, CGI API
3. Kopiert OpenVPN Profile (falls vorhanden)
4. Erstellt Config und devices.json (überschreibt bestehende NICHT)
5. Richtet procd-Service ein (Autostart + Respawn)
6. Konfiguriert uhttpd (Port 8080)
7. Öffnet Firewall-Port 8080
8. Konfiguriert sysupgrade.conf (Firmware-Update-Schutz)
9. Patcht OpenVPN auth-user-pass Direktiven
10. Startet Services und verifiziert

## Konfiguration

### 1. OpenVPN Profile

Profile können auf zwei Wegen importiert werden:

**Via Teltonika WebUI (empfohlen):**

1. Services > VPN > OpenVPN
2. Neues Client-Profil erstellen
3. .ovpn Datei hochladen
4. **NICHT aktivieren** - das macht VPN Streaming

**Via install.sh:**

.ovpn Dateien in `profiles/openvpn/` legen, werden automatisch nach `/etc/vuci-uploads/` kopiert.

### 2. WireGuard Tunnel

```bash
# Profile importieren
/etc/vpn-streaming/scripts/wg-setup.sh add CH_Home_WG /tmp/wg-config.conf

# Alle WG Interfaces anzeigen
/etc/vpn-streaming/scripts/wg-setup.sh list
```

**Wichtig für Streaming-Tunnel:**

```bash
uci set network.<TUNNEL>.disabled='1'          # Default deaktiviert
uci set network.<TUNNEL>.route_allowed_ips='0'  # Keine automatische Default Route
uci commit network
```

- `disabled='1'` - Nur Streaming Devices sollen den Tunnel nutzen
- `route_allowed_ips='0'` - Verhindert dass WireGuard eine Default Route setzt bei `AllowedIPs = 0.0.0.0/0`. Policy-Based Routing übernimmt das.

### 3. VPN Credentials

**Via WebUI:**

1. WebUI öffnen (`http://ROUTER-IP:8080/`)
2. Button "Passwörter" klicken
3. Provider werden automatisch erkannt (aus .ovpn auth-user-pass)
4. Username und Passwort eintragen
5. Speichern

**Via CLI:**

```bash
# Provider mit Credential-Status anzeigen
/etc/vpn-streaming/scripts/vpn-control.sh credentials

# Credentials setzen
/etc/vpn-streaming/scripts/vpn-control.sh credentials-set \
    /etc/openvpn/nordvpn_auth.txt USERNAME PASSWORT
```

Die Credentials werden pro Provider gespeichert (nicht pro Profil). Alle NordVPN-Profile nutzen z.B. `/etc/openvpn/nordvpn_auth.txt`.

### 4. Streaming Device hinzufügen

**Via WebUI:**

1. `http://ROUTER-IP:8080/` öffnen
2. "+ Device" klicken
3. IP-Adresse, Name und Tunnel wählen
4. "Hinzufügen"
5. Toggle zum Aktivieren

**Via CLI:**

```bash
/etc/vpn-streaming/scripts/vpn-control.sh device-add 192.168.110.239 "FireTV" "DE_Frankfurt_NordVPN"
/etc/vpn-streaming/scripts/vpn-control.sh device-enable 192.168.110.239
```

## Tunnel-Naming Convention

Profile müssen dem Schema folgen für automatische Länder-Erkennung in der WebUI:

```
{LAND}_{Stadt}_{Provider}
```

Beispiele:
- `DE_Frankfurt_NordVPN` -> DE Frankfurt (Flagge)
- `AT_Wien_NordVPN` -> AT Wien (Flagge)
- `CH_Zuerich_NordVPN` -> CH Zuerich (Flagge)
- `CH_Home_WG` -> CH Home (WireGuard)

Unterstützte Länder-Flags in der WebUI: DE, CH, AT, US, UK, NL (erweiterbar in app.js)

## WebUI

Erreichbar unter: `http://<router-ip>:8080/`

### Bereiche

| Bereich | Funktion |
|---------|----------|
| **Streaming Devices** | Grid mit allen Devices - Tunnel-Zuweisung, Enable/Disable, Edit |
| **Aktive Tunnel** | Liste der aktuell laufenden Tunnel mit Benutzeranzahl |
| **Steuerung** | Alle An, Alle Aus, Passwörter |
| **Verfügbare Tunnel** | Alle erkannten OpenVPN + WireGuard Tunnel (aufklappbar) |

### Features

- Devices hinzufügen, bearbeiten, löschen
- Tunnel per Device zuweisen und wechseln
- VPN pro Device ein/ausschalten
- Credentials pro VPN-Provider verwalten
- Auto-Refresh alle 5 Sekunden
- Responsive Design (Mobile-tauglich)

## CLI Befehle

```bash
VPN=/etc/vpn-streaming/scripts/vpn-control.sh

# Status
$VPN status                              # Kompletter JSON Status
$VPN devices                             # Alle Devices
$VPN tunnels                             # Verfügbare Tunnel
$VPN tunnels-active                      # Aktive Tunnel

# Device Management
$VPN device-add <ip> [name] [tunnel]     # Device hinzufügen
$VPN device-remove <ip>                  # Device entfernen
$VPN device-tunnel <ip> <tunnel>         # Tunnel zuweisen
$VPN device-enable <ip>                  # VPN für Device aktivieren
$VPN device-disable <ip>                 # VPN für Device deaktivieren

# Bulk
$VPN on                                  # Alle Devices aktivieren
$VPN off                                 # Alle Devices deaktivieren

# Credentials
$VPN credentials                         # Provider-Liste mit Status
$VPN credentials-set <auth_file> <user> <pass>  # Credentials setzen
```

## API Endpoints

Die CGI API ist unter `/api/vpn-streaming/` erreichbar (uhttpd Port 8080):

| Method | Endpoint | Beschreibung |
|--------|----------|--------------|
| GET | `/status` | Kompletter System-Status |
| GET | `/devices` | Alle Devices |
| POST | `/devices` | Device hinzufügen (JSON Body) |
| DELETE | `/devices/{ip}` | Device entfernen |
| POST | `/devices/{ip}/tunnel` | Tunnel zuweisen |
| POST | `/devices/{ip}/enable` | VPN für Device aktivieren |
| POST | `/devices/{ip}/disable` | VPN für Device deaktivieren |
| GET | `/tunnels` | Verfügbare Tunnel (OpenVPN + WireGuard) |
| GET | `/tunnels/active` | Aktive Tunnel mit Referenzzählung |
| POST | `/enable-all` | Alle Devices aktivieren |
| POST | `/disable-all` | Alle Devices deaktivieren |
| GET | `/credentials` | Provider mit Credential-Status |
| POST | `/credentials` | Credentials setzen |

### Beispiele

```bash
# Status abfragen
curl http://192.168.110.1:8080/api/vpn-streaming/status

# Device hinzufügen
curl -X POST http://192.168.110.1:8080/api/vpn-streaming/devices \
  -H "Content-Type: application/json" \
  -d '{"ip":"192.168.110.239","name":"FireTV","tunnel":"AT_Wien_NordVPN"}'

# Device aktivieren
curl -X POST http://192.168.110.1:8080/api/vpn-streaming/devices/192.168.110.239/enable

# Credentials setzen
curl -X POST http://192.168.110.1:8080/api/vpn-streaming/credentials \
  -H "Content-Type: application/json" \
  -d '{"auth_file":"/etc/openvpn/nordvpn_auth.txt","username":"USER","password":"PASS"}'
```

### Status Response

```json
{
  "success": true,
  "devices": [
    {
      "ip": "192.168.110.239",
      "name": "FireTV",
      "tunnel": "AT_Wien_NordVPN",
      "active": true,
      "auto_vpn": 0,
      "idle_timeout": 15
    }
  ],
  "active_tunnels": [
    {
      "profile": "AT_Wien_NordVPN",
      "fwmark": "0x8001",
      "table": 201,
      "users": 1
    }
  ],
  "service_running": true
}
```

## Routing im Detail

### So funktioniert's

```
Device 192.168.110.239 (FireTV)
    |
    | iptables -t mangle PREROUTING
    | -s 192.168.110.239 -j MARK --set-mark 0x8001
    |
    v
ip rule: fwmark 0x8001 -> table 201
    |
    v
ip route table 201: default dev tun_c_11
    |
    v
OpenVPN Tunnel -> NordVPN AT Server
    |
    v
Internet (ORF, ARD, Netflix, ...)
```

### Routing-Parameter

| Parameter | Berechnung | Beispiel |
|-----------|------------|---------|
| fwmark | 0x8000 + tunnel_index | 0x8001, 0x8002, ... |
| Routing Table | 200 + tunnel_index | 201, 202, ... |
| Priority | = table | 201, 202, ... |

### Referenzzählung

Wenn mehrere Devices denselben Tunnel nutzen, wird der Tunnel nur einmal gestartet:

```
FireTV  -> AT_Wien_NordVPN  (refcount=1, Tunnel starten)
AppleTV -> AT_Wien_NordVPN  (refcount=2, Tunnel läuft bereits)
FireTV  disable             (refcount=1, Tunnel bleibt)
AppleTV disable             (refcount=0, Tunnel stoppen)
```

### iptables Cleanup

Auf OpenWrt funktioniert `iptables -D ... -j MARK` (ohne `--set-mark`) nicht. Darum parst der Service-Wrapper die Regeln via `iptables -S` und entfernt sie einzeln:

```bash
# So werden ALLE MARK-Regeln für eine IP entfernt:
iptables -t mangle -S PREROUTING | grep "-s IP/32 .* MARK" | ...
# -> Extrahiert fwmark aus --set-xmark
# -> Entfernt jede Regel einzeln mit --set-mark
```

## Dateistruktur

### Repository

```
rutx_streaming_device/
  README.md                             # Diese Dokumentation
  install-remote.sh                     # Einzeiler Remote-Installer
  profiles/
    openvpn/                            # .ovpn Profile (ohne Credentials)
      vpn_AT-Wien_nordvpn.ovpn
      vpn_CH-Zuerich_nordvpn.ovpn
      vpn_DE-Frankfurt_nordvpn.ovpn
      ...
    wireguard/                          # .conf Dateien (NICHT im Repo)
  scripts/
    install.sh                          # Haupt-Installer
    vpn-control.sh                      # CLI/API Controller
    service-wrapper.sh                  # Root-Daemon (FIFO IPC)
    wg-setup.sh                         # WireGuard Import
    cleanup.sh                          # Deinstallation
  www/
    index.html                          # WebUI
    style.css                           # Design
    app.js                              # Frontend-Logik
    api/
      vpn-streaming                     # CGI API Script
  ha_integration/
    rutx_vpn_streaming_v5.yaml          # Home Assistant Package
    lovelace_card_v5.yaml               # Lovelace Dashboard Card
  domains/                              # Streaming-Domain-Listen (Legacy)
    de_streaming.txt
    ch_streaming.txt
    at_streaming.txt
```

### Auf dem Router nach Installation

```
/etc/vpn-streaming/
  config                                # Tunnel-State (aktive Tunnel, Index)
  devices.json                          # Device-Datenbank (IP, Name, Tunnel)
  profiles/
    openvpn/                            # .ovpn Profile
    wireguard/                          # .conf Dateien
  scripts/
    vpn-control.sh                      # CLI/API Controller
    service-wrapper.sh                  # Root-Daemon
    wg-setup.sh                         # WireGuard Import
    cleanup.sh                          # Deinstallation
  www/
    index.html                          # WebUI
    style.css
    app.js
    api/
      vpn-streaming                     # CGI API

/etc/init.d/
  vpn-streaming                         # procd Service (Autostart + Respawn)

/etc/sysupgrade.conf                    # Firmware-Update-Schutz (Einträge)

/tmp/
  vpn_service_cmd                       # FIFO: Befehle an Service-Wrapper
  vpn_service_resp                      # FIFO: Antworten vom Service-Wrapper
```

## TABU Interfaces

Folgende WireGuard/Interface-Namen sind geschützt und werden NIEMALS angefasst:

- `WG` / `wg` (und Varianten wie `WG_backup`)
- `MGMT` / `mgmt`
- `HOME` / `home`
- `VPN` / `vpn`
- `Connect` / `connect`

Diese werden:
- Nicht in der Tunnel-Liste angezeigt
- Beim Cleanup nicht deaktiviert
- Niemals gelöscht

## Firmware-Update-Schutz

RutOS überschreibt bei Firmware-Updates `/etc/`. VPN Streaming schützt sich via `/etc/sysupgrade.conf`:

```
/etc/vpn-streaming/
/etc/openvpn/nordvpn_auth.txt
/etc/iproute2/rt_tables
/etc/init.d/vpn-streaming
```

Nach einem Firmware-Update:
- Alle Dateien bleiben erhalten
- Service startet automatisch via procd (init.d)
- Keine manuelle Wiederherstellung nötig

**Hinweis:** UCI-Konfiguration (uhttpd, firewall, openvpn, network) wird von RutOS verwaltet und muss ggf. nach einem Major-Update neu konfiguriert werden. Ein erneutes `install.sh` erledigt das automatisch.

## Home Assistant Integration

### Installation

1. `ha_integration/rutx_vpn_streaming_v5.yaml` nach `/config/packages/vpn_streaming.yaml` kopieren
2. In `configuration.yaml`:
   ```yaml
   homeassistant:
     packages: !include_dir_named packages
   ```
3. Home Assistant neu starten
4. Router Host IP eintragen (`input_text.vpn_streaming_host`)

### Lovelace Dashboard

`ha_integration/lovelace_card_v5.yaml` als YAML-Karte einfügen.

### Benötigt (HACS)

- `custom:button-card`
- `custom:auto-entities` (dynamische Device-Liste)
- `custom:mushroom-title-card` (optional)

### Features

- Dynamische Device-Liste (keine Hardcoding nötig)
- Pro Device: Tunnel ein/aus schalten
- Pro Device: Tunnel wechseln
- Devices hinzufügen/löschen
- Status-Anzeige (verbunden/getrennt)

## Warum kein Auto-VPN?

### Die Idee

Auto-VPN sollte das VPN automatisch aktivieren wenn ein Gerät Traffic erzeugt, und nach Idle-Timeout deaktivieren.

### Warum es für Streaming NICHT funktioniert

```
Timeline bei Auto-VPN:
------------------------------------------------------------
0.0s   User startet Netflix-App
0.1s   App macht ersten API-Call an Netflix-Server
       -> Netflix sieht: IP aus Österreich
       -> Geo-Check: "Kein US-Abo für diese Region"
0.2s   Auto-VPN erkennt Traffic vom Streaming-Device
0.3s   Trigger: VPN soll starten
5-15s  VPN-Tunnel ist aufgebaut und aktiv
       -> ZU SPAET! Netflix hat Standort bereits gecheckt
------------------------------------------------------------
```

Die ersten 2-3 Pakete, die ohne VPN rausgehen, verraten den echten Standort. Und diese Pakete sind die entscheidenden für Geo-Blocking.

### Wann Auto-VPN sinnvoll wäre

| Use-Case | Auto-VPN sinnvoll? |
|----------|-------------------|
| Geo-Unblocking (Netflix, etc.) | **NEIN** - erster Request entscheidend |
| Traffic-Kosten sparen | JA - Volumen zählt, nicht erster Request |
| Privacy on-demand | JA - meiste Requests nicht zeitkritisch |

### Unsere Lösung

Der einzig zuverlässige Weg für Geo-Unblocking:

1. WebUI oder Home Assistant öffnen
2. Toggle für das Streaming-Gerät aktivieren
3. Warten bis VPN aktiv (Status: "Aktiv")
4. **Dann erst** Streaming-App starten

**Merksatz:** Für Geo-Unblocking muss das VPN **BEVOR** die App startet aktiv sein, nicht **NACHDEM** sie Traffic erzeugt.

## Troubleshooting

### Status prüfen

```bash
# Kompletter Status (JSON)
/etc/vpn-streaming/scripts/vpn-control.sh status

# UCI OpenVPN Status
uci show openvpn | grep enable

# UCI WireGuard Status
uci show network | grep disabled | grep -i wg

# Aktive Prozesse
ps | grep -E "openvpn|service-wrapper"

# iptables Regeln (MARK)
iptables -t mangle -L PREROUTING -n -v

# iptables Regeln (detailliert mit fwmark)
iptables -t mangle -S PREROUTING

# Routing Rules
ip rule show

# Routing Table (ersetze 201 mit tatsächlicher Nummer)
ip route show table 201
```

### Logs

```bash
# Service-Wrapper Logs
logread | grep vpn-service

# OpenVPN Logs
logread | grep openvpn

# VPN Control Logs
logread | grep vpn-streaming
```

### Häufige Probleme

**Service-Wrapper läuft nicht:**
```bash
# Status prüfen
/etc/init.d/vpn-streaming status

# Manuell starten
/etc/init.d/vpn-streaming start

# FIFOs prüfen
ls -la /tmp/vpn_service_*  # sollte prw-rw-rw- sein
```

**WebUI zeigt "Getrennt":**
- Service-Wrapper läuft? `ps | grep service-wrapper`
- FIFO existiert? `ls -la /tmp/vpn_service_cmd`
- Service neustarten: `/etc/init.d/vpn-streaming restart`

**Tunnel startet nicht:**
```bash
# OpenVPN Config vorhanden?
ls /var/run/openvpn/

# UCI Section korrekt?
uci show openvpn | grep <profilname>

# Credentials gesetzt?
/etc/vpn-streaming/scripts/vpn-control.sh credentials
```

**Device-Traffic geht nicht durch VPN:**
```bash
# iptables Regel vorhanden?
iptables -t mangle -S PREROUTING | grep 192.168.110.239

# IP Rule vorhanden?
ip rule show | grep 0x8001

# Route in Table?
ip route show table 201
```

**RUTOS WebUI zeigt Tunnel als aktiv nach Disable:**
- WireGuard: UCI disabled toggle prüfen: `uci get network.<TUNNEL>.disabled`
- OpenVPN: UCI enable prüfen: `uci get openvpn.<SECTION>.enable`
- Bei Diskrepanz: `uci commit && /etc/init.d/openvpn reload`

**Verwaiste iptables-Regeln nach Device Disable:**
```bash
# Alle MARK-Regeln für eine IP anzeigen
iptables -t mangle -S PREROUTING | grep "192.168.110.239"

# Falls verwaist: Device erneut enable/disable oder:
# Service-Wrapper nutzt remove_all_marks_for_ip() automatisch
```

**Nach Firmware-Update fehlen UCI-Einstellungen:**
```bash
# install.sh erneut ausführen (überschreibt Config NICHT)
cd /etc/vpn-streaming/scripts
./install.sh
```

## Test-Matrix

Getestet: 2026-01-08 (RUTX50), 2026-04-29 (RUTX09)

### Provider vs. Streaming-Dienste

| Dienst | NordVPN (OpenVPN) | ExpressVPN (OpenVPN) | Surfshark (WireGuard) |
|--------|-------------------|----------------------|-----------------------|
| **ORF** (AT) | OK | Blockiert | Blockiert |
| **SRF** (CH) | OK | Blockiert | Blockiert |
| **ARD/ZDF** (DE) | OK | OK | Blockiert |

### Provider-Details

**NordVPN (OpenVPN)** - Empfohlen
- AT: ORF 1/2/3/+/K alle funktionieren
- CH: SRF funktioniert
- DE: ARD/ZDF und alle Landessender
- **Einziger Provider der für alle drei Länder funktioniert**

**ExpressVPN (OpenVPN)**
- DE: Frankfurt Server funktioniert
- AT/CH: Blockiert
- **Nur für DE brauchbar**

**Surfshark (WireGuard)**
- Alle Länder blockiert (Datacenter-IPs erkannt)
- **Für Streaming unbrauchbar**

### Empfehlung

| Land | Empfohlener Tunnel |
|------|-------------------|
| DE | NordVPN OpenVPN |
| CH | NordVPN OpenVPN oder WireGuard zu Schweizer Heimanschluss |
| AT | NordVPN OpenVPN |

**Tipp:** Für CH ist ein WireGuard-Tunnel zu einem Schweizer Heimanschluss (Residential IP) die zuverlässigste Lösung - Streaming-Dienste blockieren keine echten Privat-IPs.

## Deinstallation

### Komplett-Cleanup mit interaktiver Bestätigung

```bash
/etc/vpn-streaming/scripts/cleanup.sh
```

### Automatisch ohne Bestätigung

```bash
# Credentials behalten:
/etc/vpn-streaming/scripts/cleanup.sh -y

# Alles löschen inkl. Credentials:
/etc/vpn-streaming/scripts/cleanup.sh -y-delete-creds
```

### Was entfernt wird

- Alle iptables MARK-Regeln (PREROUTING)
- Alle ip rules und Routing Tables
- VPN Tunnel (werden deaktiviert, nicht gelöscht)
- Named Pipes (FIFOs)
- procd Service
- uhttpd Konfiguration
- Firewall-Regel (Port 8080)
- Installationsverzeichnis `/etc/vpn-streaming/`
- sysupgrade.conf Einträge

### Was NICHT angefasst wird

- Management VPNs (WG, MGMT, HOME, VPN)
- WireGuard/OpenVPN Tunnel-Definitionen (werden nur deaktiviert)
- VPN Credentials (optional behalten)

## Versionshistorie

| Version | Änderungen |
|---------|-------------|
| v5.0.1 | Bugfixes: Auth-File Permissions (openvpn user), Error Handling bei Tunnel-Start, WebUI zeigt Fehlermeldungen, Config-Pfad aus UCI |
| v5.0 | WireGuard Support, Credentials Management, FIFO IPC, procd Service, sysupgrade-Schutz |
| v4.0 | Multi-Device Multi-Tunnel, JSON Devices, Referenzzählung, Trigger-File IPC |
| v3.0 | Device-basiertes Routing, Single-Tunnel, UCI Integration |

## Lizenz

MIT License
