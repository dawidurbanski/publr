// CMS Web Worker - Runs WASM with OPFS persistence
// Simple interface: just call request(method, path, body)

let wasmInstance = null;
let wasmBytes = null;
const DB_FILENAME = 'cms.sqlite';

// =============================================================================
// Sync transport (cr-sqlite changeset relay over WebSocket)
// =============================================================================
// When the user has configured a Relay URL + sync token in the cr-sqlite
// admin page (stored in localStorage, forwarded to init() by
// cms-runtime.js), the worker opens a WebSocket to `<URL>/admin/ws/sync`
// with `?sync_token=<token>`. cr-sqlite emits a JSON array on every
// saveEntry via the `env.js_sync_send` import; we wrap it in a
// `sync_changes` envelope and forward to the relay, which rebroadcasts
// to every other connected replica. Inbound `sync_changes` frames are
// pushed back into WASM via `cms_apply_remote_changeset`.
//
// Without configured URL + token we don't open a socket at all — the
// local CMS still works, save_hooks just have nowhere to publish to.

let syncWs = null;
let syncWsReady = false;
let syncWsUrl = null;
let syncToken = null;
let opfsSaveTimer = null;

function connectSyncWs() {
    if (syncWs) return;
    // Sync is strictly opt-in: only connect when both URL and token are
    // present. A replica without these is a standalone WASM CMS — no
    // peers, no relay, save_hooks just fire into js_sync_send's no-op.
    if (!syncWsUrl || !syncToken) return;

    let url = syncWsUrl;
    // Token-auth endpoint lives at `/admin/ws/sync`. If the user-
    // configured URL points at `/admin/ws` (the cookie-auth endpoint),
    // auto-correct it — that's the cross-origin path and `/admin/ws`
    // doesn't accept tokens.
    try {
        const u = new URL(url);
        if (u.pathname === '/admin/ws') {
            u.pathname = '/admin/ws/sync';
            url = u.toString();
        }
    } catch (_) { /* relative URL or junk — leave it alone */ }
    const sep = url.includes('?') ? '&' : '?';
    url += `${sep}sync_token=${encodeURIComponent(syncToken)}`;

    try {
        syncWs = new WebSocket(url);
    } catch (e) {
        console.warn('[Worker] WS create failed:', e);
        syncWs = null;
        setTimeout(connectSyncWs, 3000);
        return;
    }
    syncWs.addEventListener('open', () => {
        syncWsReady = true;
        console.log('[Worker] Sync WS connected');
        // Emit this replica's full state so the relay (and any other
        // connected replicas) catch up on whatever was saved locally
        // while we were offline, or was restored from OPFS without
        // firing any save_hook. cr-sqlite dedupes echoes on peers.
        if (wasmInstance && wasmInstance.exports.cms_sync_emit_full) {
            wasmInstance.exports.cms_sync_emit_full();
        }
    });
    syncWs.addEventListener('message', (event) => {
        console.log('[Worker] WS message:', event.data.length, 'bytes');
        try {
            const msg = JSON.parse(event.data);
            console.log('[Worker] WS message type:', msg.type, 'data len:', typeof msg.data === 'string' ? msg.data.length : '(not a string)');
            if (msg.type === 'sync_changes' && typeof msg.data === 'string') {
                applyRemoteChangeset(msg.data);
            }
        } catch (e) {
            console.warn('[Worker] WS message parse failed:', e);
        }
    });
    syncWs.addEventListener('close', () => {
        syncWsReady = false;
        syncWs = null;
        setTimeout(connectSyncWs, 3000);
    });
    syncWs.addEventListener('error', () => {
        // close handler does the reconnect
    });
}

function applyRemoteChangeset(jsonString) {
    if (!wasmInstance || !wasmInstance.exports.cms_apply_remote_changeset) {
        console.warn('[Worker] cms_apply_remote_changeset not available');
        return;
    }
    const b = writeString(jsonString);
    const rc = wasmInstance.exports.cms_apply_remote_changeset(b.ptr, b.len);
    if (b.len > 0) wasmInstance.exports.wasm_free(b.ptr, b.len);
    console.log('[Worker] applied', jsonString.length, 'bytes, rc=', rc);
    if (rc !== 0) console.warn('[Worker] cms_apply_remote_changeset failed:', rc);
    scheduleOpfsSave();
}

function scheduleOpfsSave() {
    if (opfsSaveTimer) clearTimeout(opfsSaveTimer);
    opfsSaveTimer = setTimeout(() => {
        opfsSaveTimer = null;
        ops.save?.();
    }, 250);
}

// =============================================================================
// OPFS
// =============================================================================

async function loadFromOPFS() {
    try {
        const root = await navigator.storage.getDirectory();
        const file = await (await root.getFileHandle(DB_FILENAME)).getFile();
        return new Uint8Array(await file.arrayBuffer());
    } catch (e) {
        if (e.name !== 'NotFoundError') console.error('[Worker] OPFS load error:', e);
        return null;
    }
}

async function saveToOPFS(data) {
    try {
        const root = await navigator.storage.getDirectory();
        const handle = await root.getFileHandle(DB_FILENAME, { create: true });
        const access = await handle.createSyncAccessHandle();
        access.truncate(0);
        access.write(data, { at: 0 });
        access.flush();
        access.close();
        return true;
    } catch (e) {
        console.error('[Worker] OPFS save error:', e);
        return false;
    }
}

// =============================================================================
// WASM Helpers
// =============================================================================

function writeString(str) {
    const encoded = new TextEncoder().encode(str || '');
    if (encoded.length === 0) return { ptr: 0, len: 0 };
    const ptr = wasmInstance.exports.wasm_alloc(encoded.length);
    if (!ptr) throw new Error('Alloc failed');
    new Uint8Array(wasmInstance.exports.memory.buffer).set(encoded, ptr);
    return { ptr, len: encoded.length };
}

function readResult() {
    const ptr = wasmInstance.exports.wasm_get_result_ptr();
    const len = wasmInstance.exports.wasm_get_result_len();
    return new TextDecoder().decode(new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len));
}

function readRedirect() {
    const ptr = wasmInstance.exports.wasm_get_redirect_ptr();
    const len = wasmInstance.exports.wasm_get_redirect_len();
    if (len === 0) return null;
    return new TextDecoder().decode(new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len));
}

function writeBytes(bytes) {
    if (!bytes || bytes.length === 0) return { ptr: 0, len: 0 };
    const ptr = wasmInstance.exports.wasm_alloc(bytes.length);
    if (!ptr) throw new Error('Alloc failed');
    new Uint8Array(wasmInstance.exports.memory.buffer).set(bytes, ptr);
    return { ptr, len: bytes.length };
}

function readContentType() {
    const ptr = wasmInstance.exports.wasm_get_content_type_ptr();
    const len = wasmInstance.exports.wasm_get_content_type_len();
    if (len === 0) return null;
    return new TextDecoder().decode(new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len));
}

function readResultBinary() {
    const ptr = wasmInstance.exports.wasm_get_result_ptr();
    const len = wasmInstance.exports.wasm_get_result_len();
    return new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len).slice();
}

// =============================================================================
// WASI Stubs
// =============================================================================

const wasiStubs = {
    proc_exit: () => {}, sched_yield: () => 0,
    fd_write: (fd, iovs, iovsLen, nwritten) => {
        const mem = new DataView(wasmInstance.exports.memory.buffer);
        let total = 0;
        for (let i = 0; i < iovsLen; i++) {
            const ptr = mem.getUint32(iovs + i * 8, true);
            const len = mem.getUint32(iovs + i * 8 + 4, true);
            if (fd === 1 || fd === 2) console.log('[WASM]', new TextDecoder().decode(new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len)));
            total += len;
        }
        mem.setUint32(nwritten, total, true);
        return 0;
    },
    fd_read: () => 0, fd_close: () => 0, fd_seek: () => 0, fd_sync: () => 0, fd_tell: () => 0,
    fd_prestat_get: () => 8, fd_prestat_dir_name: () => 8, fd_fdstat_get: () => 0,
    fd_fdstat_set_flags: () => 0, fd_filestat_get: () => 0, fd_filestat_set_size: () => 0,
    fd_filestat_set_times: () => 0, fd_pread: () => 0, fd_pwrite: () => 0, fd_readdir: () => 0,
    fd_renumber: () => 0, fd_allocate: () => 0, fd_advise: () => 0, fd_datasync: () => 0,
    path_open: () => 44, path_create_directory: () => 0, path_remove_directory: () => 0,
    path_readlink: () => 0, path_rename: () => 0, path_filestat_get: () => 0,
    path_filestat_set_times: () => 0, path_link: () => 0, path_symlink: () => 0,
    path_unlink_file: () => 0,
    environ_sizes_get: (c, b) => { const v = new DataView(wasmInstance.exports.memory.buffer); v.setUint32(c, 0, true); v.setUint32(b, 0, true); return 0; },
    environ_get: () => 0,
    args_sizes_get: (c, b) => { const v = new DataView(wasmInstance.exports.memory.buffer); v.setUint32(c, 0, true); v.setUint32(b, 0, true); return 0; },
    args_get: () => 0,
    clock_time_get: (_, __, ptr) => { new DataView(wasmInstance.exports.memory.buffer).setBigUint64(ptr, BigInt(Date.now()) * 1000000n, true); return 0; },
    clock_res_get: () => 0,
    random_get: (ptr, len) => { const mem = new Uint8Array(wasmInstance.exports.memory.buffer); const rand = new Uint8Array(len); crypto.getRandomValues(rand); mem.set(rand, ptr); return 0; },
    sock_accept: () => 0, sock_recv: () => 0, sock_send: () => 0, sock_shutdown: () => 0, poll_oneoff: () => 0,
};

// `env` namespace — WASM-side imports for the cr-sqlite sync transport.
const envImports = {
    js_sync_send: (ptr, len) => {
        if (!syncWsReady || !syncWs) return;
        if (!len) return;
        const mem = new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len);
        const payload = new TextDecoder().decode(mem);
        try {
            syncWs.send(JSON.stringify({ type: 'sync_changes', data: payload }));
        } catch (e) {
            console.warn('[Worker] WS send failed:', e);
        }
    },
};

// =============================================================================
// Operations
// =============================================================================

const ops = {
    async init(wasmUrl, configuredSyncWsUrl, configuredSyncToken) {
        syncWsUrl = (configuredSyncWsUrl && configuredSyncWsUrl.length > 0) ? configuredSyncWsUrl : null;
        syncToken = (configuredSyncToken && configuredSyncToken.length > 0) ? configuredSyncToken : null;
        wasmBytes = await (await fetch(wasmUrl)).arrayBuffer();
        const { instance } = await WebAssembly.instantiate(
            wasmBytes,
            { wasi_snapshot_preview1: wasiStubs, env: envImports }
        );
        wasmInstance = instance;
        wasmInstance.exports._start?.();

        // Try to restore from OPFS
        const saved = await loadFromOPFS();
        if (saved && saved.length > 0) {
            if (wasmInstance.exports.cms_init() !== 0) throw new Error('Init failed');
            const b = writeBytes(saved);
            const imported = wasmInstance.exports.cms_import_db(b.ptr, b.len);
            if (b.len > 0) wasmInstance.exports.wasm_free(b.ptr, b.len);
            if (imported === 0) {
                console.log('[Worker] Restored from OPFS (' + saved.length + ' bytes)');
                connectSyncWs();
                return { success: true, restored: true };
            }
            console.warn('[Worker] OPFS restore failed, starting fresh');
        }

        if (wasmInstance.exports.cms_init() !== 0) throw new Error('Init failed');
        console.log('[Worker] Fresh database');
        connectSyncWs();
        return { success: true, restored: false };
    },

    setSession(token) {
        if (token && token.length > 0) {
            const t = writeString(token);
            wasmInstance.exports.cms_set_session(t.ptr, t.len);
            if (t.len > 0) wasmInstance.exports.wasm_free(t.ptr, t.len);
        } else {
            wasmInstance.exports.cms_set_session(0, 0);
        }
    },

    request(method, path, body = '') {
        const m = writeString(method);
        const p = writeString(path);
        const b = writeString(body);

        wasmInstance.exports.cms_request(m.ptr, m.len, p.ptr, p.len, b.ptr, b.len);

        if (m.len > 0) wasmInstance.exports.wasm_free(m.ptr, m.len);
        if (p.len > 0) wasmInstance.exports.wasm_free(p.ptr, p.len);
        if (b.len > 0) wasmInstance.exports.wasm_free(b.ptr, b.len);

        const status = wasmInstance.exports.wasm_get_status();
        const redirect = readRedirect();
        const body_out = readResult();

        return { status, redirect, body: body_out };
    },

    requestBinary(method, path, bodyBytes, contentType) {
        const m = writeString(method);
        const p = writeString(path);
        const b = writeBytes(bodyBytes);

        // Set Content-Type header before request
        const ctName = writeString('Content-Type');
        const ctVal = writeString(contentType);
        wasmInstance.exports.cms_set_request_header(ctName.ptr, ctName.len, ctVal.ptr, ctVal.len);
        if (ctName.len > 0) wasmInstance.exports.wasm_free(ctName.ptr, ctName.len);
        if (ctVal.len > 0) wasmInstance.exports.wasm_free(ctVal.ptr, ctVal.len);

        wasmInstance.exports.cms_request(m.ptr, m.len, p.ptr, p.len, b.ptr, b.len);

        if (m.len > 0) wasmInstance.exports.wasm_free(m.ptr, m.len);
        if (p.len > 0) wasmInstance.exports.wasm_free(p.ptr, p.len);
        if (b.len > 0) wasmInstance.exports.wasm_free(b.ptr, b.len);

        const status = wasmInstance.exports.wasm_get_status();
        const redirect = readRedirect();
        const body_out = readResult();

        return { status, redirect, body: body_out };
    },

    getMedia(path) {
        const m = writeString('GET');
        const p = writeString('/media/' + path);
        const b = writeString('');

        wasmInstance.exports.cms_request(m.ptr, m.len, p.ptr, p.len, b.ptr, b.len);

        if (m.len > 0) wasmInstance.exports.wasm_free(m.ptr, m.len);
        if (p.len > 0) wasmInstance.exports.wasm_free(p.ptr, p.len);

        const contentType = readContentType();
        const data = readResultBinary();

        return { data, contentType };
    },

    async reset() {
        // Delete OPFS file
        try {
            const root = await navigator.storage.getDirectory();
            await root.removeEntry(DB_FILENAME);
            console.log('[Worker] OPFS file deleted');
        } catch (e) {
            console.log('[Worker] OPFS delete:', e.message);
        }
        // Re-instantiate WASM completely (bypasses cms_init guard)
        const { instance } = await WebAssembly.instantiate(
            wasmBytes,
            { wasi_snapshot_preview1: wasiStubs, env: envImports }
        );
        wasmInstance = instance;
        wasmInstance.exports._start?.();
        if (wasmInstance.exports.cms_init() !== 0) throw new Error('Init failed');
        console.log('[Worker] Database fully reset');
        return true;
    },

    async save() {
        if (wasmInstance.exports.cms_export_db() !== 0) return false;
        const ptr = wasmInstance.exports.wasm_get_result_ptr();
        const len = wasmInstance.exports.wasm_get_result_len();
        if (!ptr || len === 0) return false;
        const data = new Uint8Array(wasmInstance.exports.memory.buffer).slice(ptr, ptr + len);
        return await saveToOPFS(data);
    },
};

// =============================================================================
// Message Handler
// =============================================================================

self.onmessage = async ({ data: { id, method, args } }) => {
    try {
        const result = await ops[method]?.(...(args || []));
        self.postMessage({ id, success: true, result });
    } catch (e) {
        self.postMessage({ id, success: false, error: e.message });
    }
};

console.log('[Worker] Ready v3 — OPFS enabled');
