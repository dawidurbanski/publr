const MAX_FLUSH_DEPTH = 100;

const RAW = Symbol("raw");
const STORE_TAG = Symbol("store-tag");

let activeEffect = null;
let activeScope = null;
let flushScheduled = false;
let flushDepth = 0;

const targetDeps = new WeakMap();
const pendingEffects = new Set();
const proxyCache = new WeakMap();
const computedKeys = new WeakMap();
const globalSubscribers = new Set();
const sharedStores = new Map();
const localFactories = new Map();

const stateInitHooks = [];
const actionsInitHooks = [];
const proxyGetHooks = [];
const proxySetHooks = [];
const deepMergeHooks = [];

function track(target, key) {
  if (!activeEffect) {
    return;
  }

  let keyMap = targetDeps.get(target);

  if (!keyMap) {
    targetDeps.set(target, (keyMap = new Map()));
  }

  let dep = keyMap.get(key);

  if (!dep) {
    keyMap.set(key, (dep = new Set()));
  }

  dep.add(activeEffect);
  activeEffect.deps.push(dep);
}

function trigger(target, key, oldValue, newValue) {
  if (activeEffect?.isGetter) {
    throw new Error(
      `Computed getter '${activeEffect.getterName}' wrote to state — getters must be pure.`,
    );
  }

  const dep = targetDeps.get(target)?.get(key);

  if (dep) {
    for (const record of dep) {
      pendingEffects.add(record);
    }

    if (!flushScheduled) {
      flushScheduled = true;
      queueMicrotask(flush);
    }
  }

  if (globalSubscribers.size && target[STORE_TAG]) {
    notifySubscribers(target, key, oldValue, newValue);
  }
}

function flush() {
  try {
    while (pendingEffects.size) {
      if (++flushDepth > MAX_FLUSH_DEPTH) {
        const offenders = [...pendingEffects]
          .slice(-3)
          .map((record) => record.label || "<unlabelled>")
          .join(", ");
        pendingEffects.clear();
        throw new Error(`Infinite update loop — last effects: ${offenders}`);
      }

      const batch = [...pendingEffects];
      pendingEffects.clear();

      for (const record of batch) {
        record.scheduler?.();
      }

      for (const record of batch) {
        if (!record.scheduler) {
          record.run();
        }
      }
    }
  } finally {
    flushScheduled = false;
    flushDepth = 0;
  }
}

/**
 * Run `fn` and re-run it whenever a reactive value it read changes (microtask-batched).
 * Returns a runner that re-runs inline and returns the last value.
 * `opts`: `lazy` (skip initial), `scheduler` (replaces `run()` when queued), `label` (cycle errors).
 */
export function effect(fn, opts) {
  let lastValue;

  const record = {
    deps: [],
    disposed: false,
    label: opts?.label ?? null,
    scheduler: opts?.scheduler ?? null,
    isGetter: false,
    getterName: null,
    run() {
      if (record.disposed) {
        return lastValue;
      }

      for (const dep of record.deps) {
        dep.delete(record);
      }

      record.deps.length = 0;
      const prev = activeEffect;
      activeEffect = record;

      try {
        lastValue = fn();
      } finally {
        activeEffect = prev;
      }

      return lastValue;
    },
  };

  activeScope?.effects.push(record);

  if (!opts?.lazy) {
    record.run();
  }

  const runner = () => record.run();
  runner._effect = record;

  return runner;
}

function disposeEffect(record) {
  for (const dep of record.deps) {
    dep.delete(record);
  }

  record.deps.length = 0;
  record.disposed = true;
}

function createScope() {
  return { effects: [], cleanups: [] };
}

function runInScope(scope, fn) {
  const prev = activeScope;
  activeScope = scope;

  try {
    return fn();
  } finally {
    activeScope = prev;
  }
}

function disposeScope(scope) {
  for (const record of scope.effects) {
    disposeEffect(record);
  }

  for (const cleanup of scope.cleanups) {
    cleanup();
  }

  scope.effects.length = 0;
  scope.cleanups.length = 0;
}

function onCleanup(fn) {
  activeScope?.cleanups.push(fn);
}

function tagStore(target, storeName, path) {
  if (!target || typeof target !== "object" || target[STORE_TAG]) {
    return;
  }

  try {
    Object.defineProperty(target, STORE_TAG, {
      value: { store: storeName, path },
      configurable: true,
    });
  } catch (_) {}
}

function subscriptionMatches(sub, tag, path) {
  if (sub.kind === "all") {
    return true;
  }

  if (sub.store !== tag.store) {
    return false;
  }

  if (sub.kind === "store") {
    return true;
  }

  const prefix = sub.pathPrefix;

  return path === prefix || path.startsWith(prefix + ".");
}

function notifySubscribers(target, key, oldValue, newValue) {
  const tag = target[STORE_TAG];
  const path = tag.path ? `${tag.path}.${String(key)}` : String(key);
  const isComputed = !!computedKeys.get(target)?.has(key);
  const change = { store: tag.store, path, oldValue, newValue, isComputed, source: target };

  for (const sub of [...globalSubscribers]) {
    if (subscriptionMatches(sub, tag, path)) {
      sub.fn(change);
    }
  }
}

function isPlainReactiveCandidate(obj) {
  if (Array.isArray(obj)) {
    return true;
  }

  const proto = Object.getPrototypeOf(obj);

  return proto === Object.prototype || proto === null;
}

function memoizeGetter(target, key, originalGetter) {
  let cached;

  const runner = effect(() => originalGetter.call(target), {
    lazy: true,
    label: `getter(${key})`,
    scheduler() {
      const next = runner();

      if (next !== cached) {
        const prev = cached;
        cached = next;
        trigger(target, key, prev, next);
      }
    },
  });

  runner._effect.isGetter = true;
  runner._effect.getterName = key;
  cached = runner();

  let keys = computedKeys.get(target);

  if (!keys) {
    computedKeys.set(target, (keys = new Set()));
  }

  keys.add(key);

  Object.defineProperty(target, key, {
    get() {
      track(target, key);
      return cached;
    },
    enumerable: true,
    configurable: true,
  });
}

function deferGetterMemoization(target) {
  const descriptors = Object.getOwnPropertyDescriptors(target);

  for (const key of Object.keys(descriptors)) {
    const descriptor = descriptors[key];

    if (descriptor.get && !descriptor.set && descriptor.configurable) {
      const originalGetter = descriptor.get;
      queueMicrotask(() => memoizeGetter(target, key, originalGetter));
    }
  }
}

function runStateInitHooks(target, storeName) {
  for (const hook of stateInitHooks) {
    hook(target, storeName);
  }
}

function runActionsInitHooks(actions, storeName) {
  for (const hook of actionsInitHooks) {
    hook(actions, storeName);
  }
}

/**
 * Wrap a plain object/array in a deep reactive Proxy. Nested values wrap lazily on access.
 * DOM nodes, Files, Maps, Sets, Dates, etc. pass through unwrapped.
 */
export function reactive(obj) {
  if (obj === null || typeof obj !== "object") {
    return obj;
  }

  if (obj[RAW]) {
    return obj;
  }

  if (!isPlainReactiveCandidate(obj)) {
    return obj;
  }

  runStateInitHooks(obj);

  const cached = proxyCache.get(obj);

  if (cached) {
    return cached;
  }

  deferGetterMemoization(obj);

  const proxy = new Proxy(obj, {
    get(target, key, receiver) {
      if (key === RAW) {
        return target;
      }

      track(target, key);
      const value = Reflect.get(target, key, receiver);

      if (value && typeof value === "object") {
        if (
          target[STORE_TAG] &&
          !value[STORE_TAG] &&
          isPlainReactiveCandidate(value)
        ) {
          const parent = target[STORE_TAG];
          const childPath = parent.path ? `${parent.path}.${String(key)}` : String(key);
          tagStore(value, parent.store, childPath);
        }

        for (const hook of proxyGetHooks) {
          hook(target, value);
        }
      }

      return reactive(value);
    },
    set(target, key, value, receiver) {
      const oldValue = target[key];
      const oldLength = Array.isArray(target) ? target.length : -1;

      for (const hook of proxySetHooks) {
        hook(target, key, oldValue, value);
      }

      const ok = Reflect.set(target, key, value, receiver);

      if (oldValue !== value) {
        trigger(target, key, oldValue, value);
      }

      if (oldLength !== -1 && key !== "length" && target.length !== oldLength) {
        trigger(target, "length", oldLength, target.length);
      }

      return ok;
    },
  });

  proxyCache.set(obj, proxy);

  return proxy;
}

const unwrap = (state) => state?.[RAW] ?? state;

function deepMerge(target, source) {
  outer: for (const key in source) {
    const sourceValue = source[key];
    const targetValue = target[key];

    for (const hook of deepMergeHooks) {
      if (hook(targetValue, sourceValue)) {
        continue outer;
      }
    }

    const isMergeableObject =
      sourceValue &&
      typeof sourceValue === "object" &&
      !Array.isArray(sourceValue) &&
      targetValue &&
      typeof targetValue === "object";

    if (isMergeableObject) {
      deepMerge(targetValue, sourceValue);
      continue;
    }

    const descriptor = Object.getOwnPropertyDescriptor(target, key);

    if (!descriptor || descriptor.writable || descriptor.set) {
      target[key] = sourceValue;
    }
  }
}

function readSSRSeed(storeName) {
  if (typeof document === "undefined") {
    return null;
  }

  const el = document.getElementById(`publr-state-${storeName}`);

  if (!el) {
    return null;
  }

  try {
    return JSON.parse(el.textContent);
  } catch (_) {
    return null;
  }
}

function applyInlineSeed(state, jsonText) {
  if (!jsonText) {
    return;
  }

  try {
    deepMerge(unwrap(state), JSON.parse(jsonText));
  } catch (_) {}
}

function wireWatchBlock(state, watchSpec, el) {
  const storeName = unwrap(state)?.[STORE_TAG]?.store;

  for (const rawKey of Object.keys(watchSpec)) {
    const handler = watchSpec[rawKey];

    if (typeof handler !== "function") {
      continue;
    }

    if (rawKey === "*" || rawKey.startsWith("*:")) {
      if (!storeName) {
        continue;
      }

      const filter = rawKey === "*" ? null : rawKey.slice(2);

      const unsubscribe = Publr.subscribe(storeName, (change) => {
        if (filter === "static" && change.isComputed) {
          return;
        }

        if (filter === "computed" && !change.isComputed) {
          return;
        }

        handler(change.newValue, change.oldValue, { path: change.path, el });
      });

      onCleanup(unsubscribe);
      continue;
    }

    const paths = rawKey
      .split(",")
      .map((p) => p.trim())
      .filter(Boolean);

    for (const path of paths) {
      let oldValue;
      let primed = false;

      effect(
        () => {
          const value = resolvePath(state, path);

          if (!primed) {
            oldValue = value;
            primed = true;
            return;
          }

          if (oldValue !== value) {
            handler(value, oldValue, { path, el });
          }

          oldValue = value;
        },
        { label: `watch(${path})` },
      );
    }
  }
}

/** The Publr global runtime API. */
export const Publr = {
  reactive,
  effect,
  portal,
  unportal,

  /** Generate an opaque client-side id for optimistic records. */
  randomId() {
    return globalThis.crypto?.randomUUID?.() ?? `id-${Math.random().toString(36).slice(2, 18)}`;
  },

  /** Register a store. Plain definition = SHARED singleton; function = LOCAL factory per island. */
  store(name, definition) {
    if (typeof definition === "function") {
      if (name) {
        localFactories.set(name, definition);
      }

      return;
    }

    const stateTarget = definition.state || {};
    const actions = definition.actions || {};

    if (name) {
      tagStore(stateTarget, name, "");
    }

    runStateInitHooks(stateTarget, name);
    runActionsInitHooks(actions, name);

    if (name) {
      const seed = readSSRSeed(name);

      if (seed) {
        deepMerge(stateTarget, seed);
      }
    }

    const entry = { state: reactive(stateTarget), actions };

    if (name) {
      sharedStores.set(name, entry);
    }

    if (definition.watch) {
      queueMicrotask(() => wireWatchBlock(entry.state, definition.watch, null));
    }

    return entry;
  },

  /** Live access to shared stores by name. */
  get stores() {
    const out = {};

    for (const [name, entry] of sharedStores) {
      out[name] = entry.state;
    }

    return out;
  },

  /** Run `fn` with no effect tracking. Writes still trigger normally. */
  untrack(fn) {
    const prev = activeEffect;
    activeEffect = null;

    try {
      return fn();
    } finally {
      activeEffect = prev;
    }
  },

  /**
   * Subscribe to state changes. Forms: `subscribe(fn)`, `subscribe("store", fn)`,
   * `subscribe("store.path", fn)`. Returns an unsubscribe function.
   */
  subscribe(...args) {
    const entry = buildSubscription(args);
    globalSubscribers.add(entry);

    return () => globalSubscribers.delete(entry);
  },
};

/**
 * Internal extension surface used by the query plugin
 * (`publr-interactivity-query.js`). Not part of the public API — treat as private.
 */
Publr._internals = {
  reactive,
  effect,
  runInScope,
  onCleanup,
  tagStore,
  unwrap,
  proxyCache,
  RAW,
  getActiveScope: () => activeScope,
  stateInitHooks,
  actionsInitHooks,
  proxyGetHooks,
  proxySetHooks,
  deepMergeHooks,
};

function buildSubscription(args) {
  if (typeof args[0] === "function") {
    return { kind: "all", fn: args[0] };
  }

  if (typeof args[0] !== "string" || typeof args[1] !== "function") {
    throw new Error("Publr.subscribe: expected (fn) or (selector, fn)");
  }

  const [selector, fn] = args;
  const dotIndex = selector.indexOf(".");

  if (dotIndex < 0) {
    return { kind: "store", store: selector, fn };
  }

  return {
    kind: "path",
    store: selector.slice(0, dotIndex),
    pathPrefix: selector.slice(dotIndex + 1),
    fn,
  };
}

const LOCAL_PREFIX = "local:";

const KEY_MODIFIERS = {
  enter: "Enter",
  space: " ",
  esc: "Escape",
  escape: "Escape",
  tab: "Tab",
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  delete: "Delete",
};

const COMPARATORS = {
  eq: (value, literal) => String(value) === literal,
  ne: (value, literal) => String(value) !== literal,
  lt: (value, literal) => Number(value) < Number(literal),
  gt: (value, literal) => Number(value) > Number(literal),
  ge: (value, literal) => Number(value) >= Number(literal),
  le: (value, literal) => Number(value) <= Number(literal),
};

function evaluatePredicate(value, parts) {
  if (parts.length < 3) {
    return !!value;
  }

  const compare = COMPARATORS[parts[1]];

  return compare ? compare(value, parts[2]) : false;
}

function storeChain(el) {
  const chain = [];
  let node = el;

  while (node?.getAttribute) {
    const name = node.getAttribute("data-p-store");

    if (name) {
      const store = name.startsWith(LOCAL_PREFIX) ? node._publrStore : sharedStores.get(name);

      if (store) {
        chain.push(store);
      }
    }

    node = node.parentElement;
  }

  return chain;
}

function elementsWithAttr(root, attr) {
  const descendants = root.querySelectorAll(`[${attr}]`);

  if (root.nodeType === 1 && root.getAttribute(attr) != null) {
    return [root, ...descendants];
  }

  return descendants;
}

function resolveRef(ref, el) {
  const chain = storeChain(el);
  const topSegment = ref.split(".")[0];

  for (const store of chain) {
    if (store.state && topSegment in store.state) {
      return { store, rest: ref };
    }

    if (store.actions && (ref in store.actions || topSegment in store.actions)) {
      return { store, rest: ref };
    }
  }

  if (ref.indexOf(".") < 0) {
    const store = sharedStores.get(ref);

    if (store) {
      return { store, rest: ref };
    }
  }

  return { store: chain[0] || null, rest: ref };
}

function resolvePath(root, path) {
  return path
    .trim()
    .split(".")
    .reduce((obj, key) => obj?.[key], root);
}

function resolveValuePath(store, path) {
  const topSegment = path.split(".")[0];

  if (store.state && topSegment in store.state) {
    return resolvePath(store.state, path);
  }

  if (store.actions && topSegment in store.actions) {
    return resolvePath(store.actions, path);
  }

  return undefined;
}

function parseBindings(value, separator) {
  const bindings = [];

  for (const part of value.split(";")) {
    const index = part.indexOf(separator);

    if (index < 0) {
      continue;
    }

    const lhs = part.slice(0, index).trim();
    const rhs = part.slice(index + separator.length).trim();

    if (lhs && rhs) {
      bindings.push([lhs, rhs]);
    }
  }

  return bindings;
}

function resolvePredicateValue(store, rest, parts) {
  const raw = resolveValuePath(store, rest);

  return parts.length >= 3 ? evaluatePredicate(raw, parts) : raw;
}

// Split a predicate spec like `"loading"`, `"not:loading"`, `"count|gt|10"`,
// or `"not:count|gt|10"` into pipe parts + a leading-`not:` negation flag.
// Mutates `parts[0]` to strip the prefix so the rest of the pipeline sees a
// clean ref.
function parsePredicateSpec(spec) {
  const parts = spec.split("|");
  const negate = parts[0].startsWith("not:");

  if (negate) {
    parts[0] = parts[0].slice(4);
  }

  return { parts, negate };
}

function bindRef(el, ref, callback) {
  const { store, rest } = resolveRef(ref, el);

  if (!store) {
    return;
  }

  effect(() => callback(store, rest));
}

function instantiateIslands(root) {
  for (const el of elementsWithAttr(root, "data-p-store")) {
    const name = el.getAttribute("data-p-store");

    if (!name) {
      continue;
    }

    const inlineSeed = el.getAttribute("data-p");

    if (!name.startsWith(LOCAL_PREFIX)) {
      const entry = sharedStores.get(name);

      if (entry) {
        applyInlineSeed(entry.state, inlineSeed);
      }

      continue;
    }

    if (el._publrStore) {
      continue;
    }

    const factoryName = name.slice(LOCAL_PREFIX.length);
    const factory = localFactories.get(factoryName);

    if (!factory) {
      continue;
    }

    const instance = factory();

    if (instance?.state) {
      tagStore(unwrap(instance.state), factoryName, "");
    }

    if (instance?.actions) {
      runActionsInitHooks(instance.actions, factoryName);
    }

    applyInlineSeed(instance.state, inlineSeed);
    el._publrStore = instance;

    if (instance.watch) {
      wireWatchBlock(instance.state, instance.watch, el);
    }

    if (typeof instance.setup === "function") {
      const teardown = instance.setup({ el });

      if (typeof teardown === "function") {
        onCleanup(teardown);
      }
    }
  }
}

function wireOn(el) {
  for (const [descriptor, actionRef] of parseBindings(el.getAttribute("data-p-on"), ":")) {
    const { store, rest } = resolveRef(actionRef, el);

    if (!store) {
      continue;
    }

    const [eventName, ...modifiers] = descriptor.split(".");
    const target = pickEventTarget(el, modifiers);
    const keyFilters = modifiers.filter((modifier) => modifier in KEY_MODIFIERS);
    const opts = modifiers.includes("once") ? { once: true } : false;

    const handler = (event) => {
      if (keyFilters.length && !keyFilters.some((key) => event.key === KEY_MODIFIERS[key])) {
        return;
      }

      if (modifiers.includes("prevent")) {
        event.preventDefault();
      }

      if (modifiers.includes("stop")) {
        event.stopPropagation();
      }

      const action = store.actions[rest];

      if (action) {
        action({ ...el.dataset }, { el, event });
        return;
      }

      let fn = resolvePath(store.actions, rest);

      if (typeof fn !== "function") {
        fn = resolvePath(store.state, rest);
      }

      if (typeof fn === "function") {
        fn();
      }
    };

    target.addEventListener(eventName, handler, opts);
    onCleanup(() => target.removeEventListener(eventName, handler, opts));
  }
}

function pickEventTarget(el, modifiers) {
  if (modifiers.includes("window")) {
    return window;
  }

  if (modifiers.includes("document")) {
    return document;
  }

  return el;
}

function wireText(el) {
  const ref = el.getAttribute("data-p-text");

  if (ref) {
    bindRef(el, ref, (store, rest) => {
      el.textContent = resolveValuePath(store, rest) ?? "";
    });
  }
}

function wireShow(el) {
  const spec = el.getAttribute("data-p-show");

  if (!spec) {
    return;
  }

  const { parts, negate } = parsePredicateSpec(spec);

  bindRef(el, parts[0], (store, rest) => {
    let truthy = !!resolvePredicateValue(store, rest, parts);

    if (negate) {
      truthy = !truthy;
    }

    el.classList.toggle("hidden", !truthy);
  });
}

function wireClass(el) {
  for (const [refSpec, classList] of parseBindings(el.getAttribute("data-p-class"), "->")) {
    const classes = classList.split(/\s+/).filter(Boolean);

    if (!classes.length) {
      continue;
    }

    const { parts, negate } = parsePredicateSpec(refSpec);

    bindRef(el, parts[0], (store, rest) => {
      let on = !!resolvePredicateValue(store, rest, parts);

      if (negate) {
        on = !on;
      }

      for (const className of classes) {
        el.classList.toggle(className, on);
      }
    });
  }
}

function setBoundAttribute(el, attr, value) {
  if (attr === "value") {
    el.value = value ?? "";
    return;
  }

  if (attr === "checked") {
    el.checked = !!value;
    return;
  }

  if (value == null || value === false) {
    el.removeAttribute(attr);
    return;
  }

  el.setAttribute(attr, value === true ? "" : String(value));
}

function wireBind(el) {
  for (const [attr, ref] of parseBindings(el.getAttribute("data-p-bind"), ":")) {
    const { parts, negate } = parsePredicateSpec(ref);

    bindRef(el, parts[0], (store, rest) => {
      let value = resolvePredicateValue(store, rest, parts);

      if (negate) {
        value = !value;
      }

      setBoundAttribute(el, attr, value);
    });
  }
}

function wireStyle(el) {
  for (const [property, ref] of parseBindings(el.getAttribute("data-p-style"), "->")) {
    bindRef(el, ref, (store, rest) => {
      const value = resolveValuePath(store, rest);

      if (value == null || value === false) {
        el.style.removeProperty(property);
      } else {
        el.style.setProperty(property, String(value));
      }
    });
  }
}

function modelKind(el) {
  const tag = el.tagName;

  if (tag === "INPUT") {
    const type = (el.getAttribute("type") || "").toLowerCase();

    switch (type) {
      case "checkbox":
        return "checkbox";
      case "radio":
        return "radio";
      case "file":
        return "file";
      default:
        return "text";
    }
  }

  if (tag === "SELECT") {
    return el.multiple ? "multiSelect" : "select";
  }

  if (el.getAttribute("contenteditable") != null) {
    return "contentEditable";
  }

  return "text";
}

function writeModelToElement(el, kind, value) {
  switch (kind) {
    case "radio":
      el.checked = String(value) === el.value;
      return;

    case "checkbox":
      el.checked = !!value;
      return;

    case "file":
      return;

    case "multiSelect": {
      const values = Array.isArray(value) ? value.map(String) : [];

      for (const option of el.options) {
        option.selected = values.includes(option.value);
      }

      return;
    }

    case "contentEditable": {
      const text = value == null ? "" : String(value);

      if (el.textContent !== text) {
        el.textContent = text;
      }

      return;
    }

    default: {
      const text = value == null ? "" : String(value);

      if (el.value !== text) {
        el.value = text;
      }
    }
  }
}

function readModelFromElement(el, kind) {
  switch (kind) {
    case "radio":
      return el.checked ? el.value : undefined;

    case "checkbox":
      return el.checked;

    case "file":
      return el.files ? Array.from(el.files) : [];

    case "multiSelect":
      return Array.from(el.selectedOptions).map((option) => option.value);

    case "contentEditable":
      return el.textContent;

    default:
      return el.value;
  }
}

function applyModelModifiers(value, modifiers) {
  if (typeof value !== "string") {
    return value;
  }

  let next = value;

  if (modifiers.has("trim")) {
    next = next.trim();
  }

  if (modifiers.has("number") && next !== "") {
    const numeric = Number(next);

    if (!Number.isNaN(numeric)) {
      return numeric;
    }
  }

  return next;
}

function writePathOnState(state, path, value) {
  const segments = path.split(".");
  const tail = segments.pop();
  let target = state;

  for (const segment of segments) {
    target = target?.[segment];
  }

  if (target != null) {
    target[tail] = value;
  }
}

const CHANGE_EVENT_KINDS = new Set(["checkbox", "radio", "file", "multiSelect", "select"]);

function modelEventName(kind, modifiers) {
  if (CHANGE_EVENT_KINDS.has(kind)) {
    return "change";
  }

  return modifiers.has("lazy") ? "change" : "input";
}

function wireModel(el) {
  const spec = el.getAttribute("data-p-model");

  if (!spec) {
    return;
  }

  const parts = spec.split("|");
  const { store, rest } = resolveRef(parts[0], el);

  if (!store) {
    return;
  }

  const modifiers = new Set(parts.slice(1));
  const kind = modelKind(el);
  const eventName = modelEventName(kind, modifiers);

  effect(() => writeModelToElement(el, kind, resolvePath(store.state, rest)));

  const handler = () => {
    const raw = readModelFromElement(el, kind);

    if (raw === undefined) {
      return;
    }

    writePathOnState(store.state, rest, applyModelModifiers(raw, modifiers));
  };

  el.addEventListener(eventName, handler);
  onCleanup(() => el.removeEventListener(eventName, handler));
}

function setupFor(tpl) {
  if (tpl._publrBound) {
    return;
  }

  tpl._publrBound = true;
  const spec = tpl.getAttribute("data-p-for");
  const ofIndex = spec.indexOf(" of ");
  const proto = tpl.content?.firstElementChild;

  if (ofIndex < 0 || !proto) {
    return;
  }

  const alias = spec.slice(0, ofIndex).trim();
  const keyAttr = tpl.getAttribute("data-p-key") || "";
  const { store, rest } = resolveRef(spec.slice(ofIndex + 4).trim(), tpl);

  if (!store) {
    return;
  }

  const parent = tpl.parentElement;
  const rendered = new Map();

  onCleanup(() => {
    for (const { scope } of rendered.values()) {
      disposeScope(scope);
    }
  });

  effect(() => {
    const items = resolvePath(store.state, rest) || [];
    const liveKeys = new Set();
    let previousNode = tpl;

    items.forEach((item, index) => {
      const key = keyAttr ? item[keyAttr] : index;
      liveKeys.add(key);
      let entry = rendered.get(key);

      if (entry) {
        if (entry.node._publrStore.state[alias] !== item) {
          entry.node._publrStore.state[alias] = item;
        }

        if (previousNode.nextSibling !== entry.node) {
          parent.insertBefore(entry.node, previousNode.nextSibling);
        }
      } else {
        const node = proto.cloneNode(true);
        node.setAttribute("data-p-store", LOCAL_PREFIX + alias);
        node._publrStore = { state: reactive({ [alias]: item }), actions: {} };
        const scope = createScope();
        entry = { node, scope };
        rendered.set(key, entry);
        parent.insertBefore(node, previousNode.nextSibling);
        runInScope(scope, () => hydrate(node));
      }

      previousNode = entry.node;
    });

    for (const [key, entry] of rendered) {
      if (liveKeys.has(key)) {
        continue;
      }

      disposeScope(entry.scope);
      entry.node.remove();
      rendered.delete(key);
    }
  });
}

function setupIf(tpl) {
  if (tpl._publrBound) {
    return;
  }

  tpl._publrBound = true;
  const proto = tpl.content?.firstElementChild;

  if (!proto) {
    return;
  }

  const { parts, negate } = parsePredicateSpec(tpl.getAttribute("data-p-if"));
  const parent = tpl.parentElement;
  let mounted = null;

  onCleanup(() => {
    if (mounted) {
      disposeScope(mounted.scope);
    }
  });

  bindRef(tpl, parts[0], (store, rest) => {
    let truthy = !!resolvePredicateValue(store, rest, parts);

    if (negate) {
      truthy = !truthy;
    }

    if (truthy && !mounted) {
      const node = proto.cloneNode(true);
      const scope = createScope();
      mounted = { node, scope };
      parent.insertBefore(node, tpl.nextSibling);
      runInScope(scope, () => hydrate(node));
      return;
    }

    if (!truthy && mounted) {
      disposeScope(mounted.scope);
      mounted.node.remove();
      mounted = null;
    }
  });
}

// ── Portal (core) ─────────────────────────────────────────────────────────
// Move an element to a fixed portal root so it escapes overflow/stacking
// contexts (dropdowns, dialogs, tooltips), and restore it on cleanup. Carries
// the `.dark` class forward so portaled content keeps the theme cascade.
// Authored as `@portal` (→ data-p-portal); also exposed imperatively as
// Publr.portal / Publr.unportal for component plugins.
let portalRoot = null;
function getPortalRoot() {
  if (!portalRoot) {
    portalRoot = document.createElement("div");
    portalRoot.id = "publr-portal";
    portalRoot.style.cssText =
      "position:fixed;top:0;left:0;z-index:9999;pointer-events:none;";
    document.body.appendChild(portalRoot);
  }
  return portalRoot;
}

export function portal(el) {
  if (el._publrPortaled) return () => unportal(el);
  el._publrPortaled = true;
  el._publrPortalParent = el.parentNode;
  el._publrPortalNext = el.nextSibling;
  el.style.pointerEvents = "auto";
  if (el.parentNode?.closest?.(".dark") && !el.classList.contains("dark")) {
    el.classList.add("dark");
    el._publrPortaledDark = true;
  }
  getPortalRoot().appendChild(el);
  return () => unportal(el);
}

export function unportal(el) {
  if (!el._publrPortaled) return;
  if (el._publrPortalParent) {
    el._publrPortalParent.insertBefore(el, el._publrPortalNext || null);
  }
  el.style.pointerEvents = "";
  if (el._publrPortaledDark) {
    el.classList.remove("dark");
    delete el._publrPortaledDark;
  }
  delete el._publrPortaled;
  delete el._publrPortalParent;
  delete el._publrPortalNext;
}

// Portal runs AFTER the directive + structural passes so the element and its
// subtree are fully wired before the node is relocated (bindings live on the
// node, so they survive the move).
function wirePortal(el) {
  if (el._publrPortalBound) return;
  el._publrPortalBound = true;
  onCleanup(portal(el));
}

const DIRECTIVES = [
  ["data-p-on", wireOn],
  ["data-p-text", wireText],
  ["data-p-show", wireShow],
  ["data-p-class", wireClass],
  ["data-p-bind", wireBind],
  ["data-p-style", wireStyle],
  ["data-p-model", wireModel],
];

const STRUCTURAL_DIRECTIVES = [
  ["data-p-for", setupFor],
  ["data-p-if", setupIf],
];

/**
 * Bind directives in a DOM subtree to the registered stores. Instantiates local-factory
 * islands, wires each directive, and expands structural `<template>`s.
 */
export function hydrate(root = document) {
  instantiateIslands(root);

  for (const [attr, wire] of DIRECTIVES) {
    for (const el of elementsWithAttr(root, attr)) {
      wire(el);
    }
  }

  for (const [attr, setup] of STRUCTURAL_DIRECTIVES) {
    for (const el of elementsWithAttr(root, attr)) {
      setup(el);
    }
  }

  // Portal pass last: element + subtree are fully wired, now relocate.
  for (const el of elementsWithAttr(root, "data-p-portal")) {
    wirePortal(el);
  }
}

if (typeof window !== "undefined") {
  window.Publr = Publr;

  if (document.readyState === "complete") {
    queueMicrotask(() => hydrate());
  } else {
    document.addEventListener("DOMContentLoaded", () => hydrate());
  }
}
