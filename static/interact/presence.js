// Publr Presence — real-time user presence on entry edit pages.
// Shows who else is viewing/editing the same entry.
// Depends on websocket.js for connection management.

import { send, on, off, connect, isConnected } from './websocket.js';

let currentEntryId = null;
let presenceContainer = null;
let activityTimer = null;
let heartbeatTimer = null;
let lastInputTime = Date.now();
let isActive = true;

const INACTIVE_THRESHOLD = 60000; // 60s
const HEARTBEAT_INTERVAL = 10000; // 10s
const ACTIVITY_CHECK_INTERVAL = 10000; // 10s

// Current users on this entry (keyed by user_id)
const users = new Map();

// =========================================================================
// Init — called on edit pages
// =========================================================================

export function initPresence() {
    const form = document.getElementById('post-form');
    if (!form) return;

    const entryId = form.dataset.entryId;
    if (!entryId) return;

    presenceContainer = document.getElementById('presence-users');
    if (!presenceContainer) return;

    currentEntryId = entryId;

    // Register WS message handlers
    on('presence_sync', handlePresenceSync);
    on('user_joined', handleUserJoined);
    on('user_left', handleUserLeft);
    on('user_activity', handleUserActivity);
    on('open', handleWsOpen);

    // Connect WS (idempotent if already connected)
    connect();

    // If already connected, subscribe immediately
    if (isConnected()) {
        sendSubscribe();
    }

    // Start activity detection
    startActivityDetection();

    // Start heartbeat
    heartbeatTimer = setInterval(sendHeartbeat, HEARTBEAT_INTERVAL);

    // Clean up on page unload
    window.addEventListener('beforeunload', cleanup);
}

// =========================================================================
// WS event handlers
// =========================================================================

function handleWsOpen() {
    if (currentEntryId) {
        sendSubscribe();
    }
}

function handlePresenceSync(data) {
    if (!data || !data.users) return;
    users.clear();
    for (const user of data.users) {
        users.set(user.user_id, user);
    }
    renderPresence();
}

function handleUserJoined(data) {
    if (!data || !data.user_id) return;
    users.set(data.user_id, data);
    renderPresence();
}

function handleUserLeft(data) {
    if (!data || !data.user_id) return;
    users.delete(data.user_id);
    renderPresence();
}

function handleUserActivity(data) {
    if (!data || !data.user_id) return;
    const user = users.get(data.user_id);
    if (user) {
        user.active = data.active;
        renderPresence();
    }
}

// =========================================================================
// Sending
// =========================================================================

function sendSubscribe() {
    send('subscribe', { entry_id: currentEntryId });
}

function sendHeartbeat() {
    send('heartbeat');
}

// =========================================================================
// Activity detection
// =========================================================================

function startActivityDetection() {
    const events = ['mousemove', 'keydown', 'touchstart', 'scroll'];
    for (const evt of events) {
        document.addEventListener(evt, onUserInput, { passive: true });
    }

    activityTimer = setInterval(checkActivity, ACTIVITY_CHECK_INTERVAL);
}

function onUserInput() {
    lastInputTime = Date.now();
    if (!isActive) {
        isActive = true;
        send('activity', { active: true });
    }
}

function checkActivity() {
    if (isActive && (Date.now() - lastInputTime > INACTIVE_THRESHOLD)) {
        isActive = false;
        send('activity', { active: false });
    }
}

// =========================================================================
// Rendering — stacked avatars in .edit-nav
// =========================================================================

function renderPresence() {
    if (!presenceContainer) return;

    // Filter out current user (server includes them in sync)
    // We show all OTHER users; current user sees themselves in the top-bar avatar
    const others = [];
    for (const user of users.values()) {
        others.push(user);
    }

    if (others.length === 0) {
        presenceContainer.innerHTML = '';
        return;
    }

    const maxShow = 5;
    const shown = others.slice(0, maxShow);
    const overflow = others.length - maxShow;

    let html = '';
    for (const user of shown) {
        const inactiveClass = user.active === false ? ' presence-inactive' : '';
        const name = escapeAttr(user.name || '');
        const url = escapeAttr(user.avatar_url || '');
        html += '<img src="' + url + '" alt="" title="' + name + '"' +
            ' class="version-avatar version-avatar-stacked' + inactiveClass + '" />';
    }

    if (overflow > 0) {
        html += '<span class="version-avatar version-avatar-overflow">+' + overflow + '</span>';
    }

    presenceContainer.innerHTML = html;
}

function escapeAttr(s) {
    return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}

// =========================================================================
// Cleanup
// =========================================================================

function cleanup() {
    if (currentEntryId) {
        send('unsubscribe', { entry_id: currentEntryId });
    }

    if (activityTimer) clearInterval(activityTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);

    off('presence_sync', handlePresenceSync);
    off('user_joined', handleUserJoined);
    off('user_left', handleUserLeft);
    off('user_activity', handleUserActivity);
    off('open', handleWsOpen);

    const events = ['mousemove', 'keydown', 'touchstart', 'scroll'];
    for (const evt of events) {
        document.removeEventListener(evt, onUserInput);
    }

    users.clear();
    currentEntryId = null;
}

// =========================================================================
// Auto-init on DOM ready
// =========================================================================

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initPresence);
} else {
    initPresence();
}
