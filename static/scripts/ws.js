// WebSocket transport — ONE shared, ref-counted connection to /admin/ws
// (PublrJS-era replacement for interact/websocket.js; #159).
//
// Consumers are PublrJS stores: call acquire(handlers) in setup() and
// handle.release() in the teardown — the socket's lifetime is governed by
// store lifecycle, ref-counted across consumers. It connects on the first
// acquire and closes on the last release, after a short linger so a
// teardown→setup pair (SPA navigation, HMR swap) reuses the SAME socket —
// which is what keeps the old page's unsubscribe ordered before the new
// page's subscribe.
//
// Safety rails the legacy module lacked:
//   * every socket callback is guarded by a connection GENERATION — events
//     from a superseded socket (late close after a force-reconnect, messages
//     racing a teardown) are dropped instead of clobbering current state;
//   * all timers (reconnect backoff, linger close) are tracked and cancelled
//     when the last consumer releases — nothing keeps firing after teardown;
//   * released handles go inert: their handlers never fire again and their
//     send() is a no-op (stale messages after navigation are dangerous).
//
// Connection status is pushed into the shared reactive `ws` store so any
// island can bind to it (e.g. :showIf="$connected" on an offline banner).
//
// JSON envelope: { "type": "...", "data": { ... } }.

import { Publr } from '/static/scripts/publr.js';

// Shared singleton status store — reactive, page-wide.
const status = Publr.store('ws', {
    state: { connected: false },
    actions: {},
});

const MAX_DELAY = 30000;
const CLOSE_LINGER_MS = 250;

let ws = null;
let gen = 0; // bumped on every connect/close decision — stale callbacks bail
let reconnectDelay = 1000;
let reconnectTimer = null;
let closeTimer = null;

// Live handles: unique per-acquire token → handlers object, so two acquires
// sharing one handlers object stay independently releasable. Insertion order
// = notify order.
const subscribers = new Map();

function getUrl() {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${location.host}/admin/ws`;
}

function notify(kind, type, data) {
    subscribers.forEach((handlers) => {
        const fn = handlers[kind];
        if (!fn) return;
        try {
            if (kind === 'message') fn(type, data);
            else fn();
        } catch (e) {
            console.error('ws: subscriber handler failed', e);
        }
    });
}

function clearTimers() {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    clearTimeout(closeTimer);
    closeTimer = null;
}

function doConnect() {
    // No native WS server when the admin runs inside the WASM dev shell
    // (browser/index.html); `window.cms` is the runtime surface set by
    // cms-runtime.js. Presence is a native-server feature — stay silent
    // instead of spamming reconnect failures.
    if (typeof window !== 'undefined' && window.cms) return;
    if (ws) return;

    const g = ++gen;
    const socket = new WebSocket(getUrl());
    ws = socket;

    socket.onopen = () => {
        if (g !== gen) return;
        reconnectDelay = 1000;
        status.state.connected = true;
        notify('open');
    };

    socket.onmessage = (event) => {
        if (g !== gen) return;
        let msg = null;
        try {
            msg = JSON.parse(event.data);
        } catch (e) {
            return; // ignore malformed messages
        }
        if (msg && msg.type) notify('message', msg.type, msg.data);
    };

    socket.onclose = () => {
        if (g !== gen) return; // a superseded socket's close — already handled
        gen++;
        ws = null;
        status.state.connected = false;
        notify('close');
        // Reconnect only while someone still holds a handle.
        if (subscribers.size > 0) {
            reconnectTimer = setTimeout(() => {
                reconnectTimer = null;
                if (subscribers.size > 0) doConnect();
            }, reconnectDelay);
            reconnectDelay = Math.min(reconnectDelay * 2, MAX_DELAY);
        }
    };

    socket.onerror = () => {
        // onclose fires after onerror — reconnect handled there
    };
}

function closeSocket() {
    gen++; // anything in flight on this socket is now stale
    clearTimers();
    status.state.connected = false;
    if (ws) {
        const socket = ws;
        ws = null;
        try { socket.close(); } catch (e) {}
    }
}

function sendRaw(type, data) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type, data }));
    }
}

/**
 * Take a ref-counted handle on the shared connection.
 *
 * handlers: { open?(), close?(), message?(type, data) } — open fires on every
 * (re)connect (resubscribe there), close on every disconnect.
 *
 * Returns { send(type, data), isConnected(), release() }. Call release() in
 * the owning store's teardown: handlers stop firing immediately and the
 * socket closes shortly after the LAST handle is released.
 */
export function acquire(handlers) {
    const token = Symbol('ws-handle');
    subscribers.set(token, handlers || {});

    // A pending linger-close belongs to a consumer set that no longer
    // matters — this handle wants the connection alive.
    clearTimeout(closeTimer);
    closeTimer = null;

    if (!ws && !reconnectTimer) doConnect();

    let released = false;
    return {
        send: (type, data) => {
            if (!released) sendRaw(type, data);
        },
        isConnected: () => !released && ws !== null && ws.readyState === WebSocket.OPEN,
        release: () => {
            if (released) return;
            released = true;
            subscribers.delete(token);
            if (subscribers.size === 0) {
                // Linger: a navigation/HMR teardown is usually followed by a
                // new acquire within the same tick or frame — keep the socket
                // so unsubscribe→resubscribe ride the same connection, in
                // order. Nobody came back? Close for real.
                clearTimers();
                closeTimer = setTimeout(() => {
                    closeTimer = null;
                    if (subscribers.size === 0) closeSocket();
                }, CLOSE_LINGER_MS);
            }
        },
    };
}
