// Publr Interactivity — Core
// Shared registry and namespace. Loaded by admin and themes.

const handlers = {};
const features = {};
const widgets = {};

export function register(type, fn) {
    handlers[type] = fn;
}

export function feature(name, fn) {
    features[name] = fn;
}

export function widget(type, fn) {
    widgets[type] = fn;
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
    document.querySelectorAll('[data-widget]').forEach(el => {
        if (el._publrWidgetInit) return;
        const type = el.dataset.widget;
        if (widgets[type]) {
            el._publrWidgetInit = true;
            widgets[type](el);
        }
    });
    Object.values(features).forEach(fn => fn());
}

document.addEventListener('DOMContentLoaded', init);
