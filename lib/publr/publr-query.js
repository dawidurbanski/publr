// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — built by Vite from publr-js/src/ (TypeScript).
// DO NOT EDIT. Edit publr-js/src/**, run `npm run build`, then re-vendor
// consumers via scripts/vendor-publr.sh.
// ─────────────────────────────────────────────────────────────────────────────
import { Publr } from "./publr.js";
//#region src/addons/query.ts
var [reactive, effect, runInScope, onCleanup, tagStore, , proxyCache, RAW, getActiveScope, stateInitHooks, actionsInitHooks, proxyGetHooks, proxySetHooks, deepMergeHooks] = Publr._internals;
var QUERY_TAG = Symbol("query-tag");
var QUERY_INSTANCE = Symbol("query-instance");
var QUERY_META = Symbol("query-meta");
var QUERY_BACKLINK = Symbol("query-backlink");
var MUTATION_TAG = Symbol("mutation-tag");
var currentMutationCtx = null;
var isRestoring = false;
function markBacklink(value) {
	if (!value || typeof value !== "object" || value[QUERY_BACKLINK]) return;
	try {
		Object.defineProperty(value, QUERY_BACKLINK, {
			value: true,
			configurable: true,
			enumerable: false,
			writable: true
		});
	} catch {}
}
function captureSnapshot(target, key, oldValue, newValue) {
	if (target[QUERY_BACKLINK] && newValue) markBacklink(newValue);
	if (!currentMutationCtx || isRestoring || !target[QUERY_BACKLINK]) return;
	let touched = currentMutationCtx.touched.get(target);
	if (!touched) {
		currentMutationCtx.touched.set(target, touched = /* @__PURE__ */ new Set());
		if (Array.isArray(target)) {
			touched.add("length");
			currentMutationCtx.snapshots.push({
				target,
				key: "length",
				oldValue: target.length
			});
		}
	}
	if (!touched.has(key)) {
		touched.add(key);
		currentMutationCtx.snapshots.push({
			target,
			key,
			oldValue
		});
	}
}
proxyGetHooks.push((target, value) => {
	if (target[QUERY_BACKLINK]) markBacklink(value);
});
proxySetHooks.push(captureSnapshot);
deepMergeHooks.push((targetValue, sourceValue) => {
	if (!targetValue || typeof targetValue !== "object" || !targetValue[QUERY_INSTANCE]) return false;
	setMetaSuccess(targetValue[QUERY_META], sourceValue);
	return true;
});
var QUERY_RESERVED = /* @__PURE__ */ new Set([
	"data",
	"error",
	"errorObj",
	"status",
	"loading",
	"refetch",
	"reset",
	"abort"
]);
var MUTATION_RESERVED = /* @__PURE__ */ new Set([
	"data",
	"error",
	"errorObj",
	"status",
	"loading",
	"reset"
]);
var cacheRegistry = /* @__PURE__ */ new Map();
function registerCacheEntry(entry) {
	for (const tag of entry.tags) {
		let set = cacheRegistry.get(tag);
		if (!set) cacheRegistry.set(tag, set = /* @__PURE__ */ new Set());
		set.add(entry);
	}
}
function unregisterCacheEntry(entry) {
	for (const tag of entry.tags) {
		const set = cacheRegistry.get(tag);
		if (!set) continue;
		set.delete(entry);
		if (!set.size) cacheRegistry.delete(tag);
	}
}
function setMetaSuccess(meta, data) {
	meta.data = data;
	meta.error = null;
	meta.errorObj = null;
	meta.status = "success";
}
function setMetaError(meta, err) {
	meta.error = err?.message ?? String(err);
	meta.errorObj = err;
	meta.status = "error";
}
function resetMeta(meta, fields) {
	meta.data = null;
	meta.error = null;
	meta.errorObj = null;
	meta.status = "idle";
	if (fields) Object.assign(meta, fields);
}
function callHook(hook, hookName, ...args) {
	if (typeof hook !== "function") return;
	try {
		hook(...args);
	} catch (err) {
		console.error(`Publr.mutation ${hookName} threw:`, err);
	}
}
function normalizeCacheConfig(spec, queryName) {
	if (spec.cache === void 0) return {
		tagsFn: null,
		ttl: null
	};
	if (!(spec.cache && typeof spec.cache === "object" && typeof spec.cache.tags === "function")) throw new Error(`Publr.query "${queryName || "anonymous"}": cache must be an object with a tags() function — e.g. { tags: () => ['foo'], ttl?: 60 }.`);
	const ttl = typeof spec.cache.ttl === "number" ? spec.cache.ttl : null;
	return {
		tagsFn: spec.cache.tags,
		ttl
	};
}
function createQueryInstance(spec, storeName, queryName) {
	const { tagsFn, ttl } = normalizeCacheConfig(spec, queryName);
	const metaTarget = {
		data: spec.initialData ?? null,
		error: null,
		errorObj: null,
		status: "idle"
	};
	markBacklink(metaTarget);
	if (storeName) tagStore(metaTarget, storeName, queryName);
	if (spec.initialData && typeof spec.initialData === "object") markBacklink(spec.initialData);
	const meta = reactive(metaTarget);
	const keepPreviousData = spec.keepPreviousData !== false;
	const localCache = /* @__PURE__ */ new Map();
	let token = 0;
	let controller = null;
	let debounceTimer = null;
	function computePlan() {
		const tags = tagsFn ? tagsFn() : null;
		return {
			tags,
			primary: tags?.length ? String(tags[0]) : null,
			skip: spec.skipIf?.()
		};
	}
	function cancelDebounce() {
		if (debounceTimer) {
			clearTimeout(debounceTimer);
			debounceTimer = null;
		}
	}
	function execute() {
		const { tags, primary, skip } = computePlan();
		if (primary && localCache.has(primary)) {
			const entry = localCache.get(primary);
			if (!(ttl != null && Date.now() - entry.ts >= ttl * 1e3)) {
				setMetaSuccess(meta, entry.result);
				return;
			}
			localCache.delete(primary);
			unregisterCacheEntry(entry);
		}
		if (skip) return;
		controller?.abort();
		cancelDebounce();
		controller = new AbortController();
		const { signal } = controller;
		const myToken = ++token;
		function launch() {
			debounceTimer = null;
			meta.status = "pending";
			if (!keepPreviousData) meta.data = null;
			let promise;
			try {
				promise = spec.fetch({ signal });
			} catch (err) {
				if (myToken !== token || signal.aborted) return;
				setMetaError(meta, err);
				return;
			}
			Promise.resolve(promise).then((result) => {
				if (myToken !== token) return;
				setMetaSuccess(meta, result);
				if (primary) {
					const entry = {
						localCache,
						primary,
						tags: tags.slice(),
						result,
						ts: Date.now(),
						refresh: execute
					};
					localCache.set(primary, entry);
					registerCacheEntry(entry);
				}
			}).catch((err) => {
				if (myToken !== token || signal.aborted) return;
				setMetaError(meta, err);
			});
		}
		if (spec.debounce) debounceTimer = setTimeout(launch, spec.debounce);
		else launch();
	}
	function dropLocalCache() {
		for (const entry of localCache.values()) unregisterCacheEntry(entry);
		localCache.clear();
	}
	const methods = {
		refetch: execute,
		reset() {
			token++;
			controller?.abort();
			controller = null;
			cancelDebounce();
			resetMeta(meta);
			dropLocalCache();
		},
		abort() {
			controller?.abort();
		}
	};
	const ownerScope = getActiveScope();
	let firstRun = true;
	queueMicrotask(() => {
		if (storeName && typeof document !== "undefined" && document.body) {
			const selector = `[data-p-store="${storeName}"], [data-p-store="local:${storeName}"]`;
			if (!document.querySelector(selector)) return;
		}
		runInScope(ownerScope, () => {
			effect(() => {
				computePlan();
				if (firstRun) {
					firstRun = false;
					if (metaTarget.status === "success") return;
				}
				execute();
			}, { label: `query(${queryName || "anonymous"})` });
		});
	});
	onCleanup(() => {
		methods.abort();
		dropLocalCache();
	});
	return new Proxy({}, {
		get(_target, key) {
			if (key === QUERY_INSTANCE) return true;
			if (key === QUERY_META || key === RAW) return meta;
			if (key === "loading") return meta.status === "pending";
			if (QUERY_RESERVED.has(key)) return methods[key] ?? meta[key];
			const data = meta.data;
			return data == null ? void 0 : data[key];
		},
		set(_target, key, value) {
			if (key === "data") meta.data = value;
			return true;
		},
		has(_target, key) {
			if (QUERY_RESERVED.has(key)) return true;
			return meta.data != null && key in meta.data;
		}
	});
}
function instantiateQueries(obj, storeName) {
	for (const key of Object.keys(obj)) {
		const descriptor = Object.getOwnPropertyDescriptor(obj, key);
		if (!descriptor || descriptor.get) continue;
		const value = descriptor.value;
		if (value && typeof value === "object" && value[QUERY_TAG]) obj[key] = createQueryInstance(value, storeName, key);
	}
}
function rollbackSnapshots(snapshots) {
	if (!snapshots.length) return;
	isRestoring = true;
	try {
		function apply(snapshot) {
			const proxy = proxyCache.get(snapshot.target);
			if (proxy) proxy[snapshot.key] = snapshot.oldValue;
			else snapshot.target[snapshot.key] = snapshot.oldValue;
		}
		for (const snapshot of snapshots) if (snapshot.key !== "length") apply(snapshot);
		for (const snapshot of snapshots) if (snapshot.key === "length") apply(snapshot);
	} finally {
		isRestoring = false;
	}
}
function createMutationInstance(spec, storeName, mutationName) {
	const metaTarget = {
		data: null,
		error: null,
		errorObj: null,
		status: "idle",
		pending: 0
	};
	if (storeName) tagStore(metaTarget, storeName, mutationName);
	const meta = reactive(metaTarget);
	const mode = spec.concurrent || "parallel";
	let token = 0;
	let lastController = null;
	let serialChain = Promise.resolve();
	async function runOnce(arg) {
		const controller = new AbortController();
		if (mode === "latest") lastController?.abort();
		lastController = controller;
		const myToken = ++token;
		meta.pending++;
		meta.status = "pending";
		const ctx = {
			snapshots: [],
			touched: /* @__PURE__ */ new WeakMap()
		};
		const prevCtx = currentMutationCtx;
		currentMutationCtx = ctx;
		let promise;
		try {
			promise = spec.fetch(arg, { signal: controller.signal });
		} finally {
			currentMutationCtx = prevCtx;
		}
		const isStale = () => mode === "latest" && myToken !== token;
		try {
			const result = await promise;
			if (isStale()) return;
			setMetaSuccess(meta, result);
			callHook(spec.onSuccess, "onSuccess", result, arg);
		} catch (err) {
			if (isStale() || controller.signal.aborted) return;
			rollbackSnapshots(ctx.snapshots);
			setMetaError(meta, err);
			callHook(spec.onError, "onError", err, arg);
		} finally {
			meta.pending--;
			if (!meta.pending && meta.status === "pending") meta.status = "idle";
		}
	}
	function invoke(arg) {
		if (mode === "serial") {
			serialChain = serialChain.then(() => runOnce(arg)).catch(() => {});
			return serialChain;
		}
		return runOnce(arg);
	}
	const methods = { reset() {
		token++;
		lastController?.abort();
		lastController = null;
		resetMeta(meta, { pending: 0 });
	} };
	onCleanup(() => lastController?.abort());
	return new Proxy(function publrMutation() {}, {
		apply(_target, _thisArg, args) {
			return invoke(args[0]);
		},
		get(_target, key) {
			if (key === RAW) return meta;
			if (key === "loading") return meta.pending > 0;
			if (MUTATION_RESERVED.has(key)) return methods[key] ?? meta[key];
			return Reflect.get(_target, key);
		},
		has(_target, key) {
			return MUTATION_RESERVED.has(key);
		}
	});
}
function instantiateMutations(actions, storeName) {
	for (const key of Object.keys(actions)) {
		const value = actions[key];
		if (value && typeof value === "object" && value[MUTATION_TAG]) actions[key] = createMutationInstance(value, storeName, key);
	}
}
stateInitHooks.push(instantiateQueries);
actionsInitHooks.push(instantiateMutations);
/** Async data dependency in `state` — swapped for a live query proxy at registration. */
Publr.query = function query(spec) {
	return {
		[QUERY_TAG]: true,
		...spec
	};
};
/** Async write in `actions` — swapped for a callable proxy at registration. */
Publr.mutation = function mutation(spec) {
	return {
		[MUTATION_TAG]: true,
		...spec
	};
};
/** Tag-based cache invalidation (EXACT match). `{ refetch: true }` re-fires live subscribers. */
Publr.revalidate = function revalidate(tagOrTags, opts) {
	const tags = Array.isArray(tagOrTags) ? tagOrTags : [tagOrTags];
	const eager = !!opts?.refetch;
	const toDrop = /* @__PURE__ */ new Set();
	for (const tag of tags) {
		const set = cacheRegistry.get(tag);
		if (set) for (const entry of set) toDrop.add(entry);
	}
	const refreshes = [];
	for (const entry of toDrop) {
		entry.localCache.delete(entry.primary);
		unregisterCacheEntry(entry);
		if (eager && entry.refresh) refreshes.push(entry.refresh);
	}
	if (eager) for (const fn of refreshes) fn();
};
//#endregion
export { Publr };
