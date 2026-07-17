// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — built by Vite from publr-js/src/ (TypeScript).
// DO NOT EDIT. Edit publr-js/src/**, run `npm run build`, then re-vendor
// consumers via scripts/vendor-publr.sh.
// ─────────────────────────────────────────────────────────────────────────────
//#region src/addons/position.ts
var PLACEMENTS = {
	"top-start": {
		primary: "top",
		align: "start"
	},
	top: {
		primary: "top",
		align: "center"
	},
	"top-end": {
		primary: "top",
		align: "end"
	},
	"bottom-start": {
		primary: "bottom",
		align: "start"
	},
	bottom: {
		primary: "bottom",
		align: "center"
	},
	"bottom-end": {
		primary: "bottom",
		align: "end"
	},
	"left-start": {
		primary: "left",
		align: "start"
	},
	left: {
		primary: "left",
		align: "center"
	},
	"left-end": {
		primary: "left",
		align: "end"
	},
	"right-start": {
		primary: "right",
		align: "start"
	},
	right: {
		primary: "right",
		align: "center"
	},
	"right-end": {
		primary: "right",
		align: "end"
	}
};
var FLIP = {
	top: "bottom",
	bottom: "top",
	left: "right",
	right: "left"
};
function computeCoords(anchorRect, floatingRect, primary, align, offset) {
	let top;
	let left;
	if (primary === "bottom") top = anchorRect.bottom + offset;
	else if (primary === "top") top = anchorRect.top - floatingRect.height - offset;
	else if (primary === "left") left = anchorRect.left - floatingRect.width - offset;
	else left = anchorRect.right + offset;
	if (primary === "top" || primary === "bottom") if (align === "start") left = anchorRect.left;
	else if (align === "end") left = anchorRect.right - floatingRect.width;
	else left = anchorRect.left + (anchorRect.width - floatingRect.width) / 2;
	else if (align === "start") top = anchorRect.top;
	else if (align === "end") top = anchorRect.bottom - floatingRect.height;
	else top = anchorRect.top + (anchorRect.height - floatingRect.height) / 2;
	return {
		top,
		left
	};
}
function overflows(coords, floatingRect) {
	return coords.top < 0 || coords.left < 0 || coords.top + floatingRect.height > window.innerHeight || coords.left + floatingRect.width > window.innerWidth;
}
function position(floating, anchor, opts = {}) {
	const placement = opts.placement || "bottom-start";
	const offset = opts.offset ?? 4;
	const flip = opts.flip !== false;
	const parsed = PLACEMENTS[placement] || PLACEMENTS["bottom-start"];
	const anchorRect = anchor.getBoundingClientRect();
	floating.style.position = "fixed";
	floating.style.visibility = "hidden";
	floating.style.top = "0";
	floating.style.left = "0";
	const floatingRect = floating.getBoundingClientRect();
	floating.style.visibility = "";
	let { primary, align } = parsed;
	let coords = computeCoords(anchorRect, floatingRect, primary, align, offset);
	if (flip && overflows(coords, floatingRect)) {
		const flipped = FLIP[primary];
		const flippedCoords = computeCoords(anchorRect, floatingRect, flipped, align, offset);
		if (!overflows(flippedCoords, floatingRect)) {
			primary = flipped;
			coords = flippedCoords;
		}
	}
	floating.style.top = `${coords.top}px`;
	floating.style.left = `${coords.left}px`;
	return align === "center" ? primary : `${primary}-${align}`;
}
//#endregion
export { position };
