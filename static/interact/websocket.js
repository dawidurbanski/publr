// Publr WebSocket client
// Connects to the CMS WebSocket endpoint for real-time features.
// JSON envelope: { "type": "...", "data": { ... } }

let ws = null;
let reconnectDelay = 1000;
let shouldReconnect = false;
const MAX_DELAY = 30000;
const listeners = {};

function getUrl() {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${location.host}/admin/ws`;
}

function doConnect() {
    ws = new WebSocket(getUrl());

    ws.onopen = () => {
        reconnectDelay = 1000;
        dispatch('open', null);
    };

    ws.onmessage = (event) => {
        try {
            const msg = JSON.parse(event.data);
            dispatch(msg.type, msg.data);
        } catch (e) {
            // Ignore malformed messages
        }
    };

    ws.onclose = () => {
        ws = null;
        dispatch('close', null);
        if (shouldReconnect) {
            setTimeout(doConnect, reconnectDelay);
            reconnectDelay = Math.min(reconnectDelay * 2, MAX_DELAY);
        }
    };

    ws.onerror = () => {
        // onclose fires after onerror — reconnect handled there
    };
}

function dispatch(type, data) {
    const cbs = listeners[type];
    if (cbs) cbs.forEach(cb => cb(data));
}

/** Start the WebSocket connection (with auto-reconnect). */
export function connect() {
    if (ws) return;
    shouldReconnect = true;
    doConnect();
}

/** Disconnect and stop reconnecting. */
export function disconnect() {
    shouldReconnect = false;
    if (ws) {
        ws.close();
        ws = null;
    }
}

/** Send a typed JSON message. */
export function send(type, data) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type, data }));
    }
}

/** Register a handler for a message type. */
export function on(type, callback) {
    if (!listeners[type]) listeners[type] = [];
    listeners[type].push(callback);
}

/** Remove a handler. */
export function off(type, callback) {
    if (!listeners[type]) return;
    listeners[type] = listeners[type].filter(cb => cb !== callback);
}

/** Check connection state. */
export function isConnected() {
    return ws !== null && ws.readyState === WebSocket.OPEN;
}
