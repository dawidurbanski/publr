// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — built by Vite from publr-js/src/ (TypeScript).
// DO NOT EDIT. Edit publr-js/src/**, run `npm run build`, then re-vendor
// consumers via scripts/vendor-publr.sh.
// ─────────────────────────────────────────────────────────────────────────────
//#region src/addons/focus.ts
var FOCUSABLE = "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex=\"-1\"])";
function trapFocus(container, opts = {}) {
	const focusable = () => container.querySelectorAll(FOCUSABLE);
	const items = focusable();
	if (!items.length) return () => {};
	const prevFocus = document.activeElement;
	if (opts.initialFocus) opts.initialFocus.focus();
	else items[0].focus();
	function handler(e) {
		if (e.key !== "Tab") return;
		const els = focusable();
		if (!els.length) return;
		const first = els[0];
		const last = els[els.length - 1];
		if (e.shiftKey && document.activeElement === first) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && document.activeElement === last) {
			e.preventDefault();
			first.focus();
		}
	}
	container.addEventListener("keydown", handler);
	return function release() {
		container.removeEventListener("keydown", handler);
		if (prevFocus && prevFocus.focus) prevFocus.focus();
	};
}
//#endregion
export { trapFocus };
