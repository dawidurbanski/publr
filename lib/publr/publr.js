// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — built by Vite from publr-js/src/ (TypeScript).
// DO NOT EDIT. Edit publr-js/src/**, run `npm run build`, then re-vendor
// consumers via scripts/vendor-publr.sh.
// ─────────────────────────────────────────────────────────────────────────────
//#region src/core/symbols.ts
/** Proxy escape hatch: `proxy[RAW]` returns the underlying target. */
var RAW = Symbol();
/** Stamped on store state objects: [store, path] for subscriber routing. */
var STORE_TAG = Symbol();
var getStoreTag = (target) => target && typeof target === "object" ? target[STORE_TAG] : void 0;
/** `tag`'s path extended by one key — the dotted path of `key` under the tag. */
var tagPath = (tag, key) => tag[1] ? tag[1] + "." + String(key) : String(key);
var tagStore = (target, storeName, path) => {
	if (!target || typeof target !== "object" || target[STORE_TAG]) return;
	try {
		Object.defineProperty(target, STORE_TAG, {
			value: [storeName, path],
			configurable: true
		});
	} catch {}
};
//#endregion
//#region src/core/reactivity.ts
var MAX_FLUSH_DEPTH = 100;
var activeEffect = null;
var activeScope = null;
var flushScheduled = false;
var flushDepth = 0;
var targetDeps = /* @__PURE__ */ new WeakMap();
var pendingEffects = /* @__PURE__ */ new Set();
var changeNotifier = null;
var setChangeNotifier = (fn) => {
	changeNotifier = fn;
};
var track = (target, key) => {
	if (!activeEffect) return;
	let keyMap = targetDeps.get(target);
	if (!keyMap) targetDeps.set(target, keyMap = /* @__PURE__ */ new Map());
	let dep = keyMap.get(key);
	if (!dep) keyMap.set(key, dep = /* @__PURE__ */ new Set());
	dep.add(activeEffect);
	activeEffect.d.push(dep);
};
var trigger = (target, key, oldValue, newValue) => {
	if (activeEffect?.g) throw new Error(`Computed getter '${activeEffect.g}' must be pure`);
	const dep = targetDeps.get(target)?.get(key);
	if (dep) {
		for (const record of dep) pendingEffects.add(record);
		if (!flushScheduled) {
			flushScheduled = true;
			queueMicrotask(flush);
		}
	}
	changeNotifier?.(target, key, oldValue, newValue);
};
var flush = () => {
	try {
		while (pendingEffects.size) {
			if (++flushDepth > MAX_FLUSH_DEPTH) {
				const offenders = [...pendingEffects].slice(-3).map((record) => record.l || "?").join(", ");
				pendingEffects.clear();
				throw new Error(`Infinite update loop: ${offenders}`);
			}
			const batch = [...pendingEffects];
			pendingEffects.clear();
			for (const record of batch) record.s?.();
			for (const record of batch) if (!record.s) record.r();
		}
	} finally {
		flushScheduled = false;
		flushDepth = 0;
	}
};
/** Detach `record` from every dep set it is registered in. */
var clearDeps = (record) => {
	for (const dep of record.d) dep.delete(record);
	record.d.length = 0;
};
/**
* Run `fn` and re-run it whenever a reactive value it read changes (microtask-batched).
* Returns a runner that re-runs inline and returns the last value.
* `opts`: `lazy` (skip initial), `scheduler` (replaces `run()` when queued), `label` (cycle errors).
*/
var effect = (fn, opts) => {
	let lastValue;
	const record = {
		d: [],
		x: false,
		l: opts?.label ?? null,
		s: opts?.scheduler ?? null,
		g: null,
		r() {
			if (record.x) return lastValue;
			clearDeps(record);
			const prev = activeEffect;
			activeEffect = record;
			try {
				lastValue = fn();
			} finally {
				activeEffect = prev;
			}
			return lastValue;
		}
	};
	activeScope?.e.push(record);
	if (!opts?.lazy) record.r();
	const runner = record.r;
	runner._e = record;
	return runner;
};
var createScope = () => ({
	e: [],
	c: []
});
var runInScope = (scope, fn) => {
	const prev = activeScope;
	activeScope = scope;
	try {
		return fn();
	} finally {
		activeScope = prev;
	}
};
var disposeScope = (scope) => {
	for (const record of scope.e) {
		clearDeps(record);
		record.x = true;
	}
	for (const cleanup of scope.c) cleanup();
	scope.e.length = 0;
	scope.c.length = 0;
};
var onCleanup = (fn) => {
	activeScope?.c.push(fn);
};
var getActiveScope = () => activeScope;
/** Run `fn` with no effect tracking. Writes still trigger normally. */
var untrack = (fn) => {
	const prev = activeEffect;
	activeEffect = null;
	try {
		return fn();
	} finally {
		activeEffect = prev;
	}
};
//#endregion
//#region src/core/hooks.ts
var stateInitHooks = [];
var actionsInitHooks = [];
var proxyGetHooks = [];
var proxySetHooks = [];
var deepMergeHooks = [];
/** Run every hook in `hooks` with (a, b) — the shared init-hook shape. */
var runHooks = (hooks, a, b) => {
	for (const hook of hooks) hook(a, b);
};
//#endregion
//#region src/core/util.ts
/** el.getAttribute(name) */
var ga = (el, name) => el.getAttribute(name);
/** typeof v === "function" */
var isFn = (v) => typeof v === "function";
/** typeof v === "object" (null is an object here — pair with a truthiness check) */
var isObj = (v) => typeof v === "object";
/** null/undefined → "", anything else → String(v) */
var str = (v) => v == null ? "" : String(v);
/** Write `str(v)` to `el[key]` only when it actually changed. */
var setIfChanged = (el, key, v) => {
	const next = str(v);
	if (el[key] !== next) el[key] = next;
};
/** addEventListener + scope-cleaned removeEventListener. */
var listen = (target, name, fn, opts) => {
	target.addEventListener(name, fn, opts);
	onCleanup(() => target.removeEventListener(name, fn, opts));
};
//#endregion
//#region src/core/reactive.ts
var proxyCache = /* @__PURE__ */ new WeakMap();
/** Keys on a target that are memoized computed getters (for `isComputed`). */
var computedKeys = /* @__PURE__ */ new WeakMap();
var isPlainReactiveCandidate = (obj) => {
	if (Array.isArray(obj)) return true;
	const proto = Object.getPrototypeOf(obj);
	return proto === Object.prototype || proto === null;
};
var memoizeGetter = (target, key, originalGetter) => {
	let cached;
	const runner = effect(() => originalGetter.call(target), {
		lazy: true,
		label: key,
		scheduler() {
			const next = runner();
			if (next !== cached) {
				const prev = cached;
				cached = next;
				trigger(target, key, prev, next);
			}
		}
	});
	runner._e.g = key;
	cached = runner();
	let keys = computedKeys.get(target);
	if (!keys) computedKeys.set(target, keys = /* @__PURE__ */ new Set());
	keys.add(key);
	Object.defineProperty(target, key, {
		get() {
			track(target, key);
			return cached;
		},
		enumerable: true,
		configurable: true
	});
};
var deferGetterMemoization = (target) => {
	for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(target))) if (descriptor.get && !descriptor.set && descriptor.configurable) {
		const originalGetter = descriptor.get;
		queueMicrotask(() => memoizeGetter(target, key, originalGetter));
	}
};
/**
* Wrap a plain object/array in a deep reactive Proxy. Nested values wrap lazily on access.
* DOM nodes, Files, Maps, Sets, Dates, etc. pass through unwrapped.
*/
var reactive = (obj) => {
	if (obj === null || !isObj(obj) || obj[RAW] || !isPlainReactiveCandidate(obj)) return obj;
	runHooks(stateInitHooks, obj);
	const cached = proxyCache.get(obj);
	if (cached) return cached;
	deferGetterMemoization(obj);
	const proxy = new Proxy(obj, {
		get(target, key, receiver) {
			if (key === RAW) return target;
			track(target, key);
			const value = Reflect.get(target, key, receiver);
			if (value && isObj(value)) {
				if (target[STORE_TAG] && !value[STORE_TAG] && isPlainReactiveCandidate(value)) {
					const parent = getStoreTag(target);
					tagStore(value, parent[0], tagPath(parent, key));
				}
				for (const hook of proxyGetHooks) hook(target, value);
			}
			return reactive(value);
		},
		set(target, key, value, receiver) {
			const oldValue = target[key];
			const oldLength = Array.isArray(target) ? target.length : -1;
			for (const hook of proxySetHooks) hook(target, key, oldValue, value);
			const ok = Reflect.set(target, key, value, receiver);
			if (oldValue !== value) trigger(target, key, oldValue, value);
			if (oldLength !== -1 && key !== "length" && target.length !== oldLength) trigger(target, "length", oldLength, target.length);
			return ok;
		}
	});
	proxyCache.set(obj, proxy);
	return proxy;
};
/** A reactive proxy's underlying target (identity for non-proxies). */
var unwrap = (state) => state?.[RAW] ?? state;
//#endregion
//#region src/core/subscribe.ts
var globalSubscribers = /* @__PURE__ */ new Set();
setChangeNotifier((target, key, oldValue, newValue) => {
	const tag = globalSubscribers.size ? getStoreTag(target) : void 0;
	if (!tag) return;
	const path = tagPath(tag, key);
	const change = {
		store: tag[0],
		path,
		oldValue,
		newValue,
		isComputed: !!computedKeys.get(target)?.has(key),
		source: target
	};
	for (const [matches, fn] of [...globalSubscribers]) if (matches(tag[0], path)) fn(change);
});
function subscribe(...args) {
	const [selector, fn] = args;
	let entry;
	if (isFn(selector)) entry = [() => true, selector];
	else if (typeof selector !== "string" || !isFn(fn)) throw new Error("expected (fn) or (selector, fn)");
	else {
		const dotIndex = selector.indexOf(".");
		const store = dotIndex < 0 ? selector : selector.slice(0, dotIndex);
		const prefix = dotIndex < 0 ? null : selector.slice(dotIndex + 1);
		entry = [(s, path) => s === store && (prefix == null || path === prefix || path.startsWith(prefix + ".")), fn];
	}
	globalSubscribers.add(entry);
	return () => globalSubscribers.delete(entry);
}
//#endregion
//#region src/core/parse.ts
/**
* Evaluate `value <op> literal` for a predicate spec's `[ref, op, literal]`
* parts. Callers guard `parts.length >= 3`; unknown ops evaluate to false,
* eq/ne compare stringified, lt/gt/ge/le compare numerically (NaN → false).
*/
var evaluatePredicate = (value, parts) => {
	const op = parts[1];
	const literal = parts[2];
	const n = Number(value);
	const m = +literal;
	return op === "eq" ? String(value) === literal : op === "ne" ? String(value) !== literal : op === "lt" ? n < m : op === "gt" ? n > m : op === "ge" ? n >= m : op === "le" && n <= m;
};
var stripStatePrefix = (path) => path.replace(/^\$|^state\./, "");
var resolvePath = (root, path) => path.trim().split(".").reduce((obj, key) => obj?.[key], root);
var parseBindings = (value, separator) => {
	const bindings = [];
	if (value) for (const part of value.split(";")) {
		const index = part.indexOf(separator);
		if (index < 0) continue;
		const lhs = part.slice(0, index).trim();
		const rhs = part.slice(index + separator.length).trim();
		if (lhs && rhs) bindings.push([lhs, rhs]);
	}
	return bindings;
};
var parsePredicateSpec = (spec) => {
	const parts = spec.split("|");
	const negate = parts[0].startsWith("not:");
	if (negate) parts[0] = parts[0].slice(4);
	return [parts, negate];
};
var splitOutsideQuotes = (s, delim) => {
	let quote = null;
	for (let i = 0; i < s.length; i++) {
		const ch = s[i];
		if (quote) {
			if (ch === quote) quote = null;
			continue;
		}
		if (ch === "'" || ch === "\"") {
			quote = ch;
			continue;
		}
		if (s.startsWith(delim, i)) return [s.slice(0, i), s.slice(i + delim.length)];
	}
	return [s, null];
};
var unquoteLiteral = (s) => {
	const m = /^\s*(['"])([^]*)\1\s*$/.exec(s);
	return m && m[2];
};
//#endregion
//#region src/core/store.ts
var LOCAL_PREFIX = "local:";
var STORE_ATTR = "data-p-store";
var sharedStores = /* @__PURE__ */ new Map();
var localFactories = /* @__PURE__ */ new Map();
var deepMerge = (target, source) => {
	outer: for (const key in source) {
		const sourceValue = source[key];
		const targetValue = target[key];
		for (const hook of deepMergeHooks) if (hook(targetValue, sourceValue)) continue outer;
		if (sourceValue && isObj(sourceValue) && !Array.isArray(sourceValue) && targetValue && isObj(targetValue)) {
			deepMerge(targetValue, sourceValue);
			continue;
		}
		const descriptor = Object.getOwnPropertyDescriptor(target, key);
		if (!descriptor || descriptor.writable || descriptor.set) target[key] = sourceValue;
	}
};
/** Deep-merge a JSON payload into (the raw target of) `state`. Bad JSON is a no-op. */
var applyInlineSeed = (state, jsonText) => {
	if (jsonText) try {
		deepMerge(unwrap(state), JSON.parse(jsonText));
	} catch {}
};
var wireWatchBlock = (state, watchSpec, el) => {
	const storeName = getStoreTag(unwrap(state))?.[0];
	for (const rawKey of Object.keys(watchSpec)) {
		const handler = watchSpec[rawKey];
		if (!isFn(handler)) continue;
		if (rawKey === "*" || rawKey.startsWith("*:")) {
			if (!storeName) continue;
			const filter = rawKey === "*" ? null : rawKey.slice(2);
			onCleanup(subscribe(storeName, (change) => {
				if (filter === "static" && change.isComputed) return;
				if (filter === "computed" && !change.isComputed) return;
				handler(change.newValue, change.oldValue, {
					path: change.path,
					el
				});
			}));
			continue;
		}
		for (const path of rawKey.split(",").map((p) => p.trim()).filter(Boolean)) {
			let oldValue;
			let primed = false;
			effect(() => {
				const value = resolvePath(state, path);
				if (!primed) {
					oldValue = value;
					primed = true;
					return;
				}
				if (oldValue !== value) handler(value, oldValue, {
					path,
					el
				});
				oldValue = value;
			}, { label: path });
		}
	}
};
/** Repackage a user-facing instance/definition into the internal StoreRef tuple. */
var toRef = (instance) => [
	instance.state || {},
	instance.actions || {},
	instance.watch,
	instance.setup
];
/** Register a store. Plain definition = SHARED singleton; function = LOCAL factory per island. */
var store = (name, definition) => {
	if (isFn(definition)) {
		if (name) localFactories.set(name, definition);
		return;
	}
	const [stateTarget, actions] = toRef(definition);
	if (name) tagStore(stateTarget, name, "");
	runHooks(stateInitHooks, stateTarget, name);
	runHooks(actionsInitHooks, actions, name);
	if (name && typeof document !== "undefined") applyInlineSeed(stateTarget, document.getElementById("publr-state-" + name)?.textContent);
	const state = reactive(stateTarget);
	if (name) sharedStores.set(name, [state, actions]);
	if (definition.watch) {
		const watch = definition.watch;
		queueMicrotask(() => wireWatchBlock(state, watch, null));
	}
	return {
		state,
		actions
	};
};
//#endregion
//#region src/core/resolve.ts
/** The bag (state or actions) whose top-level key owns `path`, or null. */
var bagFor = ([state, actions], path) => {
	const top = path.split(".")[0];
	return state && top in state ? state : actions && top in actions ? actions : null;
};
/**
* Walk the store chain upward from `el` (following portal back-links so
* portaled content resolves through its AUTHORED position — same law as React
* portals) and return [owning store, bare path]. Falls back to a shared store
* named by the whole ref, then to the innermost store.
*/
var resolveRef = (ref, el) => {
	const bare = stripStatePrefix(ref);
	let first = null;
	let node = el;
	while (node?.getAttribute) {
		const name = ga(node, STORE_ATTR);
		if (name) {
			const store = name.startsWith("local:") ? node._ps : sharedStores.get(name);
			if (store) {
				first ??= store;
				if (bagFor(store, bare) || store[1] && bare in store[1]) return [store, bare];
			}
		}
		const portalParent = node._pp?.[0];
		node = portalParent instanceof Element ? portalParent : node.parentElement;
	}
	if (!bare.includes(".")) {
		const store = sharedStores.get(bare);
		if (store) return [store, bare];
	}
	return [first, bare];
};
var resolveValuePath = (store, rawPath) => {
	const path = stripStatePrefix(rawPath);
	const bag = bagFor(store, path);
	return bag ? resolvePath(bag, path) : void 0;
};
var bindRef = (el, ref, callback) => {
	const [store, rest] = resolveRef(ref, el);
	if (store) effect(() => callback(store, rest));
};
/**
* The shared pipeline behind -show / -class / -bind / -if and conditional
* literal payloads: parse `not:` / `ref|op|literal`, resolve the ref against
* its owning store, and re-run `apply` with the (possibly negated) value on
* every change. Plain refs pass their RAW value through (predicates and
* negation produce booleans).
*/
var bindPredicate = (el, spec, apply) => {
	const [parts, negate] = parsePredicateSpec(spec);
	bindRef(el, parts[0], (store, rest) => {
		const raw = resolveValuePath(store, rest);
		const value = parts.length >= 3 ? evaluatePredicate(raw, parts) : raw;
		apply(negate ? !value : value);
	});
};
//#endregion
//#region src/core/model-paths.ts
var writePathOnState = (state, path, value) => {
	const segments = path.split(".");
	const tail = segments.pop();
	let target = state;
	for (const segment of segments) target = target?.[segment];
	if (target != null) target[tail] = value;
};
//#endregion
//#region src/core/directives.ts
var KEY_MODIFIERS = {
	enter: "Enter",
	space: " ",
	esc: "Escape",
	escape: "Escape",
	tab: "Tab",
	up: "ArrowUp",
	down: "ArrowDown",
	left: "ArrowLeft",
	right: "ArrowRight",
	delete: "Delete"
};
var wireOn = (el, attr) => {
	for (const [descriptor, actionRef] of parseBindings(ga(el, attr), ":")) {
		const [store, rest] = resolveRef(actionRef, el);
		if (!store) continue;
		const [state, actions] = store;
		const [eventName, ...modifiers] = descriptor.split(".");
		const target = modifiers.includes("window") ? window : modifiers.includes("document") ? document : el;
		const keyFilters = modifiers.filter((m) => m in KEY_MODIFIERS).map((m) => KEY_MODIFIERS[m]);
		listen(target, eventName, (event) => {
			if (keyFilters.length && !keyFilters.includes(event.key)) return;
			if (modifiers.includes("prevent")) event.preventDefault();
			if (modifiers.includes("stop")) event.stopPropagation();
			const action = actions[rest];
			if (action) {
				action({ ...el.dataset }, {
					el,
					event
				});
				return;
			}
			let fn = resolvePath(actions, rest);
			if (!isFn(fn)) fn = resolvePath(state, rest);
			if (isFn(fn)) fn();
		}, modifiers.includes("once") ? { once: true } : false);
	}
};
var wireLiteralSpec = (el, spec, write) => {
	const [head, arrowRest] = splitOutsideQuotes(spec, "->");
	if (arrowRest != null) {
		const [onRaw, offRaw] = splitOutsideQuotes(arrowRest, "~");
		const onValue = unquoteLiteral(onRaw);
		const offValue = offRaw == null ? "" : unquoteLiteral(offRaw);
		if (onValue == null || offValue == null) return false;
		bindPredicate(el, head.trim(), (on) => write(on ? onValue : offValue));
		return true;
	}
	const [refPart, fallbackRaw] = splitOutsideQuotes(spec, "~");
	if (fallbackRaw == null) return false;
	const fallback = unquoteLiteral(fallbackRaw);
	if (fallback == null) return false;
	bindRef(el, refPart.trim(), (store, rest) => {
		const value = resolveValuePath(store, rest);
		write(value == null || value === "" ? fallback : value);
	});
	return true;
};
var wireText = (el, attr) => {
	const ref = ga(el, attr);
	if (!ref) return;
	const write = (text) => {
		el.textContent = text ?? "";
	};
	if (!wireLiteralSpec(el, ref, write)) bindRef(el, ref, (store, rest) => write(resolveValuePath(store, rest)));
};
var scanSplit = (s, delims, limit) => {
	const out = [];
	let depth = 0;
	let start = 0;
	for (let i = 0; i <= s.length; i++) {
		const ch = s[i];
		if (i === s.length || depth === 0 && delims.includes(ch) && out.length < limit) {
			out.push(s.slice(start, i));
			start = i + 1;
		} else if (ch === "[") depth++;
		else if (ch === "]" && depth > 0) depth--;
	}
	return out;
};
/**
* Toggle `onClasses` with the predicate and `offClasses` against it — one
* binding, exactly one branch active, so paired utilities SWAP instead of
* stacking (conflicting classes stacked on one element resolve by CSS order,
* not by which was toggled last).
*/
var bindClasses = (el, spec, onClasses, offClasses) => {
	bindPredicate(el, spec, (value) => {
		for (const name of onClasses) el.classList.toggle(name, !!value);
		for (const name of offClasses) el.classList.toggle(name, !value);
	});
};
var wireShow = (el, attr) => {
	const spec = ga(el, attr);
	if (spec) bindClasses(el, spec, [], ["hidden"]);
};
var wireClass = (el, attr) => {
	for (const [refSpec, classList] of parseBindings(ga(el, attr), "->")) {
		const [onPart, offPart = ""] = scanSplit(classList, "~", 1);
		const onClasses = scanSplit(onPart, "+ 	\n\r", Infinity).filter(Boolean);
		const offClasses = scanSplit(offPart, "+ 	\n\r", Infinity).filter(Boolean);
		if (onClasses.length || offClasses.length) bindClasses(el, refSpec, onClasses, offClasses);
	}
};
var setBoundAttribute = (el, attr, value) => {
	if (attr === "value") {
		el.value = value ?? "";
		return;
	}
	if (attr === "checked") {
		el.checked = !!value;
		return;
	}
	if (attr.startsWith("aria-") && typeof value === "boolean") {
		el.setAttribute(attr, String(value));
		return;
	}
	if (value == null || value === false) {
		el.removeAttribute(attr);
		return;
	}
	el.setAttribute(attr, value === true ? "" : String(value));
};
var wireBind = (el, attr) => {
	for (const [name, ref] of parseBindings(ga(el, attr), ":")) {
		const write = (value) => setBoundAttribute(el, name, value);
		if (!wireLiteralSpec(el, ref, write)) bindPredicate(el, ref, write);
	}
};
var wireStyle = (el, attr) => {
	for (const [property, ref] of parseBindings(ga(el, attr), "->")) bindRef(el, ref, (store, rest) => {
		const value = resolveValuePath(store, rest);
		const style = el.style;
		if (value == null || value === false) style.removeProperty(property);
		else style.setProperty(property, String(value));
	});
};
var writeVal = (el, value) => setIfChanged(el, "value", value);
var readVal = (el) => el.value;
var MODEL_IMPL = [
	[writeVal, readVal],
	[
		writeVal,
		readVal,
		true
	],
	[
		(el, value) => {
			el.checked = !!value;
		},
		(el) => el.checked,
		true
	],
	[
		(el, value) => {
			el.checked = String(value) === el.value;
		},
		(el) => el.checked ? el.value : void 0,
		true
	],
	[
		() => {},
		(el) => el.files ? [...el.files] : [],
		true
	],
	[
		(el, value) => {
			const values = Array.isArray(value) ? value.map(String) : [];
			for (const option of el.options) option.selected = values.includes(option.value);
		},
		(el) => Array.from(el.selectedOptions, (option) => option.value),
		true
	],
	[(el, value) => setIfChanged(el, "textContent", value), (el) => el.textContent]
];
var modelKind = (el) => {
	const tag = el.tagName;
	if (tag === "INPUT") {
		const type = (ga(el, "type") || "").toLowerCase();
		return type === "checkbox" ? 2 : type === "radio" ? 3 : type === "file" ? 4 : 0;
	}
	if (tag === "SELECT") return el.multiple ? 5 : 1;
	return ga(el, "contenteditable") != null ? 6 : 0;
};
var applyModelModifiers = (value, modifiers) => {
	if (typeof value !== "string") return value;
	const next = modifiers.has("trim") ? value.trim() : value;
	if (modifiers.has("number") && next !== "") {
		const numeric = +next;
		if (!Number.isNaN(numeric)) return numeric;
	}
	return next;
};
var wireModel = (el, attr) => {
	const spec = ga(el, attr);
	if (!spec) return;
	const parts = spec.split("|");
	const [store, rest] = resolveRef(parts[0], el);
	if (!store) return;
	const state = store[0];
	const modifiers = new Set(parts.slice(1));
	const [write, read, changes] = MODEL_IMPL[modelKind(el)];
	effect(() => write(el, resolvePath(state, rest)));
	listen(el, changes || modifiers.has("lazy") ? "change" : "input", () => {
		const raw = read(el);
		if (raw !== void 0) writePathOnState(state, rest, applyModelModifiers(raw, modifiers));
	});
};
//#endregion
//#region src/core/structural.ts
var tplParts = (el) => {
	const tpl = el;
	if (tpl._pb) return null;
	tpl._pb = true;
	const proto = tpl.content?.firstElementChild;
	return proto ? [
		tpl,
		proto,
		tpl.parentElement
	] : null;
};
var mountClone = (proto, parent, after, prep) => {
	const node = proto.cloneNode(true);
	prep?.(node);
	const scope = createScope();
	parent.insertBefore(node, after.nextSibling);
	runInScope(scope, () => hydrate(node));
	return [node, scope];
};
var unmount = ([node, scope]) => {
	disposeScope(scope);
	node.remove();
};
var setupFor = (el, attr) => {
	const tp = tplParts(el);
	if (!tp) return;
	const [tpl, proto, parent] = tp;
	const spec = ga(tpl, attr);
	const ofIndex = spec.indexOf(" of ");
	if (ofIndex < 0) return;
	const alias = spec.slice(0, ofIndex).trim();
	const keyAttr = ga(tpl, "data-p-key") || "";
	const [store, rest] = resolveRef(spec.slice(ofIndex + 4).trim(), tpl);
	if (!store) return;
	const rendered = /* @__PURE__ */ new Map();
	onCleanup(() => {
		for (const [, scope] of rendered.values()) disposeScope(scope);
	});
	effect(() => {
		const items = resolvePath(store[0], rest) || [];
		const liveKeys = /* @__PURE__ */ new Set();
		let previousNode = tpl;
		items.forEach((item, index) => {
			const key = keyAttr ? resolvePath({ [alias]: item }, stripStatePrefix(keyAttr)) : index;
			liveKeys.add(key);
			let entry = rendered.get(key);
			if (entry) {
				const state = entry[0]._ps[0];
				if (state[alias] !== item) state[alias] = item;
				if (previousNode.nextSibling !== entry[0]) parent.insertBefore(entry[0], previousNode.nextSibling);
			} else {
				entry = mountClone(proto, parent, previousNode, (node) => {
					node.setAttribute(STORE_ATTR, LOCAL_PREFIX + alias);
					node._ps = [reactive({ [alias]: item }), {}];
				});
				rendered.set(key, entry);
			}
			previousNode = entry[0];
		});
		for (const [key, entry] of rendered) if (!liveKeys.has(key)) {
			unmount(entry);
			rendered.delete(key);
		}
	});
};
var setupIf = (el, attr) => {
	const tp = tplParts(el);
	if (!tp) return;
	const [tpl, proto, parent] = tp;
	let mounted = null;
	onCleanup(() => {
		if (mounted) disposeScope(mounted[1]);
	});
	bindPredicate(tpl, ga(tpl, attr), (value) => {
		if (value && !mounted) mounted = mountClone(proto, parent, tpl);
		else if (!value && mounted) {
			unmount(mounted);
			mounted = null;
		}
	});
};
//#endregion
//#region src/core/portal.ts
var portalRoot = null;
var portal = (element) => {
	const el = element;
	if (!el._pp) {
		const dark = !!el.parentNode?.closest?.(".dark") && !el.classList.contains("dark");
		el._pp = [
			el.parentNode,
			el.nextSibling,
			dark
		];
		el.style.pointerEvents = "auto";
		if (dark) el.classList.add("dark");
		if (!portalRoot) {
			portalRoot = document.createElement("div");
			portalRoot.id = "publr-portal";
			portalRoot.style.cssText = "position:fixed;top:0;left:0;z-index:9999;pointer-events:none;";
			document.body.appendChild(portalRoot);
		}
		portalRoot.appendChild(el);
	}
	return () => unportal(el);
};
var unportal = (element) => {
	const el = element;
	const saved = el._pp;
	if (!saved) return;
	if (saved[0]) saved[0].insertBefore(el, saved[1] || null);
	el.style.pointerEvents = "";
	if (saved[2]) el.classList.remove("dark");
	el._pp = null;
};
var wirePortal = (element) => {
	const el = element;
	if (!el._pw) {
		el._pw = true;
		onCleanup(portal(el));
	}
};
//#endregion
//#region src/core/lifecycle.ts
var elementsWithAttr = (root, attr) => {
	const descendants = root.querySelectorAll(`[${attr}]`);
	return root.nodeType === 1 && ga(root, attr) != null ? [root, ...descendants] : descendants;
};
var instantiateIslands = (root) => {
	for (const element of elementsWithAttr(root, STORE_ATTR)) {
		const el = element;
		const name = ga(el, STORE_ATTR);
		if (!name) continue;
		const inlineSeed = ga(el, "data-p");
		if (!name.startsWith("local:")) {
			const entry = sharedStores.get(name);
			if (entry) applyInlineSeed(entry[0], inlineSeed);
			continue;
		}
		if (el._ps) continue;
		const factoryName = name.slice(LOCAL_PREFIX.length);
		const factory = localFactories.get(factoryName);
		if (!factory) continue;
		const scope = createScope();
		el._pc = scope;
		runInScope(scope, () => {
			const instance = factory();
			const ref = toRef(instance);
			const [state, actions, watch, setup] = ref;
			if (instance?.state) tagStore(unwrap(state), factoryName, "");
			if (instance?.actions) runHooks(actionsInitHooks, actions, factoryName);
			applyInlineSeed(state, inlineSeed);
			el._ps = ref;
			if (watch) wireWatchBlock(state, watch, el);
			if (isFn(setup)) {
				const teardown = setup({ el });
				if (isFn(teardown)) onCleanup(teardown);
			}
		});
	}
};
var scopeForEl = (el) => {
	let node = el;
	while (node) {
		const scope = node._pc;
		if (scope) return scope;
		node = node.parentElement;
	}
	return null;
};
var disposeIsland = (element) => {
	const el = element;
	if (el._pc) {
		disposeScope(el._pc);
		el._pc = null;
		el._ps = null;
		el._pw = false;
	}
};
/**
* Tear down every island in a subtree (and the root itself if it is one),
* running their cleanups — including un-portaling content back out of <body>.
* Call before replacing server-rendered markup (gallery canvas, Turbo
* `before-render`); the unmount observer also calls it automatically when a
* hydrated node is removed from the DOM.
*/
var destroy = (root = document) => {
	if (!root || root.nodeType !== 1) return;
	disposeIsland(root);
	for (const el of root.querySelectorAll(`[${STORE_ATTR}]`)) disposeIsland(el);
};
var unmountObserver = null;
var ensureUnmountObserver = () => {
	if (unmountObserver || typeof MutationObserver === "undefined") return;
	unmountObserver = new MutationObserver((mutations) => {
		for (const m of mutations) m.removedNodes.forEach((node) => {
			if (node.isConnected) return;
			destroy(node);
		});
	});
	unmountObserver.observe(document.documentElement, {
		childList: true,
		subtree: true
	});
};
var WIRING = [
	["on", wireOn],
	["text", wireText],
	["show", wireShow],
	["class", wireClass],
	["bind", wireBind],
	["style", wireStyle],
	["model", wireModel],
	["for", setupFor],
	["if", setupIf],
	["portal", wirePortal]
];
/**
* Bind directives in a DOM subtree to the registered stores. Instantiates local-factory
* islands, wires each directive, and expands structural `<template>`s. Each island's
* directives wire inside that island's scope so they tear down together on unmount.
*/
var hydrate = (root = document) => {
	instantiateIslands(root);
	for (const [suffix, wire] of WIRING) {
		const attr = "data-p-" + suffix;
		for (const el of elementsWithAttr(root, attr)) {
			const scope = scopeForEl(el);
			if (scope) runInScope(scope, () => wire(el, attr));
			else wire(el, attr);
		}
	}
	ensureUnmountObserver();
	return root;
};
//#endregion
//#region src/publr.ts
/** The Publr global runtime API. */
var Publr = {
	reactive,
	effect,
	portal,
	unportal,
	/**
	* Bind directives in a DOM subtree (default: whole document). Call after
	* injecting server-rendered markup dynamically (gallery canvas, Turbo frames)
	* so newly-added `data-p-*` elements get wired. Bind each subtree once —
	* re-binding the same nodes would attach duplicate listeners.
	*/
	hydrate,
	/**
	* Tear down islands in a subtree — run their cleanups (un-portal, remove
	* listeners, setup teardown), dispose their effects. Call before replacing
	* hydrated markup. Also runs automatically when a hydrated node is removed
	* from the DOM (unmount observer), so explicit calls are optional but make
	* teardown synchronous + deterministic.
	*/
	destroy,
	randomId() {
		return globalThis.crypto?.randomUUID?.() ?? `id-${Math.random().toString(36).slice(2, 18)}`;
	},
	store,
	get stores() {
		const out = {};
		sharedStores.forEach((ref, name) => out[name] = ref[0]);
		return out;
	},
	untrack,
	subscribe,
	_internals: [
		reactive,
		effect,
		runInScope,
		onCleanup,
		tagStore,
		unwrap,
		proxyCache,
		RAW,
		getActiveScope,
		stateInitHooks,
		actionsInitHooks,
		proxyGetHooks,
		proxySetHooks,
		deepMergeHooks
	]
};
if (typeof window !== "undefined") {
	window.Publr = Publr;
	if (document.readyState === "complete") queueMicrotask(hydrate);
	else document.addEventListener("DOMContentLoaded", () => hydrate());
}
//#endregion
export { Publr, destroy, effect, hydrate, portal, reactive, unportal };
