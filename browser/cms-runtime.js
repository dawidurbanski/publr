// CMS Runtime - Thin wrapper around worker

let worker = null;
let reqId = 0;
const pending = new Map();

function call(method, ...args) {
    return new Promise((resolve, reject) => {
        const id = ++reqId;
        pending.set(id, { resolve, reject });
        worker.postMessage({ id, method, args });
    });
}

export async function initCMS(wasmUrl = '/cms.wasm') {
    worker = new Worker(new URL('./cms-worker.js', import.meta.url), { type: 'module' });
    worker.onmessage = ({ data: { id, success, result, error } }) => {
        const p = pending.get(id);
        if (p) {
            pending.delete(id);
            success ? p.resolve(result) : p.reject(new Error(error));
        }
    };

    await call('init', wasmUrl);

    // Restore session from localStorage
    const token = localStorage.getItem('cms_session');
    if (token) await call('setSession', token);

    return {
        async request(method, path, body = '') {
            const res = await call('request', method, path, body);

            // Handle redirect with token (path|token)
            if (res.redirect?.includes('|')) {
                const [rpath, token] = res.redirect.split('|');
                localStorage.setItem('cms_session', token);
                await call('setSession', token);
                res.redirect = rpath;
            }

            return res;
        },

        async save() {
            return await call('save');
        },

        clearSession() {
            localStorage.removeItem('cms_session');
            call('setSession', null);
        }
    };
}
