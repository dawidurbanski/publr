// Publr Interactivity — Core
// Shared registry and namespace. Loaded by admin and themes.

const handlers = {};
const features = {};

export function register(type, fn) {
    handlers[type] = fn;
}

export function feature(name, fn) {
    features[name] = fn;
}

export function init() {
    document.querySelectorAll('[data-publr-component]').forEach(el => {
        if (el._publrInit) return;
        const type = el.dataset.publrComponent;
        if (handlers[type]) {
            el._publrInit = true;
            handlers[type](el);
        }
    });
    Object.values(features).forEach(fn => fn());
}

document.addEventListener('DOMContentLoaded', init);
