// Service worker: forwards every request to the Publr wasm module and returns its response.

const passthrough = ["/index.html", "/publr-worker.js", "/publr.wasm"];
const wasi_errno_nosys = 52;
const db_file = "publr.sqlite";
const cookies_file = "publr.cookies.json";

let instance = null;
let ready = null;
// Cookie and Set-Cookie are forbidden headers inside a service worker, so the worker is the cookie jar.
let cookies = new Map();

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(Promise.all([self.clients.claim(), (ready ??= boot())])));

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  if (passthrough.includes(url.pathname)) return;
  event.respondWith(forward(event.request, url));
});

async function forward(request, url) {
  await (ready ??= boot());

  const headers = [...request.headers].map(([name, value]) => ({ name, value }));
  if (cookies.size > 0) headers.push({ name: "cookie", value: [...cookies].map(([name, value]) => `${name}=${value}`).join("; ") });
  if (request.referrer) headers.push({ name: "referer", value: request.referrer });

  const envelope = {
    method: request.method,
    path: url.pathname,
    query: url.search.slice(1),
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? "" : await request.text(),
  };

  const reply = call("publr_request", JSON.stringify(envelope));
  const response = JSON.parse(reply);

  for (const { name, value } of response.headers) if (name.toLowerCase() === "set-cookie") store_cookie(value);
  if (request.method !== "GET" && request.method !== "HEAD") await persist();

  return new Response(response.body, {
    status: response.status,
    headers: response.headers.map(({ name, value }) => [name, value]),
  });
}

async function boot() {
  const bytes = await (await fetch("/publr.wasm")).arrayBuffer();
  const wasi = new Proxy(wasi_stubs, { get: (target, name) => target[name] ?? (() => wasi_errno_nosys) });
  const result = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi });

  instance = result.instance;
  instance.exports._initialize?.();

  const code = instance.exports.publr_init();
  if (code !== 0) throw new Error("publr_init failed: " + code);

  await restore();
  console.log("publr: wasm ready");
}

function call(name, text) {
  const encoded = new TextEncoder().encode(text);
  const ptr = instance.exports.publr_alloc(encoded.length);
  new Uint8Array(instance.exports.memory.buffer, ptr, encoded.length).set(encoded);

  const code = instance.exports[name](ptr, encoded.length);
  instance.exports.publr_free(ptr, encoded.length);
  if (code !== 0) throw new Error(name + " failed: " + code);

  return new TextDecoder().decode(response_bytes());
}

function response_bytes() {
  const ptr = instance.exports.publr_response_ptr();
  const len = instance.exports.publr_response_len();
  return new Uint8Array(instance.exports.memory.buffer, ptr, len).slice();
}

function store_cookie(header) {
  const [pair, ...attributes] = header.split(";").map((part) => part.trim());
  const equals = pair.indexOf("=");
  if (equals <= 0) return;
  const name = pair.slice(0, equals);
  const expired = attributes.some((attribute) => attribute.toLowerCase() === "max-age=0");
  if (expired) cookies.delete(name);
  else cookies.set(name, pair.slice(equals + 1));
}

async function persist() {
  await write_file(cookies_file, new TextEncoder().encode(JSON.stringify([...cookies])));
  if (instance.exports.publr_export() !== 0) return;
  await write_file(db_file, response_bytes());
}

async function write_file(name, bytes) {
  const root = await navigator.storage.getDirectory();
  const handle = await root.getFileHandle(name, { create: true });
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

async function read_file(name) {
  const root = await navigator.storage.getDirectory();
  const handle = await root.getFileHandle(name).catch(() => null);
  if (!handle) return null;
  return new Uint8Array(await (await handle.getFile()).arrayBuffer());
}

async function restore() {
  const saved_cookies = await read_file(cookies_file);
  if (saved_cookies && saved_cookies.length > 0) cookies = new Map(JSON.parse(new TextDecoder().decode(saved_cookies)));
  const bytes = await read_file(db_file);
  if (!bytes || bytes.length === 0) return;
  const ptr = instance.exports.publr_alloc(bytes.length);
  new Uint8Array(instance.exports.memory.buffer, ptr, bytes.length).set(bytes);
  instance.exports.publr_import(ptr, bytes.length);
  instance.exports.publr_free(ptr, bytes.length);
}

const wasi_stubs = {
  fd_write(fd, iovs, iovs_len, nwritten) {
    const view = new DataView(instance.exports.memory.buffer);
    let total = 0, text = "";
    for (let i = 0; i < iovs_len; i++) {
      const ptr = view.getUint32(iovs + i * 8, true), len = view.getUint32(iovs + i * 8 + 4, true);
      text += new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, ptr, len));
      total += len;
    }
    view.setUint32(nwritten, total, true);
    if (text.trim()) console.log("[publr]", text.trimEnd());
    return 0;
  },
  clock_time_get(id, precision, out) {
    new DataView(instance.exports.memory.buffer).setBigUint64(out, BigInt(Date.now()) * 1000000n, true);
    return 0;
  },
  clock_res_get(id, out) {
    new DataView(instance.exports.memory.buffer).setBigUint64(out, 1000000n, true);
    return 0;
  },
  random_get(ptr, len) {
    crypto.getRandomValues(new Uint8Array(instance.exports.memory.buffer, ptr, len));
    return 0;
  },
  environ_sizes_get(count, size) {
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(count, 0, true); view.setUint32(size, 0, true);
    return 0;
  },
  environ_get: () => 0,
  args_sizes_get(count, size) {
    const view = new DataView(instance.exports.memory.buffer);
    view.setUint32(count, 0, true); view.setUint32(size, 0, true);
    return 0;
  },
  args_get: () => 0,
  fd_close: () => 0,
  fd_seek: () => wasi_errno_nosys,
  fd_read: () => wasi_errno_nosys,
  fd_fdstat_get: () => 8,
  fd_prestat_get: () => 8,
  poll_oneoff: () => wasi_errno_nosys,
  proc_exit(code) { throw new Error("proc_exit " + code); },
};
