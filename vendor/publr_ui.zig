// Publr UI Amalgamation — generated from design-system/src/gen/components/*.zig
// Do not edit directly. Regenerate: ./scripts/amalgamate-design-system.sh

pub const runtime = struct {
const std = @import("std");

/// HTML-escape a string for safe output
pub fn escape(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Render an integer (no escaping needed)
pub fn renderInt(writer: anytype, value: anytype) !void {
    try writer.print("{d}", .{value});
}

/// Render a value based on its type
pub fn render(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);

    // Handle []const u8 (strings) directly
    if (T == []const u8) {
        try escape(writer, value);
        return;
    }

    // Handle *const [N]u8 (string literals)
    const info = @typeInfo(T);
    switch (info) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .pointer => |ptr| {
            // Check for pointer to u8 array (string literal type)
            const child_info = @typeInfo(ptr.child);
            if (child_info == .array and child_info.array.child == u8) {
                try escape(writer, value);
            } else if (ptr.size == .one) {
                try render(writer, value.*);
            } else {
                try writer.print("{s}", .{value});
            }
        },
        .@"enum" => try escape(writer, @tagName(value)),
        .@"fn" => {
            try value(writer);
            return;
        },
        .optional => {
            if (value) |v| {
                try render(writer, v);
            }
        },
        else => try writer.print("{any}", .{value}),
    }
}

};

pub const button = struct {

/// Button — primary action element.
///
/// Renders a `<button>` with Tailwind utility classes based on hierarchy, size,
/// and disabled state. Uses `data-publr-component="button"` for JS binding.
///
/// Hierarchy variants:
///   - primary: solid brand background, white text
///   - secondary: white background, gray text, border
///   - tertiary: transparent, gray text, hover background
///   - link: text-only brand color, no padding
///   - link_gray: text-only gray, no padding
///
/// Keyboard: standard `<button>` behavior (Enter/Space to activate).
/// No custom JS handler — purely CSS-driven.
///
/// Example:
///   <Button hierarchy=.primary size=.md label="Save changes" />
///   <Button hierarchy=.link disabled={true} label="Disabled" />
pub const Hierarchy = enum { primary, secondary, tertiary, link, link_gray };
pub const Size = enum { sm, md, lg, xl };
pub const Type = enum { button, submit, reset };
pub const Props = struct {
    label: []const u8 = "Button CTA",
    hierarchy: Hierarchy = .primary,
    size: Size = .md,
    disabled: bool = false,
    @"type": Type = .button,
};
pub fn Button(writer: anytype, comptime props: anytype) !void {
    const base = "inline-flex items-center justify-center font-semibold transition-colors";

    const is_link = props.hierarchy == .link or props.hierarchy == .link_gray;

    const size_classes = if (is_link) switch (props.size) {
        .sm, .md => "text-sm gap-xs",
        .lg, .xl => "text-md gap-sm",
    } else switch (props.size) {
        .sm => "px-3 py-2 text-sm gap-xs rounded-md",
        .md => "px-3.5 py-2.5 text-sm gap-xs rounded-md",
        .lg => "px-4 py-2.5 text-md gap-xs rounded-md",
        .xl => "px-[30px] py-3 text-lg gap-sm rounded-md",
    };

    const hierarchy_classes = if (props.disabled) switch (props.hierarchy) {
        .primary => "bg-gray-100 text-gray-400 shadow-xs cursor-not-allowed",
        .secondary => "bg-white text-gray-400 shadow-xs cursor-not-allowed",
        .tertiary, .link, .link_gray => "text-gray-300 cursor-not-allowed",
    } else switch (props.hierarchy) {
        .primary => "bg-brand-600 text-white shadow-btn-primary hover:bg-brand-700",
        .secondary => "bg-white text-gray-700 shadow-btn-secondary hover:bg-gray-50",
        .tertiary => "text-gray-600 hover:bg-gray-50 hover:text-gray-700",
        .link => "text-brand-700 hover:text-brand-800",
        .link_gray => "text-gray-600 hover:text-gray-700",
    };

    const focus = if (props.disabled) "" else "focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-brand-200 focus-visible:ring-offset-2";
    try writer.writeAll("<button data-publr-component=\"button\"");
    try writer.writeAll(" type=\"");
    try runtime.render(writer, props.@"type");
    try writer.writeAll("\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, base ++ " " ++ size_classes ++ " " ++ hierarchy_classes ++ " " ++ focus);
    try writer.writeAll("\"");
    try writer.writeAll(" disabled=\"");
    try runtime.render(writer, props.disabled);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try runtime.render(writer, props.label);
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
}

};

pub const dialog = struct {

/// Dialog — modal overlay with focus trap.
///
/// Renders a trigger button + overlay container. Clicking the trigger opens the
/// dialog. Uses `data-publr-component="dialog"` for JS initialization.
///
/// Data attributes:
///   - `data-publr-component="dialog"` — component identifier
///   - `data-publr-state="open|closed"` — current visibility state
///   - `data-publr-dismissable="true|false"` — whether overlay click/Escape closes
///   - `data-publr-part="trigger"` — the open button
///   - `data-publr-part="content"` — the overlay container
///   - `data-publr-part="close"` — the dismiss/cancel button
///
/// Keyboard:
///   - Enter/Space on trigger: opens dialog
///   - Tab: cycles through focusable elements (focus trap)
///   - Shift+Tab: reverse focus cycle
///   - Escape: closes dialog (if dismissable)
///
/// JS handler (publr-dialog.js):
///   - Focus trap: Tab wraps between first/last focusable elements
///   - Focus restore: returns focus to trigger on close
///   - Overlay dismiss: click outside content to close
///
/// Example:
///   <Dialog trigger_label="Delete" title="Confirm" body="Are you sure?" confirm_label="Delete" />
///   <Dialog trigger_label="Info" title="Notice" body="Read this." dismissable={false} />
pub const Props = struct {
    trigger_label: []const u8,
    title: []const u8,
    body: []const u8,
    dismiss_label: []const u8 = "Cancel",
    confirm_label: []const u8 = "",
    dismissable: bool = true,
};
pub fn Dialog(writer: anytype, comptime props: anytype) !void {
    try writer.writeAll("<div data-publr-component=\"dialog\" data-publr-state=\"closed\"");
    try writer.writeAll(" data-publr-dismissable=\"");
    try runtime.render(writer, if (props.dismissable) "true" else "false");
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"trigger\" aria-expanded=\"false\" class=\"inline-flex items-center justify-center px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-brand-500\">");
    try writer.writeAll("\n");
    try runtime.render(writer, props.trigger_label);
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    try writer.writeAll("<div data-publr-part=\"content\" class=\"fixed inset-0 z-50 flex items-center justify-center bg-black/50 opacity-0 pointer-events-none transition-opacity data-[publr-state=open]:opacity-100 data-[publr-state=open]:pointer-events-auto\" role=\"dialog\" aria-modal=\"true\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"bg-white rounded-xl p-6 max-w-md w-full mx-4 shadow-xl\">");
    try writer.writeAll("\n");
    try writer.writeAll("<h3 class=\"text-lg font-semibold text-gray-900\">");
    try runtime.render(writer, props.title);
    try writer.writeAll("</h3>");
    try writer.writeAll("\n");
    try writer.writeAll("<p class=\"mt-2 text-sm text-gray-600\">");
    try runtime.render(writer, props.body);
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"flex justify-end gap-3 mt-6\">");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"close\" class=\"px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50\">");
    try writer.writeAll("\n");
    try runtime.render(writer, props.dismiss_label);
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    if (props.confirm_label.len > 0) {
        try writer.writeAll("<button class=\"px-4 py-2 text-sm font-medium text-white bg-brand-600 rounded-md hover:bg-brand-700\">");
        try writer.writeAll("\n");
        try runtime.render(writer, props.confirm_label);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const css =
    \\*,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }::backdrop{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{border:0 solid #e9eaeb}:after,:before{--tw-content:""}:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:Geist,-apple-system,BlinkMacSystemFont,sans-serif;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}body{line-height:inherit}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}small{font-size:80%}sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:baseline}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}button,select{text-transform:none}button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:transparent;background-image:none}:-moz-focusring{outline:auto}:-moz-ui-invalid{box-shadow:none}progress{vertical-align:baseline}::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}[type=search]{-webkit-appearance:textfield;outline-offset:-2px}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}summary{display:list-item}blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}fieldset{margin:0}fieldset,legend{padding:0}menu,ol,ul{list-style:none;margin:0;padding:0}dialog{padding:0}textarea{resize:vertical}input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#a4a7ae}input::placeholder,textarea::placeholder{opacity:1;color:#a4a7ae}[role=button],button{cursor:pointer}:disabled{cursor:default}audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}img,video{max-width:100%;height:auto}[hidden]:where(:not([hidden=until-found])){display:none}*,:after,:before{box-sizing:border-box}body{margin:0;font-family:Geist,-apple-system,BlinkMacSystemFont,sans-serif;color:#181d27;background:#fafafa}.container{width:100%}@media (min-width:640px){.container{max-width:640px}}@media (min-width:768px){.container{max-width:768px}}@media (min-width:1024px){.container{max-width:1024px}}@media (min-width:1280px){.container{max-width:1280px}}@media (min-width:1536px){.container{max-width:1536px}}.pointer-events-none{pointer-events:none}.fixed{position:fixed}.absolute{position:absolute}.relative{position:relative}.inset-0{inset:0}.left-2\.5{left:.625rem}.top-1\/2{top:50%}.z-50{z-index:50}.m-0{margin:0}.mx-4{margin-left:1rem;margin-right:1rem}.ml-3{margin-left:.75rem}.mt-0\.5{margin-top:.125rem}.mt-2{margin-top:.5rem}.mt-6{margin-top:1.5rem}.block{display:block}.flex{display:flex}.inline-flex{display:inline-flex}.grid{display:grid}.hidden{display:none}.h-10{height:2.5rem}.h-12{height:3rem}.h-3{height:.75rem}.h-3\.5{height:.875rem}.h-5{height:1.25rem}.h-full{height:100%}.max-h-40{max-height:10rem}.w-2\/5{width:40%}.w-3{width:.75rem}.w-3\.5{width:.875rem}.w-5{width:1.25rem}.w-full{width:100%}.min-w-0{min-width:0}.max-w-md{max-width:28rem}.flex-1{flex:1 1 0%}.shrink-0{flex-shrink:0}.-translate-y-1\/2{--tw-translate-y:-50%;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}.cursor-not-allowed{cursor:not-allowed}.grid-cols-\[240px_1fr_320px\]{grid-template-columns:240px 1fr 320px}.grid-cols-\[repeat\(auto-fill\2c minmax\(200px\2c 1fr\)\)\]{grid-template-columns:repeat(auto-fill,minmax(200px,1fr))}.flex-col{flex-direction:column}.items-end{align-items:flex-end}.items-center{align-items:center}.justify-end{justify-content:flex-end}.justify-center{justify-content:center}.justify-between{justify-content:space-between}.gap-0\.5{gap:.125rem}.gap-2{gap:.5rem}.gap-3{gap:.75rem}.gap-5{gap:1.25rem}.gap-sm{gap:6px}.gap-xs{gap:4px}.divide-y>:not([hidden])~:not([hidden]){--tw-divide-y-reverse:0;border-top-width:calc(1px*(1 - var(--tw-divide-y-reverse)));border-bottom-width:calc(1px*var(--tw-divide-y-reverse))}.divide-gray-100>:not([hidden])~:not([hidden]){--tw-divide-opacity:1;border-color:rgb(245 245 245/var(--tw-divide-opacity,1))}.overflow-auto{overflow:auto}.overflow-hidden{overflow:hidden}.overflow-x-auto{overflow-x:auto}.overflow-y-auto{overflow-y:auto}.truncate{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.rounded{border-radius:.25rem}.rounded-md{border-radius:8px}.rounded-xl{border-radius:12px}.border{border-width:1px}.border-b{border-bottom-width:1px}.border-b-2{border-bottom-width:2px}.border-r{border-right-width:1px}.border-t{border-top-width:1px}.border-brand-600{--tw-border-opacity:1;border-color:rgb(2 162 255/var(--tw-border-opacity,1))}.border-gray-200{--tw-border-opacity:1;border-color:rgb(233 234 235/var(--tw-border-opacity,1))}.border-gray-300{--tw-border-opacity:1;border-color:rgb(213 215 218/var(--tw-border-opacity,1))}.border-gray-700{--tw-border-opacity:1;border-color:rgb(65 70 81/var(--tw-border-opacity,1))}.border-gray-800{--tw-border-opacity:1;border-color:rgb(37 43 55/var(--tw-border-opacity,1))}.bg-black\/50{background-color:rgba(0,0,0,.5)}.bg-brand-500{--tw-bg-opacity:1;background-color:rgb(18 173 255/var(--tw-bg-opacity,1))}.bg-brand-600{--tw-bg-opacity:1;background-color:rgb(2 162 255/var(--tw-bg-opacity,1))}.bg-gray-100{--tw-bg-opacity:1;background-color:rgb(245 245 245/var(--tw-bg-opacity,1))}.bg-gray-50{--tw-bg-opacity:1;background-color:rgb(250 250 250/var(--tw-bg-opacity,1))}.bg-gray-700{--tw-bg-opacity:1;background-color:rgb(65 70 81/var(--tw-bg-opacity,1))}.bg-gray-800{--tw-bg-opacity:1;background-color:rgb(37 43 55/var(--tw-bg-opacity,1))}.bg-gray-900{--tw-bg-opacity:1;background-color:rgb(24 29 39/var(--tw-bg-opacity,1))}.bg-gray-950{--tw-bg-opacity:1;background-color:rgb(10 13 18/var(--tw-bg-opacity,1))}.bg-white{--tw-bg-opacity:1;background-color:rgb(255 255 255/var(--tw-bg-opacity,1))}.p-3{padding:.75rem}.p-4{padding:1rem}.p-6{padding:1.5rem}.px-2{padding-left:.5rem;padding-right:.5rem}.px-2\.5{padding-left:.625rem;padding-right:.625rem}.px-3{padding-left:.75rem;padding-right:.75rem}.px-3\.5{padding-left:.875rem;padding-right:.875rem}.px-4{padding-left:1rem;padding-right:1rem}.px-\[18px\]{padding-left:18px;padding-right:18px}.py-1{padding-top:.25rem;padding-bottom:.25rem}.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}.py-2{padding-top:.5rem;padding-bottom:.5rem}.py-2\.5{padding-top:.625rem;padding-bottom:.625rem}.py-3{padding-top:.75rem;padding-bottom:.75rem}.pb-2{padding-bottom:.5rem}.pb-4{padding-bottom:1rem}.pl-8{padding-left:2rem}.pr-3{padding-right:.75rem}.text-\[10px\]{font-size:10px}.text-lg{font-size:1.125rem;line-height:1.75rem}.text-md{font-size:1rem;line-height:1.5rem}.text-sm{font-size:.875rem;line-height:1.25rem}.text-xs{font-size:.75rem;line-height:1.125rem}.font-medium{font-weight:500}.font-semibold{font-weight:600}.uppercase{text-transform:uppercase}.leading-relaxed{line-height:1.625}.tracking-tight{letter-spacing:-.025em}.tracking-wider{letter-spacing:.05em}.text-brand-600{--tw-text-opacity:1;color:rgb(2 162 255/var(--tw-text-opacity,1))}.text-brand-700{--tw-text-opacity:1;color:rgb(0 136 214/var(--tw-text-opacity,1))}.text-gray-300{--tw-text-opacity:1;color:rgb(213 215 218/var(--tw-text-opacity,1))}.text-gray-400{--tw-text-opacity:1;color:rgb(164 167 174/var(--tw-text-opacity,1))}.text-gray-500{--tw-text-opacity:1;color:rgb(113 118 128/var(--tw-text-opacity,1))}.text-gray-600{--tw-text-opacity:1;color:rgb(83 88 98/var(--tw-text-opacity,1))}.text-gray-700{--tw-text-opacity:1;color:rgb(65 70 81/var(--tw-text-opacity,1))}.text-gray-900{--tw-text-opacity:1;color:rgb(24 29 39/var(--tw-text-opacity,1))}.text-white{--tw-text-opacity:1;color:rgb(255 255 255/var(--tw-text-opacity,1))}.placeholder-gray-500::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(113 118 128/var(--tw-placeholder-opacity,1))}.placeholder-gray-500::placeholder{--tw-placeholder-opacity:1;color:rgb(113 118 128/var(--tw-placeholder-opacity,1))}.opacity-0{opacity:0}.shadow-btn-primary{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05),inset 0 0 0 1px rgba(10,13,18,.18),inset 0 -2px 0 0 rgba(10,13,18,.05),inset 0 0 0 2px hsla(0,0%,100%,.12);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color),inset 0 0 0 1px var(--tw-shadow-color),inset 0 -2px 0 0 var(--tw-shadow-color),inset 0 0 0 2px var(--tw-shadow-color)}.shadow-btn-primary,.shadow-btn-secondary{box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.shadow-btn-secondary{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05),inset 0 0 0 1px #d5d7da,inset 0 -2px 0 0 rgba(10,13,18,.05);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color),inset 0 0 0 1px var(--tw-shadow-color),inset 0 -2px 0 0 var(--tw-shadow-color)}.shadow-xl{--tw-shadow:0 20px 25px -5px rgba(0,0,0,.1),0 8px 10px -6px rgba(0,0,0,.1);--tw-shadow-colored:0 20px 25px -5px var(--tw-shadow-color),0 8px 10px -6px var(--tw-shadow-color)}.shadow-xl,.shadow-xs{box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.shadow-xs{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color)}.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}.transition-colors{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.transition-opacity{transition-property:opacity;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.hover\:bg-brand-700:hover{--tw-bg-opacity:1;background-color:rgb(0 136 214/var(--tw-bg-opacity,1))}.hover\:bg-gray-50:hover{--tw-bg-opacity:1;background-color:rgb(250 250 250/var(--tw-bg-opacity,1))}.hover\:bg-gray-700:hover{--tw-bg-opacity:1;background-color:rgb(65 70 81/var(--tw-bg-opacity,1))}.hover\:text-brand-800:hover{--tw-text-opacity:1;color:rgb(0 105 166/var(--tw-text-opacity,1))}.hover\:text-gray-700:hover{--tw-text-opacity:1;color:rgb(65 70 81/var(--tw-text-opacity,1))}.hover\:text-white:hover{--tw-text-opacity:1;color:rgb(255 255 255/var(--tw-text-opacity,1))}.focus\:border-brand-500:focus{--tw-border-opacity:1;border-color:rgb(18 173 255/var(--tw-border-opacity,1))}.focus\:outline-none:focus{outline:2px solid transparent;outline-offset:2px}.focus\:ring-1:focus{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color)}.focus\:ring-1:focus,.focus\:ring-2:focus{box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000)}.focus\:ring-2:focus{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color)}.focus\:ring-brand-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(18 173 255/var(--tw-ring-opacity,1))}.focus\:ring-offset-2:focus{--tw-ring-offset-width:2px}.focus-visible\:outline-none:focus-visible{outline:2px solid transparent;outline-offset:2px}.focus-visible\:ring-4:focus-visible{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(4px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000)}.focus-visible\:ring-brand-200:focus-visible{--tw-ring-opacity:1;--tw-ring-color:rgb(153 221 255/var(--tw-ring-opacity,1))}.focus-visible\:ring-offset-2:focus-visible{--tw-ring-offset-width:2px}.data-\[publr-state\=open\]\:pointer-events-auto[data-publr-state=open]{pointer-events:auto}.data-\[publr-state\=open\]\:opacity-100[data-publr-state=open]{opacity:1}
    \\
;

pub const core_js =
    \\// Publr Interactivity — Core
    \\// Registry, init, toggle state, toggle handler, autodetection
    \\
    \\const handlers = new Map();
    \\
    \\// ── Registry ────────────────────────────────────────
    \\
    \\export function register(name, handler) {
    \\  handlers.set(name, handler);
    \\}
    \\
    \\export function init(root = document) {
    \\  root.querySelectorAll('[data-publr-component]').forEach((el) => {
    \\    const name = el.dataset.publrComponent;
    \\    const handler = handlers.get(name);
    \\    if (handler && !el._publrInit) {
    \\      el._publrInit = true;
    \\      handler(el);
    \\    }
    \\  });
    \\}
    \\
    \\// Re-init on dynamic content (for HTMX, etc.)
    \\document.addEventListener('publr:init', (e) => init(e.target));
    \\
    \\// ── Toggle State ────────────────────────────────────
    \\
    \\export function isOpen(el) {
    \\  return el.dataset.publrState === 'open';
    \\}
    \\
    \\export function open(el) {
    \\  el.dataset.publrState = 'open';
    \\  const trigger = el.querySelector('[data-publr-part="trigger"]');
    \\  if (trigger) trigger.setAttribute('aria-expanded', 'true');
    \\}
    \\
    \\export function close(el) {
    \\  el.dataset.publrState = 'closed';
    \\  const trigger = el.querySelector('[data-publr-part="trigger"]');
    \\  if (trigger) trigger.setAttribute('aria-expanded', 'false');
    \\  if (el._publrOnClose) {
    \\    el._publrOnClose();
    \\    delete el._publrOnClose;
    \\  }
    \\}
    \\
    \\export function toggle(el) {
    \\  if (isOpen(el)) {
    \\    close(el);
    \\  } else {
    \\    open(el);
    \\  }
    \\}
    \\
    \\// ── Toggle Handler ──────────────────────────────────
    \\
    \\register('toggle', (el) => {
    \\  const trigger = el.querySelector('[data-publr-part="trigger"]');
    \\  if (!trigger) return;
    \\  trigger.addEventListener('click', () => toggle(el));
    \\});
    \\
    \\// ── Autodetection ───────────────────────────────────
    \\
    \\function autodetect() {
    \\  document.querySelectorAll('[data-publr-component]').forEach((el) => {
    \\    const name = el.dataset.publrComponent;
    \\    if (!handlers.has(name)) {
    \\      import(`./publr-${name}.js`).catch(() => {});
    \\    }
    \\  });
    \\  init();
    \\}
    \\
    \\if (document.readyState === 'loading') {
    \\  document.addEventListener('DOMContentLoaded', autodetect);
    \\} else {
    \\  autodetect();
    \\}
    \\
;

pub const dialog_js =
    \\// Publr Interactivity — Dialog
    \\// Focus trap + dialog handler
    \\
    \\import { register, init, open, close } from './publr-core.js';
    \\
    \\// ── Focus Trap ──────────────────────────────────────
    \\
    \\const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    \\
    \\function trapFocus(container) {
    \\  const focusable = container.querySelectorAll(FOCUSABLE);
    \\  if (!focusable.length) return;
    \\
    \\  const first = focusable[0];
    \\  const last = focusable[focusable.length - 1];
    \\
    \\  container._publrPrevFocus = document.activeElement;
    \\  first.focus();
    \\
    \\  container._publrTrapHandler = (e) => {
    \\    if (e.key !== 'Tab') return;
    \\
    \\    if (e.shiftKey && document.activeElement === first) {
    \\      e.preventDefault();
    \\      last.focus();
    \\    } else if (!e.shiftKey && document.activeElement === last) {
    \\      e.preventDefault();
    \\      first.focus();
    \\    }
    \\  };
    \\
    \\  container.addEventListener('keydown', container._publrTrapHandler);
    \\}
    \\
    \\function releaseFocus(container) {
    \\  if (container._publrTrapHandler) {
    \\    container.removeEventListener('keydown', container._publrTrapHandler);
    \\    delete container._publrTrapHandler;
    \\  }
    \\  if (container._publrPrevFocus) {
    \\    container._publrPrevFocus.focus();
    \\    delete container._publrPrevFocus;
    \\  }
    \\}
    \\
    \\// ── Dialog Handler ──────────────────────────────────
    \\
    \\register('dialog', (el) => {
    \\  const trigger = el.querySelector('[data-publr-part="trigger"]');
    \\  const content = el.querySelector('[data-publr-part="content"]');
    \\  const closeBtn = el.querySelector('[data-publr-part="close"]');
    \\  if (!trigger || !content) return;
    \\
    \\  trigger.addEventListener('click', () => {
    \\    open(el);
    \\    trapFocus(content);
    \\    el._publrOnClose = () => {
    \\      releaseFocus(content);
    \\      trigger.focus();
    \\    };
    \\  });
    \\
    \\  if (closeBtn) {
    \\    closeBtn.addEventListener('click', () => close(el));
    \\  }
    \\
    \\  // Overlay click (only if dismissable)
    \\  content.addEventListener('click', (e) => {
    \\    if (e.target === content && el.dataset.publrDismissable !== 'false') {
    \\      close(el);
    \\    }
    \\  });
    \\
    \\  // Escape key
    \\  content.addEventListener('keydown', (e) => {
    \\    if (e.key === 'Escape' && el.dataset.publrDismissable !== 'false') {
    \\      close(el);
    \\    }
    \\  });
    \\});
    \\
    \\init();
    \\
;

pub const dropdown_js =
    \\// Publr Interactivity — Dropdown
    \\// Portal + dropdown handler
    \\
    \\import { register, init, open, close, isOpen } from './publr-core.js';
    \\
    \\// ── Portal ──────────────────────────────────────────
    \\
    \\let portalRoot = null;
    \\
    \\function getPortalRoot() {
    \\  if (!portalRoot) {
    \\    portalRoot = document.createElement('div');
    \\    portalRoot.id = 'publr-portal';
    \\    portalRoot.style.cssText = 'position:fixed;top:0;left:0;z-index:9999;pointer-events:none;';
    \\    document.body.appendChild(portalRoot);
    \\  }
    \\  return portalRoot;
    \\}
    \\
    \\function portal(el) {
    \\  el._publrOriginalParent = el.parentNode;
    \\  el._publrOriginalNext = el.nextSibling;
    \\  el.style.pointerEvents = 'auto';
    \\  getPortalRoot().appendChild(el);
    \\}
    \\
    \\function unportal(el) {
    \\  if (el._publrOriginalParent) {
    \\    el._publrOriginalParent.insertBefore(el, el._publrOriginalNext);
    \\    delete el._publrOriginalParent;
    \\    delete el._publrOriginalNext;
    \\    el.style.pointerEvents = '';
    \\  }
    \\}
    \\
    \\function position(el, anchor, opts = {}) {
    \\  const rect = anchor.getBoundingClientRect();
    \\  const placement = opts.placement || 'bottom-start';
    \\
    \\  el.style.position = 'fixed';
    \\
    \\  if (placement.startsWith('bottom')) {
    \\    el.style.top = `${rect.bottom + 4}px`;
    \\    el.style.left = `${rect.left}px`;
    \\  } else if (placement.startsWith('top')) {
    \\    el.style.bottom = `${window.innerHeight - rect.top + 4}px`;
    \\    el.style.left = `${rect.left}px`;
    \\  }
    \\}
    \\
    \\// ── Dropdown Handler ────────────────────────────────
    \\
    \\register('dropdown', (el) => {
    \\  const trigger = el.querySelector('[data-publr-part="trigger"]');
    \\  const content = el.querySelector('[data-publr-part="content"]');
    \\  if (!trigger || !content) return;
    \\
    \\  trigger.addEventListener('click', () => {
    \\    if (isOpen(el)) {
    \\      close(el);
    \\    } else {
    \\      open(el);
    \\      portal(content);
    \\      position(content, trigger);
    \\      el._publrOnClose = () => unportal(content);
    \\    }
    \\  });
    \\});
    \\
    \\init();
    \\
;

