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

// Field soft locks (keyed by field name)
const fieldLocks = new Map();
let focusedField = null;
let focusDebounceTimer = null;
const FOCUS_DEBOUNCE_MS = 75;

// Field edit broadcasting (debounced per field)
const editDebounceTimers = {};
const EDIT_DEBOUNCE_MS = 300;

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
    on('field_focused', handleFieldFocused);
    on('field_blurred', handleFieldBlurred);
    on('field_lock_invalidated', handleFieldLockInvalidated);
    on('field_edit', handleFieldEdit);
    on('open', handleWsOpen);

    // Field focus/blur tracking (use focusin/focusout for event delegation)
    form.addEventListener('focusin', onFieldFocus);
    form.addEventListener('focusout', onFieldBlur);

    // Field edit broadcasting (debounced oninput)
    form.addEventListener('input', onFieldInput);

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

    // Apply field locks from sync (skip our own focused field)
    clearAllFieldLocks();
    if (data.locks) {
        for (const [field, lock] of Object.entries(data.locks)) {
            if (field === focusedField) continue;
            fieldLocks.set(field, lock);
            applyFieldLock(field, lock);
        }
    }

    // Re-acquire our focus if we had one (idempotent on server)
    if (focusedField) {
        send('focus', { field: focusedField });
    }
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

function handleFieldFocused(data) {
    if (!data || !data.field) return;
    fieldLocks.set(data.field, data);
    applyFieldLock(data.field, data);
}

function handleFieldBlurred(data) {
    if (!data || !data.field) return;
    fieldLocks.delete(data.field);
    removeFieldLock(data.field);
}

function handleFieldLockInvalidated(data) {
    if (!data || !data.field) return;

    // If we hold the lock, release it client-side
    if (focusedField === data.field) {
        focusedField = null;
        const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
        if (group && group.contains(document.activeElement)) {
            document.activeElement.blur();
        }
    }

    fieldLocks.set(data.field, data);
    applyFieldLock(data.field, data);
}

function handleFieldEdit(data) {
    if (!data || !data.field || data.value === undefined) return;

    const group = document.querySelector('.form-group[data-field="' + data.field + '"]');
    if (!group) return;

    const input = group.querySelector('.form-control');
    if (input) {
        input.value = data.value;
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
// Field focus/blur — soft lock events
// =========================================================================

function onFieldFocus(e) {
    const group = e.target.closest('.form-group[data-field]');
    if (!group) return;
    const field = group.dataset.field;
    if (field === focusedField) return;

    clearTimeout(focusDebounceTimer);
    focusDebounceTimer = setTimeout(() => {
        focusedField = field;
        send('focus', { field });
    }, FOCUS_DEBOUNCE_MS);
}

function onFieldBlur(e) {
    const group = e.target.closest('.form-group[data-field]');
    if (!group) return;
    const field = group.dataset.field;
    if (field !== focusedField) return;

    clearTimeout(focusDebounceTimer);
    focusedField = null;
    send('blur', { field });
}

function onFieldInput(e) {
    if (!e.target.classList.contains('form-control')) return;
    const group = e.target.closest('.form-group[data-field]');
    if (!group) return;
    const field = group.dataset.field;
    if (field !== focusedField) return;

    clearTimeout(editDebounceTimers[field]);
    editDebounceTimers[field] = setTimeout(() => {
        send('field_edit', { field, value: e.target.value });
    }, EDIT_DEBOUNCE_MS);
}

// =========================================================================
// Field lock UI — disable fields + show indicator
// =========================================================================

function applyFieldLock(field, lockData) {
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (!group) return;

    group.classList.add('field-soft-locked');

    // Disable all inputs in the group
    group.querySelectorAll('input, textarea, select').forEach(el => {
        el.disabled = true;
        el.dataset.softLocked = 'true';
    });

    // Add or update soft lock indicator
    let indicator = group.querySelector('.field-soft-lock-indicator');
    if (!indicator) {
        indicator = document.createElement('span');
        indicator.className = 'field-soft-lock-indicator';
        const checkRow = group.querySelector('.field-check-row');
        if (checkRow) {
            checkRow.prepend(indicator);
        }
    }

    const name = escapeAttr(lockData.name || '');
    const url = escapeAttr(lockData.avatar_url || '');
    indicator.innerHTML = '<img src="' + url + '" class="field-editor-avatar" alt="" />'
        + name + ' is editing';
}

function removeFieldLock(field) {
    const group = document.querySelector('.form-group[data-field="' + field + '"]');
    if (!group) return;

    group.classList.remove('field-soft-locked');

    // Re-enable inputs
    group.querySelectorAll('[data-soft-locked="true"]').forEach(el => {
        el.disabled = false;
        delete el.dataset.softLocked;
    });

    // Remove indicator
    const indicator = group.querySelector('.field-soft-lock-indicator');
    if (indicator) indicator.remove();
}

function clearAllFieldLocks() {
    for (const field of fieldLocks.keys()) {
        removeFieldLock(field);
    }
    fieldLocks.clear();
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
    clearTimeout(focusDebounceTimer);

    off('presence_sync', handlePresenceSync);
    off('user_joined', handleUserJoined);
    off('user_left', handleUserLeft);
    off('user_activity', handleUserActivity);
    off('field_focused', handleFieldFocused);
    off('field_blurred', handleFieldBlurred);
    off('field_lock_invalidated', handleFieldLockInvalidated);
    off('field_edit', handleFieldEdit);
    off('open', handleWsOpen);

    const form = document.getElementById('post-form');
    if (form) {
        form.removeEventListener('focusin', onFieldFocus);
        form.removeEventListener('focusout', onFieldBlur);
        form.removeEventListener('input', onFieldInput);
    }

    for (const key of Object.keys(editDebounceTimers)) {
        clearTimeout(editDebounceTimers[key]);
        delete editDebounceTimers[key];
    }

    const events = ['mousemove', 'keydown', 'touchstart', 'scroll'];
    for (const evt of events) {
        document.removeEventListener(evt, onUserInput);
    }

    clearAllFieldLocks();
    users.clear();
    focusedField = null;
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
