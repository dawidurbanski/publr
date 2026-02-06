// CMS Web Worker - Runs WASM with OPFS persistence
// Simple interface: just call request(method, path, body)

let wasmInstance = null;
const DB_FILENAME = 'cms.sqlite';

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

// =============================================================================
// Operations
// =============================================================================

const ops = {
    async init(wasmUrl) {
        const { instance } = await WebAssembly.instantiate(
            await (await fetch(wasmUrl)).arrayBuffer(),
            { wasi_snapshot_preview1: wasiStubs }
        );
        wasmInstance = instance;
        wasmInstance.exports._start?.();

        // Try restore from OPFS
        const saved = await loadFromOPFS();
        if (saved?.byteLength > 0) {
            const ptr = wasmInstance.exports.wasm_alloc(saved.length);
            if (ptr) {
                new Uint8Array(wasmInstance.exports.memory.buffer).set(saved, ptr);
                if (wasmInstance.exports.cms_import_db(ptr, saved.length) === 0) {
                    wasmInstance.exports.wasm_free(ptr, saved.length);
                    console.log('[Worker] Restored from OPFS');
                    return { success: true, restored: true };
                }
                wasmInstance.exports.wasm_free(ptr, saved.length);
            }
        }

        // Fresh init
        if (wasmInstance.exports.cms_init() !== 0) throw new Error('Init failed');
        console.log('[Worker] Fresh database');
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

console.log('[Worker] Ready');
