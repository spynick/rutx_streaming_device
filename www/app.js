/**
 * VPN Streaming WebUI v5.0
 * Multi-Device Multi-Tunnel Support
 */

// =============================================================================
// CONFIGURATION
// =============================================================================

const API_BASE = (window.location.port === '8080')
    ? '/api/vpn-streaming'
    : 'http://' + window.location.hostname + ':8080/api/vpn-streaming';

let currentStatus = null;
let availableTunnels = [];
let refreshInterval = null;

// =============================================================================
// API CALLS
// =============================================================================

async function api(endpoint, method = 'GET', data = null) {
    const options = {
        method,
        headers: { 'Content-Type': 'application/json' }
    };

    if (data && method !== 'GET') {
        options.body = JSON.stringify(data);
    }

    try {
        const response = await fetch(`${API_BASE}${endpoint}`, options);
        const json = await response.json();

        if (!json.success) {
            throw new Error(json.error || 'Unknown error');
        }

        return json;
    } catch (error) {
        console.error('API Error:', error);
        showToast(error.message, 'error');
        throw error;
    }
}

// =============================================================================
// STATUS & REFRESH
// =============================================================================

async function refreshStatus() {
    try {
        const result = await api('/status');
        currentStatus = result.data;
        updateUI();
    } catch (error) {
        console.error('Status refresh failed:', error);
    }
}

async function loadTunnels() {
    try {
        const result = await api('/tunnels');
        availableTunnels = result.tunnels || [];
        updateTunnelDropdowns();
        updateAvailableTunnels();
    } catch (error) {
        console.error('Failed to load tunnels:', error);
    }
}

function startAutoRefresh() {
    if (refreshInterval) clearInterval(refreshInterval);
    refreshInterval = setInterval(refreshStatus, 5000);
}

function stopAutoRefresh() {
    if (refreshInterval) {
        clearInterval(refreshInterval);
        refreshInterval = null;
    }
}

// =============================================================================
// UI UPDATE
// =============================================================================

function updateUI() {
    if (!currentStatus) return;

    updateStatusIndicator();
    updateDevicesGrid();
    updateActiveTunnels();
}

function updateStatusIndicator() {
    const indicator = document.getElementById('status-indicator');
    const text = document.getElementById('status-text');

    const devices = currentStatus.devices?.devices || [];
    const activeTunnels = currentStatus.tunnels?.active_count || 0;

    if (activeTunnels > 0) {
        indicator.className = 'status-indicator connected';
        text.textContent = `${activeTunnels} Tunnel aktiv`;
    } else {
        indicator.className = 'status-indicator disconnected';
        text.textContent = 'Getrennt';
    }
}

function updateDevicesGrid() {
    const container = document.getElementById('devices-container');
    const devices = currentStatus.devices?.devices || [];

    if (devices.length === 0) {
        container.innerHTML = `
            <div class="device-card placeholder">
                <p>Keine Devices konfiguriert</p>
                <button class="btn" onclick="showAddDeviceModal()">Device hinzufügen</button>
            </div>
        `;
        return;
    }

    container.innerHTML = [...devices].sort((a, b) => (a.name || a.ip).localeCompare(b.name || b.ip)).map(device => {
        const tunnelInfo = getTunnelInfo(device.tunnel);
        const isActive = device.active;
        const statusClass = isActive ? 'active' : 'inactive';

        return `
            <div class="device-card ${statusClass}" data-ip="${device.ip}">
                <div class="device-header">
                    <span class="device-name">${device.name || device.ip}</span>
                    <button class="btn-icon" onclick="showEditDeviceModal('${device.ip}')" title="Bearbeiten">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/>
                            <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>
                        </svg>
                    </button>
                </div>
                <div class="device-ip">${device.ip}</div>
                <div class="device-tunnel">
                    ${tunnelInfo ? `
                        <span class="tunnel-flag">${tunnelInfo.flag}</span>
                        <span class="tunnel-name">${tunnelInfo.location}</span>
                    ` : '<span class="no-tunnel">Kein Tunnel</span>'}
                </div>
                <div class="device-footer">
                    <div class="device-status">
                        <span class="status-dot ${statusClass}"></span>
                        <span>${isActive ? 'Aktiv' : 'Inaktiv'}</span>
                    </div>
                    <label class="toggle small">
                        <input type="checkbox" ${isActive ? 'checked' : ''}
                               onchange="toggleDevice('${device.ip}', this.checked)"
                               ${!device.tunnel ? 'disabled' : ''}>
                        <span class="slider"></span>
                    </label>
                </div>
            </div>
        `;
    }).join('');
}

function updateActiveTunnels() {
    const container = document.getElementById('tunnels-container');
    const countBadge = document.getElementById('tunnel-count');

    // Wir müssen die aktiven Tunnel aus den Devices ableiten
    // da die API /tunnels/active noch nicht implementiert ist
    const devices = currentStatus.devices?.devices || [];
    const activeTunnels = {};

    devices.forEach(device => {
        if (device.active && device.tunnel) {
            if (!activeTunnels[device.tunnel]) {
                activeTunnels[device.tunnel] = [];
            }
            activeTunnels[device.tunnel].push(device.name || device.ip);
        }
    });

    const tunnelCount = Object.keys(activeTunnels).length;
    countBadge.textContent = tunnelCount;

    if (tunnelCount === 0) {
        container.innerHTML = '<div class="info">Keine aktiven Tunnel</div>';
        return;
    }

    container.innerHTML = Object.entries(activeTunnels).map(([tunnel, users]) => {
        const tunnelInfo = getTunnelInfo(tunnel);
        return `
            <div class="tunnel-item active">
                <div class="tunnel-info">
                    <span class="tunnel-flag">${tunnelInfo?.flag || '?'}</span>
                    <span class="tunnel-name">${tunnelInfo?.location || tunnel}</span>
                    <span class="tunnel-provider">${tunnelInfo?.provider || ''}</span>
                </div>
                <div class="tunnel-users">
                    <span class="user-count">${users.length}</span> Device${users.length > 1 ? 's' : ''}
                </div>
            </div>
        `;
    }).join('');
}

function updateAvailableTunnels() {
    const container = document.getElementById('available-tunnels');
    const countBadge = document.getElementById('available-tunnel-count');

    countBadge.textContent = availableTunnels.length;

    if (availableTunnels.length === 0) {
        container.innerHTML = '<div class="info">Keine Tunnel verfügbar</div>';
        return;
    }

    container.innerHTML = availableTunnels.map(tunnel => {
        const info = getTunnelInfo(tunnel.name);
        return `
            <div class="tunnel-card">
                <span class="tunnel-flag">${info?.flag || '?'}</span>
                <span class="tunnel-location">${info?.location || tunnel.name}</span>
                <span class="tunnel-provider">${tunnel.provider || ''}</span>
            </div>
        `;
    }).join('');
}

function updateTunnelDropdowns() {
    const dropdowns = ['new-device-tunnel', 'edit-device-tunnel'];

    dropdowns.forEach(id => {
        const select = document.getElementById(id);
        if (!select) return;

        const currentValue = select.value;
        select.innerHTML = '<option value="">-- Tunnel wählen --</option>';

        availableTunnels.forEach(tunnel => {
            const info = getTunnelInfo(tunnel.name);
            const opt = document.createElement('option');
            opt.value = tunnel.name;
            opt.textContent = `${info?.flag || ''} ${info?.location || tunnel.name} (${tunnel.provider || 'OpenVPN'})`;
            select.appendChild(opt);
        });

        if (currentValue) select.value = currentValue;
    });
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

function getTunnelInfo(tunnelName) {
    if (!tunnelName) return null;

    // Parse tunnel name: "DE_Frankfurt_NordVPN" -> {country: "DE", location: "DE Frankfurt", provider: "NordVPN"}
    const parts = tunnelName.split('_');
    const country = parts[0]?.toUpperCase();
    const provider = parts[parts.length - 1]?.includes('VPN') ? parts.pop() : '';
    const location = parts.join(' ');

    const flags = {
        'DE': '\uD83C\uDDE9\uD83C\uDDEA',
        'CH': '\uD83C\uDDE8\uD83C\uDDED',
        'AT': '\uD83C\uDDE6\uD83C\uDDF9',
        'US': '\uD83C\uDDFA\uD83C\uDDF8',
        'UK': '\uD83C\uDDEC\uD83C\uDDE7',
        'NL': '\uD83C\uDDF3\uD83C\uDDF1'
    };

    return {
        country,
        location,
        provider,
        flag: flags[country] || country
    };
}

// =============================================================================
// DEVICE ACTIONS
// =============================================================================

async function toggleDevice(ip, enabled) {
    stopAutoRefresh();

    try {
        if (enabled) {
            await api(`/devices/${ip}/enable`, 'POST');
            showToast('Device aktiviert', 'success');
        } else {
            await api(`/devices/${ip}/disable`, 'POST');
            showToast('Device deaktiviert', 'success');
        }

        await new Promise(r => setTimeout(r, 2000));
        await refreshStatus();
    } catch (error) {
        showToast(error.message || 'Aktion fehlgeschlagen', 'error');
    } finally {
        startAutoRefresh();
    }
}

async function enableAllDevices() {
    stopAutoRefresh();

    try {
        await api('/enable-all', 'POST');
        showToast('Alle Devices aktiviert', 'success');
        await new Promise(r => setTimeout(r, 3000));
        await refreshStatus();
    } catch (error) {
        showToast(error.message || 'Aktion fehlgeschlagen', 'error');
    } finally {
        startAutoRefresh();
    }
}

async function disableAllDevices() {
    stopAutoRefresh();

    try {
        await api('/disable-all', 'POST');
        showToast('Alle Devices deaktiviert', 'success');
        await new Promise(r => setTimeout(r, 2000));
        await refreshStatus();
    } catch (error) {
        showToast(error.message || 'Aktion fehlgeschlagen', 'error');
    } finally {
        startAutoRefresh();
    }
}

async function addDevice() {
    const ip = document.getElementById('new-device-ip').value.trim();
    const name = document.getElementById('new-device-name').value.trim();
    const tunnel = document.getElementById('new-device-tunnel').value;

    if (!ip) {
        showToast('IP-Adresse erforderlich', 'error');
        return;
    }

    if (!/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(ip)) {
        showToast('Ungültige IP-Adresse', 'error');
        return;
    }

    try {
        await api('/devices', 'POST', {
            ip,
            name: name || `Device_${ip}`,
            tunnel,
        });

        showToast('Device hinzugefügt', 'success');
        closeModal('add-device-modal');
        await refreshStatus();

        // Form zurücksetzen
        document.getElementById('new-device-ip').value = '';
        document.getElementById('new-device-name').value = '';
        document.getElementById('new-device-tunnel').value = '';
    } catch (error) {
        showToast('Fehler beim Hinzufügen', 'error');
    }
}

function showAddDeviceModal() {
    updateTunnelDropdowns();
    document.getElementById('add-device-modal').classList.remove('hidden');
}

function showEditDeviceModal(ip) {
    const devices = currentStatus.devices?.devices || [];
    const device = devices.find(d => d.ip === ip);

    if (!device) {
        showToast('Device nicht gefunden', 'error');
        return;
    }

    updateTunnelDropdowns();

    document.getElementById('edit-device-ip').value = device.ip;
    document.getElementById('edit-device-name').value = device.name || '';
    document.getElementById('edit-device-tunnel').value = device.tunnel || '';

    document.getElementById('edit-device-modal').classList.remove('hidden');
}

async function saveDevice() {
    const ip = document.getElementById('edit-device-ip').value;
    const name = document.getElementById('edit-device-name').value.trim();
    const tunnel = document.getElementById('edit-device-tunnel').value;

    try {
        // Update device by adding with same IP (overwrites)
        await api('/devices', 'POST', {
            ip,
            name,
            tunnel,
        });

        showToast('Device gespeichert', 'success');
        closeModal('edit-device-modal');
        await refreshStatus();
    } catch (error) {
        showToast('Fehler beim Speichern', 'error');
    }
}

async function deleteDevice() {
    const ip = document.getElementById('edit-device-ip').value;

    showConfirm(
        'Device löschen',
        `Device "${ip}" wirklich löschen?`,
        async () => {
            try {
                await api(`/devices/${ip}`, 'DELETE');
                showToast('Device gelöscht', 'success');
                closeModal('edit-device-modal');
                await refreshStatus();
            } catch (error) {
                showToast('Fehler beim Löschen', 'error');
            }
        }
    );
}

// =============================================================================
// CREDENTIALS MANAGEMENT
// =============================================================================

async function showCredentialsModal() {
    document.getElementById('credentials-modal').classList.remove('hidden');
    document.getElementById('credentials-container').innerHTML = '<div class="info">Lade Provider...</div>';

    try {
        const result = await api('/credentials');
        const creds = result.credentials || [];

        if (creds.length === 0) {
            document.getElementById('credentials-container').innerHTML =
                '<div class="info">Keine OpenVPN-Profile mit Passwort-Authentifizierung gefunden.</div>';
            return;
        }

        document.getElementById('credentials-container').innerHTML = creds.map(cred => {
            const statusClass = cred.has_credentials ? 'cred-set' : 'cred-missing';
            const statusText = cred.has_credentials ? 'Gesetzt' : 'Nicht gesetzt';
            const userValue = cred.username || '';

            return `
                <div class="credential-provider" data-auth-file="${cred.auth_file}">
                    <div class="credential-header">
                        <span class="credential-name">${cred.provider}</span>
                        <span class="credential-info">${cred.profile_count} Profil${cred.profile_count !== 1 ? 'e' : ''}</span>
                        <span class="credential-status ${statusClass}">${statusText}</span>
                    </div>
                    <div class="form-group">
                        <label>Benutzername / Token:</label>
                        <input type="text" class="cred-username" value="${userValue}"
                               placeholder="Username oder Service-Token">
                    </div>
                    <div class="form-group">
                        <label>Passwort:</label>
                        <input type="password" class="cred-password"
                               placeholder="${cred.has_credentials ? '(unver\u00e4ndert lassen = beibehalten)' : 'Passwort eingeben'}">
                    </div>
                    <button class="btn btn-primary btn-small" onclick="saveCredentials(this)">Speichern</button>
                </div>
            `;
        }).join('');
    } catch (error) {
        document.getElementById('credentials-container').innerHTML =
            '<div class="info error">Fehler beim Laden der Provider.</div>';
    }
}

async function saveCredentials(btn) {
    const container = btn.closest('.credential-provider');
    const authFile = container.dataset.authFile;
    const username = container.querySelector('.cred-username').value.trim();
    const password = container.querySelector('.cred-password').value;

    if (!username) {
        showToast('Benutzername erforderlich', 'error');
        return;
    }

    if (!password) {
        showToast('Passwort erforderlich', 'error');
        return;
    }

    btn.disabled = true;
    btn.textContent = 'Speichern...';

    try {
        await api('/credentials', 'POST', {
            auth_file: authFile,
            username: username,
            password: password
        });

        showToast('Zugangsdaten gespeichert', 'success');

        // Status aktualisieren
        const status = container.querySelector('.credential-status');
        status.className = 'credential-status cred-set';
        status.textContent = 'Gesetzt';

        // Passwort-Feld leeren
        container.querySelector('.cred-password').value = '';
        container.querySelector('.cred-password').placeholder = '(unver\u00e4ndert lassen = beibehalten)';
    } catch (error) {
        showToast('Fehler beim Speichern', 'error');
    } finally {
        btn.disabled = false;
        btn.textContent = 'Speichern';
    }
}

// =============================================================================
// UI HELPERS
// =============================================================================

function toggleSection(header) {
    const card = header.closest('.card');
    card.classList.toggle('collapsed');
}

function closeModal(id) {
    document.getElementById(id).classList.add('hidden');
}

function showConfirm(title, message, onConfirm) {
    document.getElementById('confirm-title').textContent = title;
    document.getElementById('confirm-message').textContent = message;

    const btn = document.getElementById('confirm-btn');
    btn.onclick = () => {
        onConfirm();
        closeModal('confirm-modal');
    };

    document.getElementById('confirm-modal').classList.remove('hidden');
}

function showToast(message, type = 'info') {
    const toast = document.getElementById('toast');
    toast.textContent = message;
    toast.className = `toast ${type}`;
    toast.offsetHeight; // Force reflow
    setTimeout(() => toast.classList.add('hidden'), 3000);
}

// =============================================================================
// INITIALIZATION
// =============================================================================

document.addEventListener('DOMContentLoaded', () => {
    refreshStatus();
    loadTunnels();
    startAutoRefresh();

    // Close modals on overlay click
    document.querySelectorAll('.modal-overlay').forEach(overlay => {
        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) {
                overlay.classList.add('hidden');
            }
        });
    });

    // Visibility change handling
    document.addEventListener('visibilitychange', () => {
        if (document.hidden) {
            stopAutoRefresh();
        } else {
            refreshStatus();
            startAutoRefresh();
        }
    });
});
