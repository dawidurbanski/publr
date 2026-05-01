// Publr UI Amalgamation — generated from design-system/src/gen/components/*.zig
// Do not edit directly. Regenerate: ./scripts/amalgamate-design-system.sh

// Self-reference for cross-component imports within the amalgamation.
const root = @This();

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

/// Compute return type for withDefaults: if all Defaults fields exist in Raw,
/// return Raw directly (preserving original types); otherwise return Defaults.
fn WithDefaultsReturn(comptime Defaults: type, comptime Raw: type) type {
    for (@typeInfo(Defaults).@"struct".fields) |field| {
        if (!@hasField(Raw, field.name)) return Defaults;
    }
    return Raw;
}

/// Merge props with defaults: fields present in raw are used as-is,
/// missing fields get their default values from the Defaults type.
/// When all fields are present, returns raw directly (no type coercion).
pub fn withDefaults(comptime Defaults: type, raw: anytype) WithDefaultsReturn(Defaults, @TypeOf(raw)) {
    const needs_defaults = comptime needs: {
        for (@typeInfo(Defaults).@"struct".fields) |field| {
            if (!@hasField(@TypeOf(raw), field.name)) break :needs true;
        }
        break :needs false;
    };

    if (needs_defaults) {
        var result: Defaults = undefined;
        inline for (@typeInfo(Defaults).@"struct".fields) |field| {
            if (@hasField(@TypeOf(raw), field.name)) {
                @field(result, field.name) = @field(raw, field.name);
            } else {
                @field(result, field.name) = field.defaultValue().?;
            }
        }
        return result;
    } else {
        return raw;
    }
}

};

pub const icons_data = struct {

pub const Name = enum { alert_hexagon, alert_triangle, arrow_left, bookmark, chart, check, chevron_down, chevron_left, chevron_right, chevron_up, components, copy, dot_filled, dot_half, dot_outline, edit, file, folder_plus, folder, grid, home, image, list, lock, logout, more, package, plus_circle, plus, search, settings, sync, tag, trash, upload, user, users, x_close };

pub const alert_hexagon: []const u8 =
    \\<path d="M12 8.00008V12.0001M12 16.0001H12.01M3 7.94153V16.0586C3 16.4013 3 16.5726 3.05048 16.7254C3.09515 16.8606 3.16816 16.9847 3.26463 17.0893C3.37369 17.2077 3.52345 17.2909 3.82297 17.4573L11.223 21.5684C11.5066 21.726 11.6484 21.8047 11.7985 21.8356C11.9315 21.863 12.0685 21.863 12.2015 21.8356C12.3516 21.8047 12.4934 21.726 12.777 21.5684L20.177 17.4573C20.4766 17.2909 20.6263 17.2077 20.7354 17.0893C20.8318 16.9847 20.9049 16.8606 20.9495 16.7254C21 16.5726 21 16.4013 21 16.0586V7.94153C21 7.59889 21 7.42756 20.9495 7.27477C20.9049 7.13959 20.8318 7.01551 20.7354 6.91082C20.6263 6.79248 20.4766 6.70928 20.177 6.54288L12.777 2.43177C12.4934 2.27421 12.3516 2.19543 12.2015 2.16454C12.0685 2.13721 11.9315 2.13721 11.7985 2.16454C11.6484 2.19543 11.5066 2.27421 11.223 2.43177L3.82297 6.54288C3.52345 6.70928 3.37369 6.79248 3.26463 6.91082C3.16816 7.01551 3.09515 7.13959 3.05048 7.27477C3 7.42756 3 7.59889 3 7.94153Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const alert_triangle: []const u8 =
    \\<path d="M11.9998 8.99999V13M11.9998 17H12.0098M10.6151 3.89171L2.39019 18.0983C1.93398 18.8863 1.70588 19.2803 1.73959 19.6037C1.769 19.8857 1.91677 20.142 2.14613 20.3088C2.40908 20.5 2.86435 20.5 3.77487 20.5H20.2246C21.1352 20.5 21.5904 20.5 21.8534 20.3088C22.0827 20.142 22.2305 19.8857 22.2599 19.6037C22.2936 19.2803 22.0655 18.8863 21.6093 18.0983L13.3844 3.89171C12.9299 3.10654 12.7026 2.71396 12.4061 2.58211C12.1474 2.4671 11.8521 2.4671 11.5935 2.58211C11.2969 2.71396 11.0696 3.10655 10.6151 3.89171Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const arrow_left: []const u8 =
    \\<path d="M19 12H5M5 12L12 19M5 12L12 5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const bookmark: []const u8 =
    \\<path d="M5 7.8C5 6.11984 5 5.27976 5.32698 4.63803C5.6146 4.07354 6.07354 3.6146 6.63803 3.32698C7.27976 3 8.11984 3 9.8 3H14.2C15.8802 3 16.7202 3 17.362 3.32698C17.9265 3.6146 18.3854 4.07354 18.673 4.63803C19 5.27976 19 6.11984 19 7.8V21L12 17L5 21V7.8Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chart: []const u8 =
    \\<path d="M21 21H4.6C4.03995 21 3.75992 21 3.54601 20.891C3.35785 20.7951 3.20487 20.6422 3.10899 20.454C3 20.2401 3 19.9601 3 19.4V3M21 7L15.5657 12.4343C15.3677 12.6323 15.2687 12.7313 15.1545 12.7684C15.0541 12.8011 14.9459 12.8011 14.8455 12.7684C14.7313 12.7313 14.6323 12.6323 14.4343 12.4343L12.5657 10.5657C12.3677 10.3677 12.2687 10.2687 12.1545 10.2316C12.0541 10.1989 11.9459 10.1989 11.8455 10.2316C11.7313 10.2687 11.6323 10.3677 11.4343 10.5657L7 15M21 7H17M21 7V11" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const check: []const u8 =
    \\<path d="M20 6L9 17L4 12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_down: []const u8 =
    \\<path d="M6 9L12 15L18 9" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_left: []const u8 =
    \\<path d="M15 18L9 12L15 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_right: []const u8 =
    \\<path d="M9 18L15 12L9 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const chevron_up: []const u8 =
    \\<path d="M18 15L12 9L6 15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const components: []const u8 =
    \\<path d="M15.0505 9H5.5C4.11929 9 3 7.88071 3 6.5C3 5.11929 4.11929 4 5.5 4H15.0505M8.94949 20H18.5C19.8807 20 21 18.8807 21 17.5C21 16.1193 19.8807 15 18.5 15H8.94949M3 17.5C3 19.433 4.567 21 6.5 21C8.433 21 10 19.433 10 17.5C10 15.567 8.433 14 6.5 14C4.567 14 3 15.567 3 17.5ZM21 6.5C21 8.433 19.433 10 17.5 10C15.567 10 14 8.433 14 6.5C14 4.567 15.567 3 17.5 3C19.433 3 21 4.567 21 6.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const copy: []const u8 =
    \\<path d="M7.5 3H14.6C16.8402 3 17.9603 3 18.816 3.43597C19.5686 3.81947 20.1805 4.43139 20.564 5.18404C21 6.03969 21 7.15979 21 9.4V16.5M6.2 21H14.3C15.4201 21 15.9802 21 16.408 20.782C16.7843 20.5903 17.0903 20.2843 17.282 19.908C17.5 19.4802 17.5 18.9201 17.5 17.8V9.7C17.5 8.57989 17.5 8.01984 17.282 7.59202C17.0903 7.21569 16.7843 6.90973 16.408 6.71799C15.9802 6.5 15.4201 6.5 14.3 6.5H6.2C5.0799 6.5 4.51984 6.5 4.09202 6.71799C3.71569 6.90973 3.40973 7.21569 3.21799 7.59202C3 8.01984 3 8.57989 3 9.7V17.8C3 18.9201 3 19.4802 3.21799 19.908C3.40973 20.2843 3.71569 20.5903 4.09202 20.782C4.51984 21 5.0799 21 6.2 21Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const dot_filled: []const u8 =
    \\<circle cx="12" cy="12" r="6"/>
;

pub const dot_half: []const u8 =
    \\<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>
    \\<path d="M12 7a5 5 0 010 10V7z" fill="currentColor"/>
;

pub const dot_outline: []const u8 =
    \\<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>
;

pub const edit: []const u8 =
    \\<path d="M2.87601 18.1156C2.92195 17.7021 2.94493 17.4954 3.00748 17.3022C3.06298 17.1307 3.1414 16.9676 3.24061 16.8171C3.35242 16.6475 3.49952 16.5005 3.7937 16.2063L17 3C18.1046 1.89543 19.8954 1.89543 21 3C22.1046 4.10457 22.1046 5.89543 21 7L7.7937 20.2063C7.49951 20.5005 7.35242 20.6475 7.18286 20.7594C7.03242 20.8586 6.86926 20.937 6.69782 20.9925C6.50457 21.055 6.29783 21.078 5.88434 21.124L2.49997 21.5L2.87601 18.1156Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const file: []const u8 =
    \\<path d="M14 2.26946V6.4C14 6.96005 14 7.24008 14.109 7.45399C14.2049 7.64215 14.3578 7.79513 14.546 7.89101C14.7599 8 15.0399 8 15.6 8H19.7305M20 9.98822V17.2C20 18.8802 20 19.7202 19.673 20.362C19.3854 20.9265 18.9265 21.3854 18.362 21.673C17.7202 22 16.8802 22 15.2 22H8.8C7.11984 22 6.27976 22 5.63803 21.673C5.07354 21.3854 4.6146 20.9265 4.32698 20.362C4 19.7202 4 18.8802 4 17.2V6.8C4 5.11984 4 4.27976 4.32698 3.63803C4.6146 3.07354 5.07354 2.6146 5.63803 2.32698C6.27976 2 7.11984 2 8.8 2H12.0118C12.7455 2 13.1124 2 13.4577 2.08289C13.7638 2.15638 14.0564 2.27759 14.3249 2.44208C14.6276 2.6276 14.887 2.88703 15.4059 3.40589L18.5941 6.59411C19.113 7.11297 19.3724 7.3724 19.5579 7.67515C19.7224 7.94356 19.8436 8.2362 19.9171 8.5423C20 8.88757 20 9.25445 20 9.98822Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const folder_plus: []const u8 =
    \\<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7ZM12 17V11M9 14H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const folder: []const u8 =
    \\<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const grid: []const u8 =
    \\<path d="M3 3H10V10H3V3ZM14 3H21V10H14V3ZM14 14H21V21H14V14ZM3 14H10V21H3V14Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const home: []const u8 =
    \\<path d="M3 10.5651C3 9.9907 3 9.70352 3.07403 9.43905C3.1396 9.20478 3.24737 8.98444 3.39203 8.78886C3.55534 8.56806 3.78202 8.39175 4.23539 8.03912L11.0177 2.764C11.369 2.49075 11.5447 2.35412 11.7387 2.3016C11.9098 2.25526 12.0902 2.25526 12.2613 2.3016C12.4553 2.35412 12.631 2.49075 12.9823 2.764L19.7646 8.03913C20.218 8.39175 20.4447 8.56806 20.608 8.78886C20.7526 8.98444 20.8604 9.20478 20.926 9.43905C21 9.70352 21 9.9907 21 10.5651V17.8C21 18.9201 21 19.4801 20.782 19.908C20.5903 20.2843 20.2843 20.5903 19.908 20.782C19.4802 21 18.9201 21 17.8 21H6.2C5.07989 21 4.51984 21 4.09202 20.782C3.71569 20.5903 3.40973 20.2843 3.21799 19.908C3 19.4801 3 18.9201 3 17.8V10.5651Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const image: []const u8 =
    \\<path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const list: []const u8 =
    \\<path d="M21 12L9 12M21 6L9 6M21 18L9 18M5 12C5 12.5523 4.55228 13 4 13C3.44772 13 3 12.5523 3 12C3 11.4477 3.44772 11 4 11C4.55228 11 5 11.4477 5 12ZM5 6C5 6.55228 4.55228 7 4 7C3.44772 7 3 6.55228 3 6C3 5.44772 3.44772 5 4 5C4.55228 5 5 5.44772 5 6ZM5 18C5 18.5523 4.55228 19 4 19C3.44772 19 3 18.5523 3 18C3 17.4477 3.44772 17 4 17C4.55228 17 5 17.4477 5 18Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const lock: []const u8 =
    \\<path d="M17 11V8C17 5.23858 14.7614 3 12 3C9.23858 3 7 5.23858 7 8V11M12 14.5V16.5M9.8 21H14.2C15.8802 21 16.7202 21 17.362 20.673C17.9265 20.3854 18.3854 19.9265 18.673 19.362C19 18.7202 19 17.8802 19 16.2V15.8C19 14.1198 19 13.2798 18.673 12.638C18.3854 12.0735 17.9265 11.6146 17.362 11.327C16.7202 11 15.8802 11 14.2 11H9.8C8.11984 11 7.27976 11 6.63803 11.327C6.07354 11.6146 5.6146 12.0735 5.32698 12.638C5 13.2798 5 14.1198 5 15.8V16.2C5 17.8802 5 18.7202 5.32698 19.362C5.6146 19.9265 6.07354 20.3854 6.63803 20.673C7.27976 21 8.11984 21 9.8 21Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const logout: []const u8 =
    \\<path d="M16 17L21 12M21 12L16 7M21 12H9M9 3H7.8C6.11984 3 5.27976 3 4.63803 3.32698C4.07354 3.6146 3.6146 4.07354 3.32698 4.63803C3 5.27976 3 6.11984 3 7.8V16.2C3 17.8802 3 18.7202 3.32698 19.362C3.6146 19.9265 4.07354 20.3854 4.63803 20.673C5.27976 21 6.11984 21 7.8 21H9" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const more: []const u8 =
    \\<path d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 6C12.5523 6 13 5.55228 13 5C13 4.44772 12.5523 4 12 4C11.4477 4 11 4.44772 11 5C11 5.55228 11.4477 6 12 6Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 20C12.5523 20 13 19.5523 13 19C13 18.4477 12.5523 18 12 18C11.4477 18 11 18.4477 11 19C11 19.5523 11.4477 20 12 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const package: []const u8 =
    \\<path d="M16.5 9.4L7.5 4.21M21 16V8C20.9996 7.6493 20.9071 7.30483 20.7315 7.00017C20.556 6.69552 20.3037 6.44136 20 6.264L13 2.264C12.696 2.08669 12.3511 1.99377 12 1.99377C11.6489 1.99377 11.304 2.08669 11 2.264L4 6.264C3.69626 6.44136 3.44398 6.69552 3.26846 7.00017C3.09294 7.30483 3.00036 7.6493 3 8V16C3.00036 16.3507 3.09294 16.6952 3.26846 16.9998C3.44398 17.3045 3.69626 17.5586 4 17.736L11 21.736C11.304 21.9133 11.6489 22.0062 12 22.0062C12.3511 22.0062 12.696 21.9133 13 21.736L20 17.736C20.3037 17.5586 20.556 17.3045 20.7315 16.9998C20.9071 16.6952 20.9996 16.3507 21 16Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M3.27002 6.96L12 12.01L20.73 6.96M12 22.08V12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const plus_circle: []const u8 =
    \\<path d="M12 8V16M8 12H16M22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.47715 2 12 2C17.5228 2 22 6.47715 22 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const plus: []const u8 =
    \\<path d="M12 5V19M5 12H19" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const search: []const u8 =
    \\<path d="M21 21L17.5001 17.5M20 11.5C20 16.1944 16.1944 20 11.5 20C6.80558 20 3 16.1944 3 11.5C3 6.80558 6.80558 3 11.5 3C16.1944 3 20 6.80558 20 11.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const settings: []const u8 =
    \\<path d="M9.3951 19.3711L9.97955 20.6856C10.1533 21.0768 10.4368 21.4093 10.7958 21.6426C11.1547 21.8759 11.5737 22.0001 12.0018 22C12.4299 22.0001 12.8488 21.8759 13.2078 21.6426C13.5667 21.4093 13.8503 21.0768 14.024 20.6856L14.6084 19.3711C14.8165 18.9047 15.1664 18.5159 15.6084 18.26C16.0532 18.0034 16.5678 17.8941 17.0784 17.9478L18.5084 18.1C18.9341 18.145 19.3637 18.0656 19.7451 17.8713C20.1265 17.6771 20.4434 17.3763 20.6573 17.0056C20.8715 16.635 20.9735 16.2103 20.9511 15.7829C20.9286 15.3555 20.7825 14.9438 20.5307 14.5978L19.684 13.4344C19.3825 13.0171 19.2214 12.5148 19.224 12C19.2239 11.4866 19.3865 10.9864 19.6884 10.5711L20.5351 9.40778C20.787 9.06175 20.933 8.65007 20.9555 8.22267C20.978 7.79528 20.8759 7.37054 20.6618 7C20.4479 6.62923 20.131 6.32849 19.7496 6.13423C19.3681 5.93997 18.9386 5.86053 18.5129 5.90556L17.0829 6.05778C16.5722 6.11141 16.0577 6.00212 15.6129 5.74556C15.17 5.48825 14.82 5.09736 14.6129 4.62889L14.024 3.31444C13.8503 2.92317 13.5667 2.59072 13.2078 2.3574C12.8488 2.12408 12.4299 1.99993 12.0018 2C11.5737 1.99993 11.1547 2.12408 10.7958 2.3574C10.4368 2.59072 10.1533 2.92317 9.97955 3.31444L9.3951 4.62889C9.18803 5.09736 8.83798 5.48825 8.3951 5.74556C7.95032 6.00212 7.43577 6.11141 6.9251 6.05778L5.49066 5.90556C5.06499 5.86053 4.6354 5.93997 4.25397 6.13423C3.87255 6.32849 3.55567 6.62923 3.34177 7C3.12759 7.37054 3.02555 7.79528 3.04804 8.22267C3.07052 8.65007 3.21656 9.06175 3.46844 9.40778L4.3151 10.5711C4.61704 10.9864 4.77964 11.4866 4.77955 12C4.77964 12.5134 4.61704 13.0137 4.3151 13.4289L3.46844 14.5922C3.21656 14.9382 3.07052 15.3499 3.04804 15.7773C3.02555 16.2047 3.12759 16.6295 3.34177 17C3.55589 17.3706 3.8728 17.6712 4.25417 17.8654C4.63554 18.0596 5.06502 18.1392 5.49066 18.0944L6.92066 17.9422C7.43133 17.8886 7.94587 17.9979 8.39066 18.2544C8.83519 18.511 9.18687 18.902 9.3951 19.3711Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M12 15C13.6568 15 15 13.6569 15 12C15 10.3431 13.6568 9 12 9C10.3431 9 8.99998 10.3431 8.99998 12C8.99998 13.6569 10.3431 15 12 15Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const sync: []const u8 =
    \\<path d="M21 10C21 10 18.995 7.26822 17.3662 5.63824C15.7373 4.00827 13.4864 3 11 3C6.02944 3 2 7.02944 2 12C2 16.9706 6.02944 21 11 21C15.1031 21 18.5649 18.2543 19.6482 14.5M21 10V4M21 10H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const tag: []const u8 =
    \\<path d="M2 12L11.6422 2.35783C11.8405 2.15953 11.9396 2.06038 12.0558 1.98697C12.1588 1.92191 12.2711 1.87276 12.389 1.84115C12.5221 1.80544 12.6631 1.80078 12.945 1.79148L18.2889 1.61571C19.0558 1.59043 19.4392 1.57779 19.7301 1.72C19.9853 1.84519 20.1927 2.04907 20.3223 2.30189C20.4694 2.58969 20.4632 2.97309 20.4507 3.73989L20.3508 9.0844C20.3457 9.36634 20.3432 9.50731 20.3113 9.64061C20.283 9.75858 20.2371 9.87138 20.1751 9.97537C20.105 10.0929 20.0088 10.1946 19.8165 10.3982L10.5 20M2 12L10.5 20M2 12L5 9M10.5 20L13 17" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const trash: []const u8 =
    \\<path d="M9 3H15M3 6H21M19 6L18.2987 16.5193C18.1935 18.0975 18.1409 18.8867 17.8 19.485C17.4999 20.0118 17.0472 20.4353 16.5017 20.6997C15.882 21 15.0911 21 13.5093 21H10.4907C8.90891 21 8.11803 21 7.49834 20.6997C6.95276 20.4353 6.50009 20.0118 6.19998 19.485C5.85911 18.8867 5.8065 18.0975 5.70129 16.5193L5 6M10 10.5V15.5M14 10.5V15.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const upload: []const u8 =
    \\<path d="M21 15V16.2C21 17.8802 21 18.7202 20.673 19.362C20.3854 19.9265 19.9265 20.3854 19.362 20.673C18.7202 21 17.8802 21 16.2 21H7.8C6.11984 21 5.27976 21 4.63803 20.673C4.07354 20.3854 3.6146 19.9265 3.32698 19.362C3 18.7202 3 17.8802 3 16.2V15M17 8L12 3M12 3L7 8M12 3V15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const user: []const u8 =
    \\<path d="M20 21C20 19.6044 20 18.9067 19.8278 18.3389C19.44 17.0605 18.4395 16.06 17.1611 15.6722C16.5933 15.5 15.8956 15.5 14.5 15.5H9.5C8.10444 15.5 7.40665 15.5 6.83886 15.6722C5.56045 16.06 4.56004 17.0605 4.17224 18.3389C4 18.9067 4 19.6044 4 21M16.5 7.5C16.5 9.98528 14.4853 12 12 12C9.51472 12 7.5 9.98528 7.5 7.5C7.5 5.01472 9.51472 3 12 3C14.4853 3 16.5 5.01472 16.5 7.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const users: []const u8 =
    \\<path d="M16 3.46776C17.4817 4.20411 18.5 5.73314 18.5 7.5C18.5 9.26686 17.4817 10.7959 16 11.5322M18 16.7664C19.5115 17.4503 20.8725 18.565 22 20M2 20C3.94649 17.5226 6.58918 16 9.5 16C12.4108 16 15.0535 17.5226 17 20M14 7.5C14 9.98528 11.9853 12 9.5 12C7.01472 12 5 9.98528 5 7.5C5 5.01472 7.01472 3 9.5 3C11.9853 3 14 5.01472 14 7.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub const x_close: []const u8 =
    \\<path d="M18 6L6 18M6 6l12 12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
;

pub fn get(name: Name) []const u8 {
    const svgs = comptime blk: {
        const fields = @typeInfo(Name).@"enum".fields;
        var arr: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            arr[i] = @field(@This(), f.name);
        }
        break :blk arr;
    };
    return svgs[@intFromEnum(name)];
}
};

pub const avatar = struct {

/// Avatar — user identity with image, initials fallback, badge, and grouping.
///
/// Sub-components matching shadcn API:
///   - Avatar: outer container (size)
///   - AvatarImage: `<img>` element (absolute, covers fallback)
///   - AvatarFallback: initials shown when no image
///   - AvatarBadge: small status indicator positioned on the avatar
///   - AvatarGroup: container that overlaps children with ring dividers (via CSS)
///   - AvatarGroupCount: "+N" overflow count
///
/// Usage:
///   <Avatar size=.md>
///       <AvatarImage src="/img/olivia.jpg" alt="Olivia" />
///       <AvatarFallback>OM</AvatarFallback>
///   </Avatar>
///
///   <Avatar size=.md>
///       <AvatarFallback>OM</AvatarFallback>
///       <AvatarBadge />
///   </Avatar>
///
///   <AvatarGroup>
///       <Avatar size=.sm><AvatarFallback>OM</AvatarFallback></Avatar>
///       <Avatar size=.sm><AvatarFallback>JL</AvatarFallback></Avatar>
///       <AvatarGroupCount size=.sm count="3" />
///   </AvatarGroup>
pub const Size = enum { sm, default, lg };
// ── Components (shadcn API) ─────────────────────────
pub const AvatarProps = struct {
    size: Size = .default,
    children: []const u8 = "",
};
pub fn Avatar(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarProps, _props);
    const dimensions = if (props.size == .sm) "h-8 w-8 text-xs"
        else if (props.size == .lg) "h-14 w-14 text-lg"
        else "h-10 w-10 text-sm";
    try writer.writeAll("<span data-publr-component=\"avatar\"");
    try writer.writeAll(" data-publr-size=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("relative inline-flex items-center justify-center rounded-full shrink-0 ");
    try writer.writeAll(dimensions);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const AvatarImageProps = struct {
    src: []const u8 = "",
    alt: []const u8 = "",
};
pub fn AvatarImage(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarImageProps, _props);
    try writer.writeAll("<img data-publr-part=\"image\" class=\"absolute inset-0 h-full w-full rounded-full object-cover\"");
    try writer.writeAll(" src=\"");
    try runtime.render(writer, props.src);
    try writer.writeAll("\"");
    try writer.writeAll(" alt=\"");
    try runtime.render(writer, props.alt);
    try writer.writeAll("\"");
    try writer.writeAll(">");
}

pub const AvatarFallbackProps = struct {
    children: []const u8 = "",
};
pub fn AvatarFallback(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarFallbackProps, _props);
    try writer.writeAll("<span data-publr-part=\"fallback\" class=\"flex h-full w-full items-center justify-center rounded-full bg-muted text-muted-foreground font-medium uppercase\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const AvatarBadgeProps = struct {};
pub fn AvatarBadge(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<span data-publr-part=\"badge\" class=\"absolute bottom-0 right-0 h-3 w-3 rounded-full border-2 border-background bg-success\">");
    try writer.writeAll("</span>");
}

pub const AvatarGroupProps = struct {
    children: []const u8 = "",
};
pub fn AvatarGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarGroupProps, _props);
    try writer.writeAll("<div data-publr-component=\"avatar-group\" class=\"flex -space-x-2\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const AvatarGroupCountProps = struct {
    count: []const u8 = "0",
    size: Size = .default,
};
pub fn AvatarGroupCount(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarGroupCountProps, _props);
    const dimensions = if (props.size == .sm) "h-8 w-8 text-[10px]"
        else if (props.size == .lg) "h-14 w-14 text-sm"
        else "h-10 w-10 text-xs";
    try writer.writeAll("<span data-publr-part=\"count\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("relative inline-flex items-center justify-center rounded-full border-2 border-background bg-muted font-medium text-muted-foreground ");
    try writer.writeAll(dimensions);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n        +");
    try runtime.render(writer, props.count);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

// ── Gallery Demo (separate from component API) ──────
// Props are forwarded to sub-components. The gallery groups them
// by sub-component in the tree panel via manifest.sub_components.
pub const AvatarDemoProps = struct {
    // Demo selector
    demo: enum { fallback, with_image, with_badge, group } = .fallback,
    // Avatar props
    size: Size = .default,
    // AvatarImage props
    src: []const u8 = "",
    alt: []const u8 = "",
    // AvatarFallback props
    fallback: []const u8 = "",
    // Group: per-item props
    src_1: []const u8 = "",
    alt_1: []const u8 = "",
    fallback_1: []const u8 = "",
    src_2: []const u8 = "",
    alt_2: []const u8 = "",
    fallback_2: []const u8 = "",
    src_3: []const u8 = "",
    alt_3: []const u8 = "",
    fallback_3: []const u8 = "",
    // AvatarGroupCount props
    count: []const u8 = "",
};
pub fn AvatarDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(AvatarDemoProps, _props);
    if (props.demo == .fallback) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.fallback);
                try AvatarFallback(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_image) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try AvatarImage(_children_buf_0.writer(_children_alloc_0), .{ .src = props.src,  .alt = props.alt });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.fallback);
                try AvatarFallback(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_badge) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.fallback);
                try AvatarFallback(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try AvatarBadge(_children_buf_0.writer(_children_alloc_0), .{ });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Avatar(writer, .{ .size = props.size, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.fallback_1);
                    try AvatarFallback(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Avatar(_children_buf_0.writer(_children_alloc_0), .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.fallback_2);
                    try AvatarFallback(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Avatar(_children_buf_0.writer(_children_alloc_0), .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.fallback_3);
                    try AvatarFallback(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Avatar(_children_buf_0.writer(_children_alloc_0), .{ .size = props.size, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try AvatarGroupCount(_children_buf_0.writer(_children_alloc_0), .{ .size = props.size,  .count = props.count });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try AvatarGroup(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const badge = struct {

/// Badge — status indicator label.
///
/// Renders a `<span>` with variant-driven colors. Used for status tags
/// (Published, Draft, Active), counts, and labels.
///
/// No JS — purely CSS-driven.
///
/// Example:
///   <Badge label="Published" variant=.success />
///   <Badge label="Draft" variant=.secondary />
///   <Badge label="Error" variant=.error size=.sm />
pub const Variant = enum { default, secondary, outline, success, warning, @"error", destructive };
pub const Size = enum { sm, md };
pub const BadgeProps = struct {
    label: []const u8 = "Badge",
    variant: Variant = .default,
    size: Size = .md,
};
pub fn Badge(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BadgeProps, _props);
    const base = "inline-flex items-center font-medium rounded-full border";

    const size_classes = switch (props.size) {
        .sm => "px-2 py-0.5 text-[10px]",
        .md => "px-2.5 py-0.5 text-xs",
    };

    const variant_classes = switch (props.variant) {
        .default => "bg-primary text-primary-foreground border-transparent",
        .secondary => "bg-secondary text-secondary-foreground border-transparent",
        .outline => "bg-transparent text-foreground border-border",
        .success => "bg-success/10 text-success border-success/20",
        .warning => "bg-warning/10 text-warning border-warning/20",
        .@"error" => "bg-error/10 text-error border-error/20",
        .destructive => "bg-destructive text-primary-foreground border-transparent",
    };
    try writer.writeAll("<span data-publr-component=\"badge\"");
    try writer.writeAll(" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-size=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(size_classes);
    try writer.writeAll(" ");
    try writer.writeAll(variant_classes);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try runtime.render(writer, props.label);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

};

pub const breadcrumbs = struct {

/// Breadcrumbs — navigation trail.
///
/// Composable sub-components:
///   - Breadcrumb: outer `<nav>` with aria-label
///   - BreadcrumbList: `<ol>` container
///   - BreadcrumbItem: `<li>` wrapper
///   - BreadcrumbLink: clickable link
///   - BreadcrumbPage: current page (not a link)
///   - BreadcrumbSeparator: separator between items (default: chevron icon)
///   - BreadcrumbEllipsis: "..." for collapsed middle items
///
/// Usage:
///   <Breadcrumb>
///       <BreadcrumbList>
///           <BreadcrumbItem><BreadcrumbLink href="/">Home</BreadcrumbLink></BreadcrumbItem>
///           <BreadcrumbSeparator />
///           <BreadcrumbItem><BreadcrumbPage>Profile</BreadcrumbPage></BreadcrumbItem>
///       </BreadcrumbList>
///   </Breadcrumb>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const BreadcrumbProps = struct {
    children: []const u8 = "",
};
pub fn Breadcrumb(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbProps, _props);
    try writer.writeAll("<nav data-publr-component=\"breadcrumbs\" aria-label=\"Breadcrumb\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</nav>");
}

pub const BreadcrumbListProps = struct {
    children: []const u8 = "",
};
pub fn BreadcrumbList(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbListProps, _props);
    try writer.writeAll("<ol class=\"flex items-center gap-1.5 flex-wrap\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</ol>");
}

pub const BreadcrumbItemProps = struct {
    children: []const u8 = "",
};
pub fn BreadcrumbItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbItemProps, _props);
    try writer.writeAll("<li class=\"inline-flex items-center gap-1.5\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</li>");
}

pub const BreadcrumbLinkProps = struct {
    href: []const u8 = "#",
    children: []const u8 = "",
};
pub fn BreadcrumbLink(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbLinkProps, _props);
    try writer.writeAll("<a class=\"text-sm text-muted-foreground hover:text-foreground transition-colors\"");
    try writer.writeAll(" href=\"");
    try runtime.render(writer, props.href);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</a>");
}

pub const BreadcrumbPageProps = struct {
    children: []const u8 = "",
};
pub fn BreadcrumbPage(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbPageProps, _props);
    try writer.writeAll("<span aria-current=\"page\" class=\"text-sm font-medium text-foreground\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const BreadcrumbSeparatorProps = struct {};
pub fn BreadcrumbSeparator(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<li role=\"presentation\" class=\"text-muted-foreground\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .chevron_right,  .size = 14,  .class = "text-muted-foreground" });
    try writer.writeAll("\n");
    try writer.writeAll("</li>");
}

pub const BreadcrumbEllipsisProps = struct {};
pub fn BreadcrumbEllipsis(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<li class=\"text-sm text-muted-foreground\">");
    try writer.writeAll("...");
    try writer.writeAll("</li>");
}

// ── Gallery Demo ────────────────────────────────────
pub const BreadcrumbsDemoProps = struct {
    demo: enum { two_level, three_level, four_level, with_ellipsis } = .three_level,
    // BreadcrumbLink props per item
    link_1: []const u8 = "",
    href_1: []const u8 = "",
    link_2: []const u8 = "",
    href_2: []const u8 = "",
    link_3: []const u8 = "",
    href_3: []const u8 = "",
    // BreadcrumbPage
    page: []const u8 = "",
};
pub fn BreadcrumbsDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(BreadcrumbsDemoProps, _props);
    if (props.demo == .two_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_1);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.page);
                        try BreadcrumbPage(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbList(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .three_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_1);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_2);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.page);
                        try BreadcrumbPage(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbList(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .four_level) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_1);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_2);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_3);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_3, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.page);
                        try BreadcrumbPage(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbList(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_1);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_1, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try BreadcrumbEllipsis(_children_buf_2.writer(_children_alloc_2), .{ });
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.link_2);
                        try BreadcrumbLink(_children_buf_2.writer(_children_alloc_2), .{ .href = props.href_2, .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.page);
                        try BreadcrumbPage(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try BreadcrumbItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try BreadcrumbList(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Breadcrumb(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const button = struct {

/// Button — primary action element.
///
/// Renders a `<button>` with semantic token classes based on hierarchy, size,
/// and disabled state. Uses `data-publr-component="button"` for JS binding.
///
/// Hierarchy variants:
///   - primary: solid primary background, primary-foreground text
///   - secondary: secondary background, secondary-foreground text, border
///   - tertiary: transparent, muted text, hover accent background
///   - link: text-only primary color, no padding
///   - link_gray: text-only muted color, no padding
///   - destructive: solid destructive background for dangerous actions
///
/// Keyboard: standard `<button>` behavior (Enter/Space to activate).
/// No custom JS handler — purely CSS-driven.
///
/// Example:
///   <Button hierarchy=.primary size=.md label="Save changes" />
///   <Button hierarchy=.destructive label="Delete" icon=.trash />
///   <Button hierarchy=.secondary label="Settings" icon=.settings />
pub const Icon = root.icon.Icon;
pub const IconName = root.icon.Name;
pub const Hierarchy = enum { primary, secondary, tertiary, link, link_gray, destructive };
pub const Size = enum { sm, md, lg, xl };
pub const Type = enum { button, submit, reset };
pub const ButtonProps = struct {
    label: []const u8,
    hierarchy: Hierarchy = .primary,
    size: Size = .md,
    disabled: bool = false,
    loading: bool = false,
    button_type: Type = .button,
    icon: ?IconName = null,
    href: []const u8 = "",
    id: []const u8 = "",
    full_width: bool = false,
};
pub fn Button(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ButtonProps, _props);
    const base = "inline-flex items-center justify-center font-semibold transition-colors";
    const is_disabled = props.disabled or props.loading;

    const is_link = props.hierarchy == .link or props.hierarchy == .link_gray;

    const size_classes = if (is_link) switch (props.size) {
        .sm, .md => "text-sm gap-2",
        .lg, .xl => "text-md gap-2.5",
    } else switch (props.size) {
        .sm => "px-3 py-2 text-sm gap-2 rounded-md",
        .md => "px-3.5 py-2.5 text-sm gap-2 rounded-md",
        .lg => "px-4 py-2.5 text-md gap-2 rounded-md",
        .xl => "px-5 py-3 text-lg gap-2.5 rounded-md",
    };

    const icon_size: u16 = switch (props.size) {
        .sm => 14,
        .md => 16,
        .lg => 18,
        .xl => 20,
    };

    const hierarchy_classes = if (is_disabled) switch (props.hierarchy) {
        .primary, .destructive => "bg-muted text-muted-foreground shadow-xs cursor-not-allowed",
        .secondary => "bg-background text-muted-foreground shadow-xs border border-input cursor-not-allowed",
        .tertiary, .link, .link_gray => "text-muted-foreground cursor-not-allowed",
    } else switch (props.hierarchy) {
        .primary => "bg-primary text-primary-foreground shadow-xs hover:bg-primary/90",
        .secondary => "bg-secondary text-secondary-foreground shadow-xs border border-input hover:bg-accent hover:text-accent-foreground",
        .tertiary => "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
        .link => "text-primary hover:text-primary/80",
        .link_gray => "text-muted-foreground hover:text-foreground",
        .destructive => "bg-destructive text-primary-foreground shadow-xs hover:bg-destructive/90",
    };

    const focus = if (is_disabled) "" else "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2";

    const has_icon = props.icon != null and !props.loading;
    const state = if (props.loading) "loading" else "idle";
    const width = if (props.full_width) "w-full justify-center" else "";

    const is_anchor = props.href.len > 0;

    const has_id = props.id.len > 0;
    if (is_anchor) {
        try writer.writeAll("<a data-publr-component=\"button\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(focus);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_size,  .class = "" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    } else if (is_disabled) {
        try writer.writeAll("<button data-publr-component=\"button\" aria-disabled=\"true\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.button_type);
        try writer.writeAll("\"");
        try writer.writeAll(" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(focus);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (props.loading) {
            try Icon(writer, .{ .name = .sync,  .size = icon_size,  .class = "shrink-0 animate-spin" });
        }
        try writer.writeAll("\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_size,  .class = "" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    } else {
        try writer.writeAll("<button data-publr-component=\"button\" aria-disabled=\"false\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.button_type);
        try writer.writeAll("\"");
        try writer.writeAll(" id=\"");
        try runtime.render(writer, if (has_id) props.id else null);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(size_classes);
        try writer.writeAll(" ");
        try writer.writeAll(hierarchy_classes);
        try writer.writeAll(" ");
        try writer.writeAll(focus);
        try writer.writeAll(" ");
        try writer.writeAll(width);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_icon) {
            try Icon(writer, .{ .name = props.icon.?,  .size = icon_size,  .class = "" });
        }
        try writer.writeAll("\n");
        try runtime.render(writer, props.label);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
}

};

pub const card = struct {

/// Card — elevated surface container.
///
/// Composable sub-components:
///   - Card: outer container with border, bg, shadow
///   - CardHeader: top section (contains title, description, action)
///   - CardTitle: heading text
///   - CardDescription: subtitle/helper text
///   - CardAction: top-right action slot (e.g., button, dropdown)
///   - CardContent: main body
///   - CardFooter: bottom section
///
/// Usage:
///   <Card size=.default>
///       <CardHeader>
///           <CardTitle>Account</CardTitle>
///           <CardDescription>Manage your settings.</CardDescription>
///       </CardHeader>
///       <CardContent>
///           <p>Your content here.</p>
///       </CardContent>
///       <CardFooter>
///           <Button label="Save" />
///       </CardFooter>
///   </Card>
// ── Sub-components ──────────────────────────────────
pub const CardProps = struct {
    children: []const u8 = "",
};
pub fn Card(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardProps, _props);
    try writer.writeAll("<div data-publr-component=\"card\" class=\"rounded-lg border border-border bg-card text-card-foreground shadow-sm\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const CardHeaderProps = struct {
    children: []const u8 = "",
};
pub fn CardHeader(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardHeaderProps, _props);
    try writer.writeAll("<div data-publr-part=\"header\" class=\"flex flex-col space-y-1.5 p-6 pb-0\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const CardTitleProps = struct {
    children: []const u8 = "",
};
pub fn CardTitle(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardTitleProps, _props);
    try writer.writeAll("<h3 data-publr-part=\"title\" class=\"text-lg font-semibold text-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</h3>");
}

pub const CardDescriptionProps = struct {
    children: []const u8 = "",
};
pub fn CardDescription(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardDescriptionProps, _props);
    try writer.writeAll("<p data-publr-part=\"description\" class=\"text-sm text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

pub const CardActionProps = struct {
    children: []const u8 = "",
};
pub fn CardAction(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardActionProps, _props);
    try writer.writeAll("<div data-publr-part=\"action\" class=\"ml-auto\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const CardContentProps = struct {
    children: []const u8 = "",
};
pub fn CardContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"p-6\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const CardFooterProps = struct {
    children: []const u8 = "",
};
pub fn CardFooter(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardFooterProps, _props);
    try writer.writeAll("<div data-publr-part=\"footer\" class=\"flex items-center p-6 pt-0\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const CardDemoProps = struct {
    demo: enum { basic, with_description, with_footer } = .basic,
    // CardTitle
    title: []const u8 = "",
    // CardDescription
    description: []const u8 = "",
    // CardContent
    content: []const u8 = "",
    // CardFooter
    footer: []const u8 = "",
};
pub fn CardDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CardDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.title);
                    try CardTitle(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try CardHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try CardContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_description) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.title);
                    try CardTitle(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.description);
                    try CardDescription(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try CardHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try CardContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.title);
                    try CardTitle(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.description);
                    try CardDescription(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try CardHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p class=\"text-sm text-foreground\">");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try CardContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.footer);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</span>");
                try CardFooter(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Card(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const checkbox = struct {

/// Checkbox — toggle control for checked/unchecked state.
///
/// Renders a native `<input type="checkbox">` with styled indicator.
/// Compose with Field/FieldLabel for labeling, or use the built-in label prop.
///
/// No custom JS — native checkbox handles state.
///
/// Usage:
///   <Checkbox label="Accept terms" />
///   <Checkbox label="Subscribe" description="Get weekly updates" />
///   <Checkbox label="Disabled" disabled={true} />
///   <Checkbox label="Invalid" invalid={true} />
///   <Checkbox label="Checked" checked=.checked />
pub const CheckedState = enum { unchecked, checked, indeterminate };
pub const CheckboxProps = struct {
    label: []const u8 = "",
    description: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
    checked: CheckedState = .unchecked,
    disabled: bool = false,
    invalid: bool = false,
};
pub fn Checkbox(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(CheckboxProps, _props);
    const has_label = props.label.len > 0;
    const has_description = props.description.len > 0;
    const invalid_ring = if (props.invalid) "ring-1 ring-error" else "";
    const checkbox_class_base = "h-4 w-4 shrink-0 rounded border border-input bg-background text-primary accent-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
    const state = switch (props.checked) {
        .checked => "checked",
        .unchecked => "unchecked",
        .indeterminate => "indeterminate",
    };
    const is_checked = props.checked == .checked;
    const is_indeterminate = props.checked == .indeterminate;
    if (props.disabled and is_checked) {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (props.disabled and is_indeterminate) {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" data-publr-indeterminate=\"true\" aria-checked=\"mixed\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (props.disabled) {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (is_checked) {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-pointer\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (is_indeterminate) {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-pointer\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" data-publr-indeterminate=\"true\" aria-checked=\"mixed\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else {
        try writer.writeAll("<label data-publr-component=\"checkbox\" class=\"flex items-start gap-2 cursor-pointer\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(checkbox_class_base);
        try writer.writeAll(" ");
        try writer.writeAll(invalid_ring);
        try writer.writeAll(" mt-0.5");
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_label) {
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    }
}

};

pub const container = struct {

/// Container — max-width wrapper with padding.
///
/// Usage:
///   <Container size=.md>content</Container>
pub const ContainerSize = enum { sm, md, lg, xl, full };
pub const Padding = enum { none, sm, md, lg, xl };
pub const ContainerProps = struct {
    size: ContainerSize = .lg,
    padding: Padding = .lg,
    children: []const u8 = "",
};
pub fn Container(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ContainerProps, _props);
    const size_class = if (props.size == .sm) "max-w-lg" else if (props.size == .md) "max-w-3xl" else if (props.size == .lg) "max-w-5xl" else if (props.size == .xl) "max-w-7xl" else "max-w-full";
    const pad = if (props.padding == .none) "" else if (props.padding == .sm) "px-3 py-2" else if (props.padding == .md) "px-4 py-3" else if (props.padding == .lg) "px-6 py-4" else "px-8 py-6";
    try writer.writeAll("<div data-publr-component=\"container\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("w-full mx-auto ");
    try writer.writeAll(size_class);
    try writer.writeAll(" ");
    try writer.writeAll(pad);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const dialog = struct {

/// Dialog — modal overlay with focus trap.
///
/// Sub-components matching Radix Dialog API:
///   - Dialog: root container with state
///   - DialogTrigger: button that opens the dialog
///   - DialogOverlay: backdrop layer
///   - DialogContent: centered content panel
///   - DialogClose: button that closes the dialog
///   - DialogTitle: accessible heading
///   - DialogDescription: accessible body text
///
/// Usage:
///   <Dialog>
///       <DialogTrigger><Button label="Open" /></DialogTrigger>
///       <DialogOverlay>
///           <DialogContent>
///               <DialogTitle>Are you sure?</DialogTitle>
///               <DialogDescription>This action cannot be undone.</DialogDescription>
///               <div class="flex justify-end gap-3 mt-6">
///                   <DialogClose><Button hierarchy=.secondary label="Cancel" /></DialogClose>
///                   <Button hierarchy=.destructive label="Delete" />
///               </div>
///           </DialogContent>
///       </DialogOverlay>
///   </Dialog>
pub const Button = root.button.Button;
// ── Sub-components ──────────────────────────────────
pub const DialogProps = struct {
    id: []const u8 = "",
    dismissable: bool = true,
    children: []const u8 = "",
};
pub fn Dialog(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogProps, _props);
    try writer.writeAll("<div data-publr-component=\"dialog\" data-publr-state=\"closed\" class=\"group inline-block\"");
    try writer.writeAll(" data-publr-id=\"");
    try runtime.render(writer, props.id);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-dismissable=\"");
    try runtime.render(writer, if (props.dismissable) "true" else "false");
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const DialogTriggerProps = struct {
    children: []const u8 = "",
};
pub fn DialogTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" aria-expanded=\"false\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const DialogOverlayProps = struct {
    children: []const u8 = "",
};
pub fn DialogOverlay(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogOverlayProps, _props);
    try writer.writeAll("<div data-publr-part=\"overlay\" class=\"fixed inset-0 z-50 flex items-center justify-center bg-black/50 opacity-0 pointer-events-none transition-opacity group-data-[publr-state=open]:opacity-100 group-data-[publr-state=open]:pointer-events-auto\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const DialogContentProps = struct {
    children: []const u8 = "",
};
pub fn DialogContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"publr-dialog-title\" aria-describedby=\"publr-dialog-description\" class=\"bg-popover text-popover-foreground rounded-lg p-6 max-w-md w-full mx-4 shadow-lg border border-border\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const DialogCloseProps = struct {
    children: []const u8 = "",
};
pub fn DialogClose(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogCloseProps, _props);
    try writer.writeAll("<span data-publr-part=\"close\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const DialogTitleProps = struct {
    children: []const u8 = "",
};
pub fn DialogTitle(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogTitleProps, _props);
    try writer.writeAll("<h3 id=\"publr-dialog-title\" data-publr-part=\"title\" class=\"text-lg font-semibold text-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</h3>");
}

pub const DialogDescriptionProps = struct {
    children: []const u8 = "",
};
pub fn DialogDescription(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogDescriptionProps, _props);
    try writer.writeAll("<p id=\"publr-dialog-description\" data-publr-part=\"description\" class=\"mt-2 text-sm text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

// ── Gallery Demo ────────────────────────────────────
pub const DialogDemoProps = struct {
    demo: enum { confirm, destructive, info } = .confirm,
};
pub fn DialogDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DialogDemoProps, _props);
    if (props.demo == .confirm) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = "Open dialog" });
                try DialogTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Save changes?");
                        try DialogTitle(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Your unsaved changes will be lost if you don't save them.");
                        try DialogDescription(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<div class=\"flex justify-end gap-3 mt-6\">");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try Button(_children_buf_3.writer(_children_alloc_3), .{ .hierarchy = .secondary,  .label = "Cancel" });
                        try DialogClose(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<span data-publr-part=\"confirm\">");
                    try Button(_children_buf_2.writer(_children_alloc_2), .{ .hierarchy = .primary,  .label = "Save" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</span>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</div>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try DialogContent(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DialogOverlay(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Dialog(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .destructive) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .destructive,  .label = "Delete" });
                try DialogTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Delete item?");
                        try DialogTitle(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("This action cannot be undone. This will permanently delete the item.");
                        try DialogDescription(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<div class=\"flex justify-end gap-3 mt-6\">");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try Button(_children_buf_3.writer(_children_alloc_3), .{ .hierarchy = .secondary,  .label = "Cancel" });
                        try DialogClose(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<span data-publr-part=\"confirm\">");
                    try Button(_children_buf_2.writer(_children_alloc_2), .{ .hierarchy = .destructive,  .label = "Delete" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</span>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</div>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try DialogContent(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DialogOverlay(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Dialog(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = "Info" });
                try DialogTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Notice");
                        try DialogTitle(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Please read the terms and conditions before continuing.");
                        try DialogDescription(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<div class=\"flex justify-end gap-3 mt-6\">");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("<span data-publr-part=\"confirm\">");
                    try Button(_children_buf_2.writer(_children_alloc_2), .{ .hierarchy = .primary,  .label = "I understand" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</span>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("</div>");
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try DialogContent(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DialogOverlay(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Dialog(writer, .{ .dismissable = false, .children = _children_buf_0.items });
        }
    }
}

};

pub const dropdown = struct {

/// DropdownMenu — action menu triggered by a button.
///
/// Sub-components matching shadcn API:
///   - DropdownMenu: root container with state
///   - DropdownMenuTrigger: element that opens the menu
///   - DropdownMenuContent: floating panel
///   - DropdownMenuGroup: logical grouping
///   - DropdownMenuLabel: non-interactive heading
///   - DropdownMenuItem: clickable action (variant: destructive)
///   - DropdownMenuSeparator: visual divider
///
/// Usage:
///   <DropdownMenu>
///       <DropdownMenuTrigger>
///           <Button label="Actions" icon=.chevron_down />
///       </DropdownMenuTrigger>
///       <DropdownMenuContent>
///           <DropdownMenuLabel>Actions</DropdownMenuLabel>
///           <DropdownMenuItem>Edit</DropdownMenuItem>
///           <DropdownMenuItem>Duplicate</DropdownMenuItem>
///           <DropdownMenuSeparator />
///           <DropdownMenuItem variant=.destructive>Delete</DropdownMenuItem>
///       </DropdownMenuContent>
///   </DropdownMenu>
pub const Button = root.button.Button;
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const DropdownMenuProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenu(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuProps, _props);
    try writer.writeAll("<div data-publr-component=\"dropdown\" data-publr-state=\"closed\" class=\"group relative inline-block\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const DropdownMenuTriggerProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenuTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" aria-expanded=\"false\" aria-haspopup=\"menu\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const DropdownMenuContentProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenuContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" role=\"menu\" class=\"hidden group-data-[publr-state=open]:block min-w-48 rounded-lg border border-border bg-popover p-1 text-popover-foreground shadow-lg\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const DropdownMenuGroupProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenuGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuGroupProps, _props);
    try writer.writeAll("<div role=\"group\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
}

pub const DropdownMenuLabelProps = struct {
    children: []const u8 = "",
};
pub fn DropdownMenuLabel(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuLabelProps, _props);
    try writer.writeAll("<span data-publr-part=\"label\" class=\"block px-2 py-1.5 text-xs font-semibold text-muted-foreground\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const ItemVariant = enum { default, destructive };
pub const DropdownMenuItemProps = struct {
    variant: ItemVariant = .default,
    disabled: bool = false,
    href: []const u8 = "",
    children: []const u8 = "",
};
pub fn DropdownMenuItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownMenuItemProps, _props);
    const item_class = if (props.variant == .destructive)
        "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm text-destructive outline-none hover:bg-destructive/10 focus-visible:bg-destructive/10 disabled:pointer-events-none disabled:text-muted-foreground disabled:opacity-50"
    else
        "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent focus-visible:text-accent-foreground disabled:pointer-events-none disabled:text-muted-foreground disabled:opacity-50";

    const variant_attr = if (props.variant == .destructive) "destructive" else "default";
    const state = if (props.disabled) "disabled" else "default";
    const is_link = props.href.len > 0;
    if (is_link) {
        try writer.writeAll("<a data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\"");
        try writer.writeAll(" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, item_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    } else if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\" aria-disabled=\"true\"");
        try writer.writeAll(" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, item_class);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"item\" role=\"menuitem\" tabindex=\"-1\"");
        try writer.writeAll(" data-publr-variant=\"");
        try runtime.render(writer, variant_attr);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, item_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
}

pub const DropdownMenuSeparatorProps = struct {};
pub fn DropdownMenuSeparator(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<div data-publr-part=\"separator\" role=\"separator\" class=\"my-1 h-px bg-border\">");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const DropdownDemoProps = struct {
    demo: enum { basic, with_icons, destructive } = .basic,
};
pub fn DropdownDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(DropdownDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Actions");
                    try DropdownMenuLabel(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Edit");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Duplicate");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Archive");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .disabled = true, .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_icons) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Actions");
                    try DropdownMenuLabel(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .edit,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Edit");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Duplicate");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .disabled = true, .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .bookmark,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Archive");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = "Actions",  .icon = .chevron_down,  .size = .sm });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Actions");
                    try DropdownMenuLabel(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .edit,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Edit");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Duplicate");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .trash,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll(" Delete");
                    try DropdownMenuItem(_children_buf_1.writer(_children_alloc_1), .{ .variant = .destructive, .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try DropdownMenuContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try DropdownMenu(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const empty = struct {

/// Empty — zero-data placeholder.
///
/// Sub-components matching shadcn API:
///   - Empty: outer container
///   - EmptyMedia: icon/illustration area (variant: default or icon)
///   - EmptyTitle: heading
///   - EmptyDescription: body text
///   - EmptyContent: action area (buttons, links)
///
/// Usage:
///   <Empty>
///       <EmptyMedia variant=.icon>
///           <Icon name=.folder size={24} class="text-muted-foreground" />
///       </EmptyMedia>
///       <EmptyTitle>No posts yet</EmptyTitle>
///       <EmptyDescription>Create your first post to get started.</EmptyDescription>
///       <EmptyContent><Button label="Create Post" /></EmptyContent>
///   </Empty>
pub const Icon = root.icon.Icon;
pub const Button = root.button.Button;
// ── Sub-components ──────────────────────────────────
pub const EmptyProps = struct {
    children: []const u8 = "",
};
pub fn Empty(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyProps, _props);
    try writer.writeAll("<div data-publr-component=\"empty\" class=\"flex flex-col items-center justify-center py-12 px-4 text-center\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const EmptyMediaProps = struct {
    variant: enum { default, icon } = .default,
    children: []const u8 = "",
};
pub fn EmptyMedia(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyMediaProps, _props);
    const wrapper_class = if (props.variant == .icon) "rounded-full bg-muted p-3 mb-4" else "mb-4";
    try writer.writeAll("<div data-publr-part=\"media\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, wrapper_class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const EmptyTitleProps = struct {
    children: []const u8 = "",
};
pub fn EmptyTitle(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyTitleProps, _props);
    try writer.writeAll("<h3 data-publr-part=\"title\" class=\"text-lg font-semibold text-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</h3>");
}

pub const EmptyDescriptionProps = struct {
    children: []const u8 = "",
};
pub fn EmptyDescription(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyDescriptionProps, _props);
    try writer.writeAll("<p data-publr-part=\"description\" class=\"mt-1 text-sm text-muted-foreground max-w-sm\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

pub const EmptyContentProps = struct {
    children: []const u8 = "",
};
pub fn EmptyContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"mt-4\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const EmptyDemoProps = struct {
    demo: enum { with_action, without_action } = .with_action,
    // EmptyTitle
    title: []const u8 = "",
    // EmptyDescription
    description: []const u8 = "",
    // Button label in EmptyContent
    action_label: []const u8 = "",
};
pub fn EmptyDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(EmptyDemoProps, _props);
    if (props.demo == .with_action) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Icon(_children_buf_1.writer(_children_alloc_1), .{ .name = .folder,  .size = 24,  .class = "text-muted-foreground" });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try EmptyMedia(_children_buf_0.writer(_children_alloc_0), .{ .variant = .icon, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.title);
                try EmptyTitle(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.description);
                try EmptyDescription(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .primary,  .label = props.action_label });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try EmptyContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Empty(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Icon(_children_buf_1.writer(_children_alloc_1), .{ .name = .search,  .size = 24,  .class = "text-muted-foreground" });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try EmptyMedia(_children_buf_0.writer(_children_alloc_0), .{ .variant = .icon, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.title);
                try EmptyTitle(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.description);
                try EmptyDescription(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Empty(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const form_field = struct {

/// Field — accessible form field layout system.
///
/// Sub-components matching shadcn API:
///   - FieldSet: semantic fieldset wrapper
///   - FieldLegend: legend for fieldset (variant: legend/label)
///   - FieldGroup: stacks Field components
///   - Field: core wrapper for a single field (orientation: vertical/horizontal)
///   - FieldContent: flex column for label + description beside control
///   - FieldLabel: styled label element
///   - FieldDescription: helper text
///   - FieldSeparator: visual divider
///   - FieldError: error message container
///
/// Usage:
///   <Field>
///       <FieldLabel>Email</FieldLabel>
///       <Input type=.email placeholder="you@example.com" />
///       <FieldDescription>We'll never share your email.</FieldDescription>
///   </Field>
// ── Sub-components ──────────────────────────────────
pub const FieldSetProps = struct {
    children: []const u8 = "",
};
pub fn FieldSet(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldSetProps, _props);
    try writer.writeAll("<fieldset data-publr-component=\"field-set\" class=\"space-y-6\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</fieldset>");
}

pub const LegendVariant = enum { legend, label };
pub const FieldLegendProps = struct {
    variant: LegendVariant = .legend,
    children: []const u8 = "",
};
pub fn FieldLegend(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldLegendProps, _props);
    const cls = if (props.variant == .label)
        "text-sm font-medium text-foreground"
    else
        "text-lg font-semibold text-foreground";
    try writer.writeAll("<legend");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, cls);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll(props.children);
    try writer.writeAll("</legend>");
}

pub const FieldGroupProps = struct {
    children: []const u8 = "",
};
pub fn FieldGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldGroupProps, _props);
    try writer.writeAll("<div data-publr-component=\"field-group\" class=\"flex flex-col gap-4\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const Orientation = enum { vertical, horizontal };
pub const FieldProps = struct {
    orientation: Orientation = .vertical,
    invalid: bool = false,
    children: []const u8 = "",
};
pub fn Field(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldProps, _props);
    const layout = if (props.orientation == .horizontal)
        "flex items-start gap-3"
    else
        "grid gap-1.5";

    const invalid_attr = if (props.invalid) "true" else "false";
    try writer.writeAll("<div data-publr-component=\"field\"");
    try writer.writeAll(" data-invalid=\"");
    try runtime.render(writer, invalid_attr);
    try writer.writeAll("\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, layout);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const FieldContentProps = struct {
    children: []const u8 = "",
};
pub fn FieldContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldContentProps, _props);
    try writer.writeAll("<div class=\"flex flex-col gap-0.5\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const FieldLabelProps = struct {
    html_for: []const u8 = "",
    required: bool = false,
    children: []const u8 = "",
};
pub fn FieldLabel(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldLabelProps, _props);
    const has_for = props.html_for.len > 0;
    if (has_for and props.required) {
        try writer.writeAll("<label class=\"text-sm font-medium text-foreground\"");
        try writer.writeAll(" for=\"");
        try runtime.render(writer, props.html_for);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"text-error ml-0.5\">");
        try writer.writeAll("*");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (has_for) {
        try writer.writeAll("<label class=\"text-sm font-medium text-foreground\"");
        try writer.writeAll(" for=\"");
        try runtime.render(writer, props.html_for);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (props.required) {
        try writer.writeAll("<label class=\"text-sm font-medium text-foreground\">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"text-error ml-0.5\">");
        try writer.writeAll("*");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else {
        try writer.writeAll("<label class=\"text-sm font-medium text-foreground\">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    }
}

pub const FieldDescriptionProps = struct {
    children: []const u8 = "",
};
pub fn FieldDescription(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldDescriptionProps, _props);
    try writer.writeAll("<p class=\"text-xs text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

pub const FieldSeparatorProps = struct {
    children: []const u8 = "",
};
pub fn FieldSeparator(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldSeparatorProps, _props);
    const has_children = props.children.len > 0;
    if (has_children) {
        try writer.writeAll("<div class=\"relative my-4\">");
        try writer.writeAll("\n");
        try writer.writeAll("<div class=\"absolute inset-0 flex items-center\">");
        try writer.writeAll("<span class=\"w-full border-t border-border\">");
        try writer.writeAll("</span>");
        try writer.writeAll("</div>");
        try writer.writeAll("\n");
        try writer.writeAll("<div class=\"relative flex justify-center text-xs uppercase\">");
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"bg-background px-2 text-muted-foreground\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
    } else {
        try writer.writeAll("<div class=\"my-4 h-px bg-border\">");
        try writer.writeAll("</div>");
    }
}

pub const FieldErrorProps = struct {
    children: []const u8 = "",
};
pub fn FieldError(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldErrorProps, _props);
    try writer.writeAll("<p class=\"text-xs text-error\" role=\"alert\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

// ── Gallery Demo ────────────────────────────────────
pub const Input = root.text_input.Input;
pub const FieldDemoProps = struct {
    demo: enum { basic, with_error, horizontal, fieldset } = .basic,
};
pub fn FieldDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FieldDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("Email");
                try FieldLabel(_children_buf_0.writer(_children_alloc_0), .{ .html_for = "email", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Input(_children_buf_0.writer(_children_alloc_0), .{ .name = "email",  .placeholder = "you@example.com" });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("We'll never share your email.");
                try FieldDescription(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Field(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_error) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("Email");
                try FieldLabel(_children_buf_0.writer(_children_alloc_0), .{ .html_for = "email", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Input(_children_buf_0.writer(_children_alloc_0), .{ .name = "email",  .placeholder = "you@example.com",  .invalid = true });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("Please enter a valid email address.");
                try FieldError(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Field(writer, .{ .invalid = true, .children = _children_buf_0.items });
        }
    } else if (props.demo == .horizontal) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("Remember me");
                try FieldLabel(_children_buf_0.writer(_children_alloc_0), .{ .html_for = "remember", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Input(_children_buf_0.writer(_children_alloc_0), .{ .input_type = .checkbox,  .name = "remember" });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Field(writer, .{ .orientation = .horizontal, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("Profile");
                try FieldLegend(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Full name");
                        try FieldLabel(_children_buf_2.writer(_children_alloc_2), .{ .html_for = "name", .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try Input(_children_buf_2.writer(_children_alloc_2), .{ .name = "name",  .placeholder = "John Doe" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try Field(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Email");
                        try FieldLabel(_children_buf_2.writer(_children_alloc_2), .{ .html_for = "email",  .required = true, .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try Input(_children_buf_2.writer(_children_alloc_2), .{ .name = "email",  .placeholder = "you@example.com" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("We'll never share your email.");
                        try FieldDescription(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try Field(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try FieldGroup(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try FieldSet(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const flex = struct {

/// Flex — generic flexbox container.
///
/// Usage:
///   <Flex justify=.between items=.center gap=.md>
///       <Heading level=.h1 size=.lg>Title</Heading>
///       <Button label="Create" />
///   </Flex>
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, between, around };
pub const Wrap = enum { nowrap, wrap };
pub const FlexProps = struct {
    gap: Gap = .none,
    items: Align = .center,
    justify: Justify = .start,
    wrap: Wrap = .nowrap,
    children: []const u8 = "",
};
pub fn Flex(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(FlexProps, _props);
    const gap_class = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    const align_class = if (props.items == .start) "items-start" else if (props.items == .center) "items-center" else if (props.items == .end) "items-end" else if (props.items == .baseline) "items-baseline" else "items-stretch";
    const justify_class = if (props.justify == .start) "" else if (props.justify == .center) "justify-center" else if (props.justify == .end) "justify-end" else if (props.justify == .between) "justify-between" else "justify-around";
    const wrap_class = if (props.wrap == .wrap) "flex-wrap" else "";
    try writer.writeAll("<div data-publr-component=\"flex\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("flex flex-row ");
    try writer.writeAll(gap_class);
    try writer.writeAll(" ");
    try writer.writeAll(align_class);
    try writer.writeAll(" ");
    try writer.writeAll(justify_class);
    try writer.writeAll(" ");
    try writer.writeAll(wrap_class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const grid = struct {

/// Grid — CSS grid with column presets.
///
/// Usage:
///   <Grid columns=.three gap=.lg>items</Grid>
pub const Columns = enum { one, two, three, four, auto_fill };
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const GridProps = struct {
    columns: Columns = .three,
    gap: Gap = .lg,
    children: []const u8 = "",
};
pub fn Grid(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(GridProps, _props);
    const cols = if (props.columns == .one) "grid-cols-1" else if (props.columns == .two) "grid-cols-2" else if (props.columns == .three) "grid-cols-3" else if (props.columns == .four) "grid-cols-4" else "grid-cols-[repeat(auto-fill,minmax(200px,1fr))]";
    const gap_class = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    try writer.writeAll("<div data-publr-component=\"grid\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("grid ");
    try writer.writeAll(cols);
    try writer.writeAll(" ");
    try writer.writeAll(gap_class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const heading = struct {

/// Heading — semantic heading with constrained sizes.
///
/// Usage:
///   <Heading level=.h1 size=.xl>Page Title</Heading>
///   <Heading level=.h2 size=.md>Section</Heading>
pub const Level = enum { h1, h2, h3, h4, h5, h6 };
pub const HeadingSize = enum { xs, sm, md, lg, xl };
pub const HeadingProps = struct {
    level: Level = .h2,
    size: HeadingSize = .md,
    children: []const u8 = "",
};
pub fn Heading(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(HeadingProps, _props);
    const class = if (props.size == .xs) "text-sm font-semibold tracking-tight text-foreground" else if (props.size == .sm) "text-md font-semibold tracking-tight text-foreground" else if (props.size == .md) "text-lg font-semibold tracking-tight text-foreground" else if (props.size == .lg) "text-xl font-semibold tracking-tight text-foreground" else "text-2xl font-bold tracking-tight text-foreground";
    if (props.level == .h1) {
        try writer.writeAll("<h1 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h1>");
    } else if (props.level == .h2) {
        try writer.writeAll("<h2 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h2>");
    } else if (props.level == .h3) {
        try writer.writeAll("<h3 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h3>");
    } else if (props.level == .h4) {
        try writer.writeAll("<h4 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h4>");
    } else if (props.level == .h5) {
        try writer.writeAll("<h5 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h5>");
    } else {
        try writer.writeAll("<h6 data-publr-component=\"heading\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</h6>");
    }
}

};

pub const icon = struct {

/// Icon — SVG icon from the design system icon set.
///
/// Renders an `<svg>` element with the inner paths for the specified icon.
/// Icons are generated from `src/icons/*.svg` via the build script.
///
/// Size constants:
///   - Size.sm = 16
///   - Size.md = 20
///   - Size.lg = 24 (default)
///   - Size.xl = 32
///
/// Example:
///   <Icon name=.home />
///   <Icon name=.settings size={Size.sm} />
///   <Icon name=.edit size={Size.xl} class="text-brand-600" />
pub const icons = root.icons_data;
pub const Name = icons.Name;
pub const Size = struct {
    pub const sm: u16 = 16;
    pub const md: u16 = 20;
    pub const lg: u16 = 24;
    pub const xl: u16 = 32;
};
pub const IconProps = struct {
    name: Name,
    size: u16 = 24,
    class: []const u8 = "icon",
};
pub fn Icon(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(IconProps, _props);
    try writer.writeAll("<svg viewBox=\"0 0 24 24\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, props.class);
    try writer.writeAll("\"");
    try writer.writeAll(" width=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\"");
    try writer.writeAll(" height=\"");
    try runtime.render(writer, props.size);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(icons.get(props.name));
    try writer.writeAll("\n");
    try writer.writeAll("</svg>");
}

};

pub const input_group = struct {

/// InputGroup — input with addons (icons, buttons, text).
///
/// Sub-components matching shadcn API:
///   - InputGroup: wrapper that combines input + addons
///   - InputGroupInput: styled input for use inside group
///   - InputGroupTextarea: styled textarea for use inside group
///   - InputGroupAddon: container for icons/buttons/text (align: inline_start/inline_end)
///   - InputGroupButton: button inside addon
///   - InputGroupText: static text inside addon
///
/// Usage:
///   <InputGroup>
///       <InputGroupInput placeholder="Search..." />
///       <InputGroupAddon align_to=.inline_end>
///           <Icon name=.search size={16} class="text-muted-foreground" />
///       </InputGroupAddon>
///   </InputGroup>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const InputGroupProps = struct {
    children: []const u8 = "",
};
pub fn InputGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupProps, _props);
    try writer.writeAll("<div data-publr-component=\"input-group\" class=\"relative flex items-center\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const AddonAlign = enum { inline_start, inline_end };
pub const InputGroupAddonProps = struct {
    align_to: AddonAlign = .inline_start,
    children: []const u8 = "",
};
pub fn InputGroupAddon(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupAddonProps, _props);
    const cls = if (props.align_to == .inline_end)
        "absolute right-0 inset-y-0 flex items-center pr-3 pointer-events-none"
    else
        "absolute left-0 inset-y-0 flex items-center pl-3 pointer-events-none";
    try writer.writeAll("<div data-publr-part=\"addon\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, cls);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const InputGroupInputProps = struct {
    placeholder: []const u8 = "",
    name: []const u8 = "",
    has_start_addon: bool = false,
    has_end_addon: bool = false,
    disabled: bool = false,
};
pub fn InputGroupInput(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupInputProps, _props);
    const padding = if (props.has_start_addon and props.has_end_addon) "pl-10 pr-10"
        else if (props.has_start_addon) "pl-10"
        else if (props.has_end_addon) "pr-10"
        else "";
    if (props.disabled) {
        try writer.writeAll("<input data-publr-part=\"input\" type=\"text\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll("flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 ");
        try writer.writeAll(padding);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
    } else {
        try writer.writeAll("<input data-publr-part=\"input\" type=\"text\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll("flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 ");
        try writer.writeAll(padding);
        try writer.writeAll("\"");
        try writer.writeAll(">");
    }
}

pub const InputGroupTextareaProps = struct {
    placeholder: []const u8 = "",
    name: []const u8 = "",
    disabled: bool = false,
};
pub fn InputGroupTextarea(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupTextareaProps, _props);
    if (props.disabled) {
        try writer.writeAll("<textarea data-publr-part=\"textarea\" class=\"flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</textarea>");
    } else {
        try writer.writeAll("<textarea data-publr-part=\"textarea\" class=\"flex w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</textarea>");
    }
}

pub const InputGroupButtonProps = struct {
    children: []const u8 = "",
};
pub fn InputGroupButton(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupButtonProps, _props);
    try writer.writeAll("<button data-publr-part=\"button\" class=\"inline-flex items-center justify-center text-xs font-medium text-muted-foreground hover:text-foreground transition-colors pointer-events-auto\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
}

pub const InputGroupTextProps = struct {
    children: []const u8 = "",
};
pub fn InputGroupText(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupTextProps, _props);
    try writer.writeAll("<span class=\"text-sm text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</span>");
}

// ── Gallery Demo ────────────────────────────────────
pub const InputGroupDemoProps = struct {
    demo: enum { with_icon, with_text, with_button } = .with_icon,
};
pub fn InputGroupDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputGroupDemoProps, _props);
    if (props.demo == .with_icon) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroupInput(_children_buf_0.writer(_children_alloc_0), .{ .placeholder = "Search...",  .has_start_addon = true });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Icon(_children_buf_1.writer(_children_alloc_1), .{ .name = .search,  .size = 16,  .class = "text-muted-foreground" });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try InputGroupAddon(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_text) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroupInput(_children_buf_0.writer(_children_alloc_0), .{ .placeholder = "0.00",  .has_start_addon = true });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("$");
                    try InputGroupText(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try InputGroupAddon(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroupInput(_children_buf_0.writer(_children_alloc_0), .{ .placeholder = "Enter URL...",  .has_end_addon = true });
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .copy,  .size = 16,  .class = "" });
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try InputGroupButton(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try InputGroupAddon(_children_buf_0.writer(_children_alloc_0), .{ .align_to = .inline_end, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try InputGroup(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const text_input = struct {

/// Input — text input and textarea for forms.
///
/// Sub-components:
///   - Input: styled `<input>` element
///   - Textarea: styled `<textarea>` element
///
/// Usage:
///   <Input name="email" placeholder="you@example.com" />
///   <Input input_type=.password name="password" />
///   <Textarea name="bio" placeholder="Tell us about yourself" />
pub const InputType = enum { text, email, password, search, tel, url, number, file, checkbox };
pub const InputProps = struct {
    input_type: InputType = .text,
    name: []const u8 = "",
    placeholder: []const u8 = "",
    value: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    required: bool = false,
};
pub fn Input(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(InputProps, _props);
    const is_checkbox = props.input_type == .checkbox;
    const base = if (is_checkbox)
        "h-4 w-4 rounded border border-input bg-background accent-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50"
    else
        "flex w-full rounded-md border bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring file:border-0 file:bg-transparent file:text-foreground file:text-sm disabled:cursor-not-allowed disabled:opacity-50";

    const border = if (props.invalid) "border-error" else "border-input";
    if (props.disabled and props.required) {
        try writer.writeAll("<input data-publr-component=\"input\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" required=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
    } else if (props.disabled) {
        try writer.writeAll("<input data-publr-component=\"input\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
    } else if (props.required) {
        try writer.writeAll("<input data-publr-component=\"input\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(" required=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
    } else {
        try writer.writeAll("<input data-publr-component=\"input\"");
        try writer.writeAll(" type=\"");
        try runtime.render(writer, props.input_type);
        try writer.writeAll("\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
    }
}

pub const TextareaProps = struct {
    name: []const u8 = "",
    placeholder: []const u8 = "",
    value: []const u8 = "",
    disabled: bool = false,
    invalid: bool = false,
    required: bool = false,
};
pub fn Textarea(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TextareaProps, _props);
    const border = if (props.invalid) "border-error" else "border-input";
    if (props.disabled) {
        try writer.writeAll("<textarea data-publr-component=\"textarea\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll("flex w-full rounded-md border bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.value);
        try writer.writeAll("</textarea>");
    } else {
        try writer.writeAll("<textarea data-publr-component=\"textarea\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" placeholder=\"");
        try runtime.render(writer, props.placeholder);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll("flex w-full rounded-md border bg-background px-3 py-2 text-sm text-foreground transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 min-h-20 resize-y ");
        try writer.writeAll(border);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-invalid=\"");
        try runtime.render(writer, if (props.invalid) "true" else "false");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.value);
        try writer.writeAll("</textarea>");
    }
}

};

pub const pagination = struct {

/// Pagination — page navigation.
///
/// Sub-components matching shadcn API:
///   - Pagination: outer `<nav>` container
///   - PaginationContent: `<ul>` list
///   - PaginationItem: `<li>` wrapper
///   - PaginationLink: page number (is_active for current page)
///   - PaginationPrevious: previous button with chevron
///   - PaginationNext: next button with chevron
///   - PaginationEllipsis: "..." truncation
///
/// Usage:
///   <Pagination>
///       <PaginationContent>
///           <PaginationItem><PaginationPrevious /></PaginationItem>
///           <PaginationItem><PaginationLink is_active={true}>1</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationLink>2</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationEllipsis /></PaginationItem>
///           <PaginationItem><PaginationLink>10</PaginationLink></PaginationItem>
///           <PaginationItem><PaginationNext /></PaginationItem>
///       </PaginationContent>
///   </Pagination>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const PaginationProps = struct {
    children: []const u8 = "",
};
pub fn Pagination(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationProps, _props);
    try writer.writeAll("<nav data-publr-component=\"pagination\" aria-label=\"Pagination\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</nav>");
}

pub const PaginationContentProps = struct {
    children: []const u8 = "",
};
pub fn PaginationContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationContentProps, _props);
    try writer.writeAll("<ul class=\"flex items-center gap-1\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</ul>");
}

pub const PaginationItemProps = struct {
    children: []const u8 = "",
};
pub fn PaginationItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationItemProps, _props);
    try writer.writeAll("<li>");
    try writer.writeAll(props.children);
    try writer.writeAll("</li>");
}

pub const PaginationLinkProps = struct {
    href: []const u8 = "#",
    is_active: bool = false,
    children: []const u8 = "",
};
pub fn PaginationLink(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationLinkProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.is_active) {
        try writer.writeAll("<span aria-current=\"page\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" bg-accent text-accent-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
    } else {
        try writer.writeAll("<a");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    }
}

pub const PaginationPreviousProps = struct {
    href: []const u8 = "#",
    disabled: bool = false,
};
pub fn PaginationPrevious(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationPreviousProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.disabled) {
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground opacity-50 cursor-not-allowed");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_left,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
    } else {
        try writer.writeAll("<a");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_left,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    }
}

pub const PaginationNextProps = struct {
    href: []const u8 = "#",
    disabled: bool = false,
};
pub fn PaginationNext(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationNextProps, _props);
    const base = "inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium transition-colors";
    if (props.disabled) {
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground opacity-50 cursor-not-allowed");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_right,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
    } else {
        try writer.writeAll("<a");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-muted-foreground hover:bg-accent/50 hover:text-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_right,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    }
}

pub const PaginationEllipsisProps = struct {};
pub fn PaginationEllipsis(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<span class=\"inline-flex items-center justify-center h-8 w-8 text-sm text-muted-foreground\">");
    try writer.writeAll("...");
    try writer.writeAll("</span>");
}

// ── Gallery Demo ────────────────────────────────────
pub const PaginationDemoProps = struct {
    demo: enum { few_pages, many_pages, last_page } = .few_pages,
};
pub fn PaginationDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PaginationDemoProps, _props);
    if (props.demo == .few_pages) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationPrevious(_children_buf_2.writer(_children_alloc_2), .{ .disabled = true });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("1");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("2");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("3");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationNext(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PaginationContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .many_pages) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationPrevious(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("1");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationEllipsis(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("4");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("5");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("6");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationEllipsis(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("20");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationNext(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PaginationContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationPrevious(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("1");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationEllipsis(_children_buf_2.writer(_children_alloc_2), .{ });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("8");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("9");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("10");
                        try PaginationLink(_children_buf_2.writer(_children_alloc_2), .{ .is_active = true, .children = _children_buf_3.items });
                    }
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try PaginationNext(_children_buf_2.writer(_children_alloc_2), .{ .disabled = true });
                    try PaginationItem(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PaginationContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Pagination(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const popover = struct {

/// Popover — floating content panel.
///
/// Sub-components matching Radix Popover API:
///   - Popover: outer container with state
///   - PopoverTrigger: element that opens the popover
///   - PopoverContent: floating panel (side, align_to, side_offset, align_offset)
///   - PopoverHeader: header section
///   - PopoverTitle: title text
///   - PopoverDescription: body text
///   - PopoverClose: close button (optional)
///   - PopoverArrow: pointing arrow (optional)
///
/// Usage:
///   <Popover>
///       <PopoverTrigger><Button label="Settings" /></PopoverTrigger>
///       <PopoverContent side=.bottom align_to=.center side_offset={8}>
///           <PopoverTitle>Settings</PopoverTitle>
///           <PopoverDescription>Customize your preferences.</PopoverDescription>
///       </PopoverContent>
///   </Popover>
pub const Button = root.button.Button;
// ── Sub-components ──────────────────────────────────
pub const PopoverProps = struct {
    modal: bool = false,
    children: []const u8 = "",
};
pub fn Popover(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverProps, _props);
    try writer.writeAll("<div data-publr-component=\"popover\" data-publr-state=\"closed\" class=\"group relative inline-block\"");
    try writer.writeAll(" data-publr-modal=\"");
    try runtime.render(writer, props.modal);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const PopoverTriggerProps = struct {
    children: []const u8 = "",
};
pub fn PopoverTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" aria-expanded=\"false\" aria-haspopup=\"dialog\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const Side = enum { top, right, bottom, left };
pub const Alignment = enum { start, center, end };
pub const PopoverContentProps = struct {
    side: Side = .bottom,
    align_to: Alignment = .center,
    side_offset: u16 = 0,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    children: []const u8 = "",
};
pub fn PopoverContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" role=\"dialog\" class=\"hidden group-data-[publr-state=open]:block w-72 rounded-lg border border-border bg-popover p-4 text-popover-foreground shadow-md\"");
    try writer.writeAll(" data-publr-side=\"");
    try runtime.render(writer, props.side);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-align=\"");
    try runtime.render(writer, props.align_to);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-side-offset=\"");
    try runtime.render(writer, props.side_offset);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-align-offset=\"");
    try runtime.render(writer, props.align_offset);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-avoid-collisions=\"");
    try runtime.render(writer, props.avoid_collisions);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const PopoverHeaderProps = struct {
    children: []const u8 = "",
};
pub fn PopoverHeader(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverHeaderProps, _props);
    try writer.writeAll("<div data-publr-part=\"header\" class=\"mb-3\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const PopoverTitleProps = struct {
    children: []const u8 = "",
};
pub fn PopoverTitle(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverTitleProps, _props);
    try writer.writeAll("<h4 data-publr-part=\"title\" class=\"text-sm font-semibold text-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</h4>");
}

pub const PopoverDescriptionProps = struct {
    children: []const u8 = "",
};
pub fn PopoverDescription(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverDescriptionProps, _props);
    try writer.writeAll("<p data-publr-part=\"description\" class=\"text-sm text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</p>");
}

pub const PopoverCloseProps = struct {
    children: []const u8 = "",
};
pub fn PopoverClose(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverCloseProps, _props);
    try writer.writeAll("<button data-publr-part=\"close\" class=\"text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
}

pub const PopoverArrowProps = struct {};
pub fn PopoverArrow(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<div data-publr-part=\"arrow\" class=\"absolute w-2.5 h-2.5 bg-popover border border-border rotate-45\">");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const PopoverDemoProps = struct {
    demo: enum { basic, with_form } = .basic,
    // Popover
    modal: bool = false,
    // PopoverContent
    side: Side = .bottom,
    align_to: Alignment = .center,
    side_offset: u16 = 0,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    // PopoverTitle
    title: []const u8 = "",
    // PopoverDescription
    description: []const u8 = "",
    // Trigger label
    trigger_label: []const u8 = "",
};
pub fn PopoverDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(PopoverDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PopoverTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.title);
                        try PopoverTitle(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try PopoverHeader(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.description);
                    try PopoverDescription(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PopoverContent(_children_buf_0.writer(_children_alloc_0), .{ .side = props.side,  .align_to = props.align_to,  .side_offset = props.side_offset,  .align_offset = props.align_offset,  .avoid_collisions = props.avoid_collisions, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Popover(writer, .{ .modal = props.modal, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try Button(_children_buf_1.writer(_children_alloc_1), .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PopoverTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try runtime.render(_children_buf_3.writer(_children_alloc_3), props.title);
                        try PopoverTitle(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try PopoverHeader(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.description);
                    try PopoverDescription(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<div class=\"mt-3 grid gap-2\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<label class=\"grid gap-1\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<span class=\"text-xs font-medium text-foreground\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("Width");
                try _children_buf_1.writer(_children_alloc_1).writeAll("</span>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<input type=\"text\" value=\"100%\" class=\"rounded-md border border-input bg-background px-2.5 py-1.5 text-sm\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("</label>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<label class=\"grid gap-1\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<span class=\"text-xs font-medium text-foreground\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("Height");
                try _children_buf_1.writer(_children_alloc_1).writeAll("</span>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<input type=\"text\" value=\"auto\" class=\"rounded-md border border-input bg-background px-2.5 py-1.5 text-sm\">");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("</label>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("</div>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try PopoverContent(_children_buf_0.writer(_children_alloc_0), .{ .side = props.side,  .align_to = props.align_to,  .side_offset = props.side_offset,  .align_offset = props.align_offset,  .avoid_collisions = props.avoid_collisions, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Popover(writer, .{ .modal = props.modal, .children = _children_buf_0.items });
        }
    }
}

};

pub const radio_group = struct {

/// RadioGroup — set of radio buttons where only one can be selected.
///
/// Sub-components matching shadcn API:
///   - RadioGroup: outer container (fieldset + legend)
///   - RadioGroupItem: individual radio option with label + description
///
/// Usage:
///   <RadioGroup name="plan" legend="Choose a plan">
///       <RadioGroupItem value="free" label="Free" description="Up to 5 pages" />
///       <RadioGroupItem value="pro" label="Pro" description="Unlimited pages" />
///       <RadioGroupItem value="enterprise" label="Enterprise" description="Custom SLA" />
///   </RadioGroup>
pub const Orientation = enum { vertical, horizontal };
// ── Sub-components ──────────────────────────────────
pub const RadioGroupProps = struct {
    name: []const u8 = "",
    legend: []const u8 = "",
    orientation: Orientation = .vertical,
    disabled: bool = false,
    children: []const u8 = "",
};
pub fn RadioGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupProps, _props);
    const layout = if (props.orientation == .horizontal)
        "flex flex-row flex-wrap gap-4"
    else
        "flex flex-col gap-3";

    const has_legend = props.legend.len > 0;
    if (props.disabled) {
        try writer.writeAll("<fieldset data-publr-component=\"radio-group\" class=\"space-y-3\"");
        try writer.writeAll(" data-publr-name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_legend) {
            try writer.writeAll("<legend class=\"text-sm font-medium text-foreground\">");
            try runtime.render(writer, props.legend);
            try writer.writeAll("</legend>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("<div role=\"radiogroup\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, layout);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
        try writer.writeAll("\n");
        try writer.writeAll("</fieldset>");
    } else {
        try writer.writeAll("<fieldset data-publr-component=\"radio-group\" class=\"space-y-3\"");
        try writer.writeAll(" data-publr-name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        if (has_legend) {
            try writer.writeAll("<legend class=\"text-sm font-medium text-foreground\">");
            try runtime.render(writer, props.legend);
            try writer.writeAll("</legend>");
        }
        try writer.writeAll("\n");
        try writer.writeAll("<div role=\"radiogroup\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, layout);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
        try writer.writeAll("\n");
        try writer.writeAll("</fieldset>");
    }
}

pub const RadioGroupItemProps = struct {
    value: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    name: []const u8 = "",
    disabled: bool = false,
};
pub fn RadioGroupItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupItemProps, _props);
    const has_description = props.description.len > 0;
    const radio_class = "mt-0.5 h-4 w-4 shrink-0 rounded-full border border-input bg-background text-primary accent-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
    if (props.disabled) {
        if (props.name.len > 0) {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50\">");
            try writer.writeAll("\n");
            try writer.writeAll("<input type=\"radio\"");
            try writer.writeAll(" name=\"");
            try runtime.render(writer, props.name);
            try writer.writeAll("\"");
            try writer.writeAll(" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\"");
            try writer.writeAll(" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\"");
            try writer.writeAll(" disabled=\"");
            try runtime.render(writer, true);
            try writer.writeAll("\"");
            try writer.writeAll(">");
            try writer.writeAll("\n");
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
            try writer.writeAll("\n");
            try writer.writeAll("</label>");
        } else {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"flex items-start gap-2 cursor-not-allowed opacity-50\">");
            try writer.writeAll("\n");
            try writer.writeAll("<input type=\"radio\"");
            try writer.writeAll(" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\"");
            try writer.writeAll(" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\"");
            try writer.writeAll(" disabled=\"");
            try runtime.render(writer, true);
            try writer.writeAll("\"");
            try writer.writeAll(">");
            try writer.writeAll("\n");
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
            try writer.writeAll("\n");
            try writer.writeAll("</label>");
        }
    } else {
        if (props.name.len > 0) {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"flex items-start gap-2 cursor-pointer\">");
            try writer.writeAll("\n");
            try writer.writeAll("<input type=\"radio\"");
            try writer.writeAll(" name=\"");
            try runtime.render(writer, props.name);
            try writer.writeAll("\"");
            try writer.writeAll(" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\"");
            try writer.writeAll(" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\"");
            try writer.writeAll(">");
            try writer.writeAll("\n");
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
            try writer.writeAll("\n");
            try writer.writeAll("</label>");
        } else {
            try writer.writeAll("<label data-publr-part=\"item\" data-publr-state=\"unchecked\" class=\"flex items-start gap-2 cursor-pointer\">");
            try writer.writeAll("\n");
            try writer.writeAll("<input type=\"radio\"");
            try writer.writeAll(" value=\"");
            try runtime.render(writer, props.value);
            try writer.writeAll("\"");
            try writer.writeAll(" class=\"");
            try runtime.render(writer, radio_class);
            try writer.writeAll("\"");
            try writer.writeAll(">");
            try writer.writeAll("\n");
            try writer.writeAll("<div class=\"grid gap-0.5\">");
            try writer.writeAll("\n");
            try writer.writeAll("<span class=\"text-sm text-foreground\">");
            try runtime.render(writer, props.label);
            try writer.writeAll("</span>");
            try writer.writeAll("\n");
            if (has_description) {
                try writer.writeAll("<span class=\"text-xs text-muted-foreground\">");
                try runtime.render(writer, props.description);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("\n");
            try writer.writeAll("</div>");
            try writer.writeAll("\n");
            try writer.writeAll("</label>");
        }
    }
}

// ── Gallery preview ─────────────────────────────────
pub const Demo = enum { default };
pub const RadioGroupPreviewProps = struct {
    demo: Demo = .default,
    // RadioGroup
    name: []const u8 = "",
    legend: []const u8 = "",
    orientation: Orientation = .vertical,
    disabled: bool = false,
    // RadioGroupItem @1
    value_1: []const u8 = "",
    label_1: []const u8 = "",
    description_1: []const u8 = "",
    // RadioGroupItem @2
    value_2: []const u8 = "",
    label_2: []const u8 = "",
    description_2: []const u8 = "",
    // RadioGroupItem @3
    value_3: []const u8 = "",
    label_3: []const u8 = "",
    description_3: []const u8 = "",
};
pub fn RadioGroupPreview(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(RadioGroupPreviewProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try RadioGroupItem(_children_buf_0.writer(_children_alloc_0), .{ .value = props.value_1,  .label = props.label_1,  .description = props.description_1 });
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try RadioGroupItem(_children_buf_0.writer(_children_alloc_0), .{ .value = props.value_2,  .label = props.label_2,  .description = props.description_2 });
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try RadioGroupItem(_children_buf_0.writer(_children_alloc_0), .{ .value = props.value_3,  .label = props.label_3,  .description = props.description_3 });
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try RadioGroup(writer, .{ .name = props.name,  .legend = props.legend,  .orientation = props.orientation,  .disabled = props.disabled, .children = _children_buf_0.items });
    }
}

};

pub const select = struct {

/// Select — custom select with composable parts.
///
/// Sub-components matching shadcn API:
///   - Select: outer container with state + hidden input
///   - SelectTrigger: the button that opens the listbox
///   - SelectValue: displayed value/placeholder inside trigger
///   - SelectContent: floating listbox panel
///   - SelectGroup: group of options
///   - SelectLabel: non-interactive group heading
///   - SelectItem: individual option
///   - SelectSeparator: divider between groups
///
/// Usage:
///   <Select name="fruit">
///       <SelectTrigger>
///           <SelectValue>Select a fruit</SelectValue>
///       </SelectTrigger>
///       <SelectContent>
///           <SelectGroup>
///               <SelectLabel>Fruits</SelectLabel>
///               <SelectItem value="apple">Apple</SelectItem>
///               <SelectItem value="banana">Banana</SelectItem>
///           </SelectGroup>
///       </SelectContent>
///   </Select>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const SelectProps = struct {
    name: []const u8 = "",
    default_value: []const u8 = "",
    children: []const u8 = "",
};
pub fn Select(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectProps, _props);
    try writer.writeAll("<div data-publr-component=\"select\" data-publr-state=\"closed\" class=\"inline-block\"");
    try writer.writeAll(" data-publr-default-value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll("<input type=\"hidden\" data-publr-part=\"value\"");
    try writer.writeAll(" name=\"");
    try runtime.render(writer, props.name);
    try writer.writeAll("\"");
    try writer.writeAll(" value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SelectTriggerProps = struct {
    children: []const u8 = "",
    disabled: bool = false,
};
pub fn SelectTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectTriggerProps, _props);
    const base = "inline-flex items-center justify-between w-48 rounded-md border border-input bg-background px-3 py-2 text-sm transition-colors hover:bg-accent/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
    if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"trigger\" type=\"button\" aria-haspopup=\"listbox\" aria-expanded=\"false\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, base);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "text-muted-foreground shrink-0" });
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"trigger\" type=\"button\" aria-haspopup=\"listbox\" aria-expanded=\"false\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, base);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "text-muted-foreground shrink-0" });
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
}

pub const SelectValueProps = struct {
    children: []const u8 = "",
};
pub fn SelectValue(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectValueProps, _props);
    try writer.writeAll("<span class=\"text-muted-foreground truncate\" data-publr-part=\"label\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const SelectContentProps = struct {
    children: []const u8 = "",
};
pub fn SelectContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" role=\"listbox\" class=\"hidden min-w-48 rounded-lg border border-border bg-popover p-1 text-popover-foreground shadow-lg\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SelectGroupProps = struct {
    children: []const u8 = "",
};
pub fn SelectGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectGroupProps, _props);
    try writer.writeAll("<div role=\"group\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
}

pub const SelectLabelProps = struct {
    children: []const u8 = "",
};
pub fn SelectLabel(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectLabelProps, _props);
    try writer.writeAll("<div class=\"px-2 py-1.5 text-xs font-semibold text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
}

pub const SelectItemProps = struct {
    value: []const u8 = "",
    disabled: bool = false,
    children: []const u8 = "",
};
pub fn SelectItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectItemProps, _props);
    const state = if (props.disabled) "disabled" else "unselected";
    const class = if (props.disabled)
        "group flex items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm text-muted-foreground opacity-50 outline-none pointer-events-none cursor-default"
    else
        "group flex items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent cursor-pointer";
    if (props.disabled) {
        try writer.writeAll("<div data-publr-part=\"option\" role=\"option\" tabindex=\"-1\" aria-disabled=\"true\" aria-selected=\"false\"");
        try writer.writeAll(" data-value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span data-publr-part=\"option-label\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span data-publr-part=\"indicator\" class=\"ml-2 shrink-0 opacity-0 transition-opacity\">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .check,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
    } else {
        try writer.writeAll("<div data-publr-part=\"option\" role=\"option\" tabindex=\"-1\" aria-selected=\"false\"");
        try writer.writeAll(" data-value=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span data-publr-part=\"option-label\">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span data-publr-part=\"indicator\" class=\"ml-2 shrink-0 opacity-0 transition-opacity group-data-[publr-state=selected]:opacity-100\">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .check,  .size = 16,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</div>");
    }
}

pub const SelectSeparatorProps = struct {};
pub fn SelectSeparator(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<div role=\"separator\" class=\"my-1 h-px bg-border\">");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const SelectDemoProps = struct {
    demo: enum { basic, with_groups, disabled } = .basic,
    // Select
    name: []const u8 = "",
    default_value: []const u8 = "banana",
    // SelectValue
    placeholder: []const u8 = "",
};
pub fn SelectDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SelectDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.placeholder);
                    try SelectValue(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Apple");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "apple", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Banana");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "banana", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Cherry");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "cherry",  .disabled = true, .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Grape");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "grape", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Orange");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "orange", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_groups) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.placeholder);
                    try SelectValue(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectTrigger(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Fruits");
                        try SelectLabel(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Apple");
                        try SelectItem(_children_buf_2.writer(_children_alloc_2), .{ .value = "apple", .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Banana");
                        try SelectItem(_children_buf_2.writer(_children_alloc_2), .{ .value = "banana", .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Cherry");
                        try SelectItem(_children_buf_2.writer(_children_alloc_2), .{ .value = "cherry", .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try SelectGroup(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectSeparator(_children_buf_1.writer(_children_alloc_1), .{ });
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Vegetables");
                        try SelectLabel(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Carrot");
                        try SelectItem(_children_buf_2.writer(_children_alloc_2), .{ .value = "carrot", .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Potato");
                        try SelectItem(_children_buf_2.writer(_children_alloc_2), .{ .value = "potato",  .disabled = true, .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try SelectGroup(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.placeholder);
                    try SelectValue(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectTrigger(_children_buf_0.writer(_children_alloc_0), .{ .disabled = true, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Apple");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "apple", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("Banana");
                    try SelectItem(_children_buf_1.writer(_children_alloc_1), .{ .value = "banana", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try SelectContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Select(writer, .{ .name = props.name,  .default_value = props.default_value, .children = _children_buf_0.items });
        }
    }
}

};

pub const separator = struct {

/// Separator — visual divider.
///
/// Usage:
///   <Separator />
///   <Separator spacing=.lg />
pub const Direction = enum { horizontal, vertical };
pub const Spacing = enum { none, sm, md, lg, xl };
pub const SeparatorProps = struct {
    direction: Direction = .horizontal,
    spacing: Spacing = .none,
};
pub fn Separator(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SeparatorProps, _props);
    const base = if (props.direction == .vertical) "h-full border-l border-border self-stretch" else "w-full border-t border-border";
    const margin = if (props.spacing == .none) "" else if (props.spacing == .sm) (if (props.direction == .horizontal) "my-2" else "mx-2") else if (props.spacing == .md) (if (props.direction == .horizontal) "my-3" else "mx-3") else if (props.spacing == .lg) (if (props.direction == .horizontal) "my-4" else "mx-4") else (if (props.direction == .horizontal) "my-6" else "mx-6");
    try writer.writeAll("<div data-publr-component=\"separator\" role=\"separator\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(margin);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("</div>");
}

};

pub const sidebar = struct {

/// Sidebar — navigation sidebar with composable parts.
///
/// Sub-components matching shadcn API:
///   - Sidebar: outer container
///   - SidebarHeader: sticky top section
///   - SidebarContent: scrollable middle section
///   - SidebarFooter: sticky bottom section
///   - SidebarGroup: section within content
///   - SidebarGroupLabel: section heading (collapsible option)
///   - SidebarGroupContent: section body
///   - SidebarMenu: list container
///   - SidebarMenuItem: list item wrapper
///   - SidebarMenuButton: clickable nav item (is_active)
///   - SidebarMenuBadge: count badge on an item
///
/// Usage:
///   <Sidebar>
///       <SidebarHeader>
///           <span>Publr CMS</span>
///       </SidebarHeader>
///       <SidebarContent>
///           <SidebarGroup>
///               <SidebarGroupLabel>Content</SidebarGroupLabel>
///               <SidebarGroupContent>
///                   <SidebarMenu>
///                       <SidebarMenuItem>
///                           <SidebarMenuButton is_active={true}>
///                               <Icon name=.file size={16} class="" /> Pages
///                           </SidebarMenuButton>
///                       </SidebarMenuItem>
///                   </SidebarMenu>
///               </SidebarGroupContent>
///           </SidebarGroup>
///       </SidebarContent>
///   </Sidebar>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const SidebarContainerProps = struct {
    children: []const u8 = "",
};
pub fn SidebarContainer(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarContainerProps, _props);
    try writer.writeAll("<nav data-publr-component=\"sidebar\" class=\"flex h-full w-56 flex-col bg-sidebar text-sidebar-foreground border-r border-sidebar-border\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</nav>");
}

pub const SidebarHeaderProps = struct {
    children: []const u8 = "",
};
pub fn SidebarHeader(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarHeaderProps, _props);
    try writer.writeAll("<div data-publr-part=\"header\" class=\"flex items-center gap-2 px-3 py-4 border-b border-sidebar-border\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarContentProps = struct {
    children: []const u8 = "",
};
pub fn SidebarContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" class=\"flex-1 overflow-y-auto px-2 py-2\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarFooterProps = struct {
    children: []const u8 = "",
};
pub fn SidebarFooter(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarFooterProps, _props);
    try writer.writeAll("<div data-publr-part=\"footer\" class=\"border-t border-sidebar-border px-2 py-2\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarGroupProps = struct {
    children: []const u8 = "",
};
pub fn SidebarGroup(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupProps, _props);
    try writer.writeAll("<div data-publr-part=\"section\" data-publr-state=\"open\" class=\"mb-2\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarGroupLabelProps = struct {
    children: []const u8 = "",
    collapsible: bool = false,
};
pub fn SidebarGroupLabel(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupLabelProps, _props);
    if (props.collapsible) {
        try writer.writeAll("<button data-publr-part=\"section-trigger\" class=\"flex w-full items-center justify-between px-2 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wider hover:text-sidebar-foreground\">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .chevron_down,  .size = 14,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    } else {
        try writer.writeAll("<span class=\"block px-2 py-1 text-xs font-semibold text-muted-foreground uppercase tracking-wider\">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
    }
}

pub const SidebarGroupContentProps = struct {
    children: []const u8 = "",
};
pub fn SidebarGroupContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarGroupContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"section-content\" class=\"mt-0.5 space-y-0.5\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarMenuProps = struct {
    children: []const u8 = "",
};
pub fn SidebarMenu(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuProps, _props);
    try writer.writeAll("<div class=\"space-y-0.5\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const SidebarMenuItemProps = struct {
    children: []const u8 = "",
};
pub fn SidebarMenuItem(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuItemProps, _props);
    try writer.writeAll("<div>");
    try writer.writeAll(props.children);
    try writer.writeAll("</div>");
}

pub const SidebarMenuButtonProps = struct {
    href: []const u8 = "#",
    is_active: bool = false,
    children: []const u8 = "",
};
pub fn SidebarMenuButton(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuButtonProps, _props);
    const base = "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm transition-colors";
    if (props.is_active) {
        try writer.writeAll("<a data-publr-part=\"item\" aria-current=\"page\"");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" bg-sidebar-primary text-sidebar-primary-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    } else {
        try writer.writeAll("<a data-publr-part=\"item\"");
        try writer.writeAll(" href=\"");
        try runtime.render(writer, props.href);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(base);
        try writer.writeAll(" text-sidebar-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</a>");
    }
}

pub const SidebarMenuBadgeProps = struct {
    children: []const u8 = "",
};
pub fn SidebarMenuBadge(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarMenuBadgeProps, _props);
    try writer.writeAll("<span class=\"ml-auto inline-flex items-center rounded-full bg-sidebar-accent px-1.5 py-0.5 text-[10px] font-medium text-sidebar-accent-foreground\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

// ── Gallery preview (matches filename, no gallery_entry) ──
pub const SidebarProps = struct {
    collapsible: bool = false,
};
pub fn Sidebar(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SidebarProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            try _children_buf_1.writer(_children_alloc_1).writeAll("<span class=\"text-sm font-semibold text-sidebar-foreground\">");
            try _children_buf_1.writer(_children_alloc_1).writeAll("Publr CMS");
            try _children_buf_1.writer(_children_alloc_1).writeAll("</span>");
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            try SidebarHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
        }
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    try _children_buf_3.writer(_children_alloc_3).writeAll("Content");
                    try SidebarGroupLabel(_children_buf_2.writer(_children_alloc_2), .{ .collapsible = props.collapsible, .children = _children_buf_3.items });
                }
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    try _children_buf_3.writer(_children_alloc_3).writeAll("\n");
                    {
                        var _children_buf_4: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_4 = @import("std").heap.page_allocator;
                        defer _children_buf_4.deinit(_children_alloc_4);
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try Icon(_children_buf_6.writer(_children_alloc_6), .{ .name = .file,  .size = 16,  .class = "" });
                                try _children_buf_6.writer(_children_alloc_6).writeAll(" Pages\n                            ");
                                try SidebarMenuButton(_children_buf_5.writer(_children_alloc_5), .{ .is_active = true, .children = _children_buf_6.items });
                            }
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            try SidebarMenuItem(_children_buf_4.writer(_children_alloc_4), .{ .children = _children_buf_5.items });
                        }
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try Icon(_children_buf_6.writer(_children_alloc_6), .{ .name = .edit,  .size = 16,  .class = "" });
                                try _children_buf_6.writer(_children_alloc_6).writeAll(" Posts\n                                ");
                                {
                                    var _children_buf_7: @import("std").ArrayListUnmanaged(u8) = .{};
                                    const _children_alloc_7 = @import("std").heap.page_allocator;
                                    defer _children_buf_7.deinit(_children_alloc_7);
                                    try _children_buf_7.writer(_children_alloc_7).writeAll("12");
                                    try SidebarMenuBadge(_children_buf_6.writer(_children_alloc_6), .{ .children = _children_buf_7.items });
                                }
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try SidebarMenuButton(_children_buf_5.writer(_children_alloc_5), .{ .children = _children_buf_6.items });
                            }
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            try SidebarMenuItem(_children_buf_4.writer(_children_alloc_4), .{ .children = _children_buf_5.items });
                        }
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try Icon(_children_buf_6.writer(_children_alloc_6), .{ .name = .image,  .size = 16,  .class = "" });
                                try _children_buf_6.writer(_children_alloc_6).writeAll(" Media\n                            ");
                                try SidebarMenuButton(_children_buf_5.writer(_children_alloc_5), .{ .children = _children_buf_6.items });
                            }
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            try SidebarMenuItem(_children_buf_4.writer(_children_alloc_4), .{ .children = _children_buf_5.items });
                        }
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        try SidebarMenu(_children_buf_3.writer(_children_alloc_3), .{ .children = _children_buf_4.items });
                    }
                    try _children_buf_3.writer(_children_alloc_3).writeAll("\n");
                    try SidebarGroupContent(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                }
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try SidebarGroup(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
            }
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    try _children_buf_3.writer(_children_alloc_3).writeAll("System");
                    try SidebarGroupLabel(_children_buf_2.writer(_children_alloc_2), .{ .collapsible = props.collapsible, .children = _children_buf_3.items });
                }
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    try _children_buf_3.writer(_children_alloc_3).writeAll("\n");
                    {
                        var _children_buf_4: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_4 = @import("std").heap.page_allocator;
                        defer _children_buf_4.deinit(_children_alloc_4);
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try Icon(_children_buf_6.writer(_children_alloc_6), .{ .name = .settings,  .size = 16,  .class = "" });
                                try _children_buf_6.writer(_children_alloc_6).writeAll(" Settings\n                            ");
                                try SidebarMenuButton(_children_buf_5.writer(_children_alloc_5), .{ .children = _children_buf_6.items });
                            }
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            try SidebarMenuItem(_children_buf_4.writer(_children_alloc_4), .{ .children = _children_buf_5.items });
                        }
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        {
                            var _children_buf_5: @import("std").ArrayListUnmanaged(u8) = .{};
                            const _children_alloc_5 = @import("std").heap.page_allocator;
                            defer _children_buf_5.deinit(_children_alloc_5);
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            {
                                var _children_buf_6: @import("std").ArrayListUnmanaged(u8) = .{};
                                const _children_alloc_6 = @import("std").heap.page_allocator;
                                defer _children_buf_6.deinit(_children_alloc_6);
                                try _children_buf_6.writer(_children_alloc_6).writeAll("\n");
                                try Icon(_children_buf_6.writer(_children_alloc_6), .{ .name = .users,  .size = 16,  .class = "" });
                                try _children_buf_6.writer(_children_alloc_6).writeAll(" Users\n                            ");
                                try SidebarMenuButton(_children_buf_5.writer(_children_alloc_5), .{ .children = _children_buf_6.items });
                            }
                            try _children_buf_5.writer(_children_alloc_5).writeAll("\n");
                            try SidebarMenuItem(_children_buf_4.writer(_children_alloc_4), .{ .children = _children_buf_5.items });
                        }
                        try _children_buf_4.writer(_children_alloc_4).writeAll("\n");
                        try SidebarMenu(_children_buf_3.writer(_children_alloc_3), .{ .children = _children_buf_4.items });
                    }
                    try _children_buf_3.writer(_children_alloc_3).writeAll("\n");
                    try SidebarGroupContent(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                }
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try SidebarGroup(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
            }
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            try SidebarContent(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
        }
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try Icon(_children_buf_2.writer(_children_alloc_2), .{ .name = .user,  .size = 16,  .class = "" });
                try _children_buf_2.writer(_children_alloc_2).writeAll(" Account\n            ");
                try SidebarMenuButton(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
            }
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            try SidebarFooter(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
        }
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try SidebarContainer(writer, .{ .children = _children_buf_0.items });
    }
}

};

pub const stack = struct {

/// Stack — flex column or row with semantic gap.
///
/// Usage:
///   <Stack gap=.lg>
///       <Heading level=.h1 size=.lg>Title</Heading>
///   </Stack>
///   <Stack direction=.horizontal gap=.md items=.center>
///       <Icon name=.settings />
///       <Text>Settings</Text>
///   </Stack>
pub const Direction = enum { vertical, horizontal };
pub const Gap = enum { none, xs, sm, md, lg, xl, @"2xl" };
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, between, around };
pub const StackProps = struct {
    direction: Direction = .vertical,
    gap: Gap = .md,
    items: Align = .stretch,
    justify: Justify = .start,
    padding: Gap = .none,
    children: []const u8 = "",
};
pub fn Stack(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(StackProps, _props);
    const dir = if (props.direction == .horizontal) "flex-row" else "flex-col";
    const gap_class = if (props.gap == .none) "" else if (props.gap == .xs) "gap-1" else if (props.gap == .sm) "gap-2" else if (props.gap == .md) "gap-3" else if (props.gap == .lg) "gap-4" else if (props.gap == .xl) "gap-6" else "gap-8";
    const align_class = if (props.items == .start) "items-start" else if (props.items == .center) "items-center" else if (props.items == .end) "items-end" else if (props.items == .baseline) "items-baseline" else "items-stretch";
    const justify_class = if (props.justify == .start) "" else if (props.justify == .center) "justify-center" else if (props.justify == .end) "justify-end" else if (props.justify == .between) "justify-between" else "justify-around";
    const pad = if (props.padding == .none) "" else if (props.padding == .xs) "p-1" else if (props.padding == .sm) "p-2" else if (props.padding == .md) "p-3" else if (props.padding == .lg) "p-4" else if (props.padding == .xl) "p-6" else "p-8";
    try writer.writeAll("<div data-publr-component=\"stack\"");
    try writer.writeAll(" class=\"");
    try writer.writeAll("flex ");
    try writer.writeAll(dir);
    try writer.writeAll(" ");
    try writer.writeAll(gap_class);
    try writer.writeAll(" ");
    try writer.writeAll(align_class);
    try writer.writeAll(" ");
    try writer.writeAll(justify_class);
    try writer.writeAll(" ");
    try writer.writeAll(pad);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const @"switch" = struct {

/// Switch — toggle control with label.
///
/// Renders a `<label>` wrapping a hidden native checkbox and a styled track/thumb.
/// The thumb position and track color are driven by `:checked` CSS state.
///
/// No custom JS needed — native checkbox handles state. Minimal JS syncs `aria-checked`.
///
/// Example:
///   <Switch label="Enable notifications" />
///   <Switch label="Dark mode" checked={true} />
///   <Switch label="Maintenance" disabled={true} />
pub const Size = enum { sm, md, lg };
pub const SwitchProps = struct {
    label: []const u8 = "Toggle",
    name: []const u8 = "",
    size: Size = .md,
    checked: bool = false,
    disabled: bool = false,
};
pub fn Switch(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(SwitchProps, _props);
    const track_size = switch (props.size) {
        .sm => "w-8 h-4",
        .md => "w-10 h-5",
        .lg => "w-12 h-6",
    };

    const thumb_size = switch (props.size) {
        .sm => "h-3 w-3",
        .md => "h-4 w-4",
        .lg => "h-5 w-5",
    };

    const thumb_translate = switch (props.size) {
        .sm => "peer-checked:translate-x-4",
        .md => "peer-checked:translate-x-5",
        .lg => "peer-checked:translate-x-6",
    };

    const label_size = switch (props.size) {
        .sm => "text-xs",
        .md => "text-sm",
        .lg => "text-md",
    };
    const state = if (props.checked) "checked" else "unchecked";
    const container_class = if (props.disabled)
        "inline-flex items-center gap-2 cursor-not-allowed opacity-50"
    else
        "inline-flex items-center gap-2 cursor-pointer";
    if (props.disabled and props.checked) {
        try writer.writeAll("<label data-publr-component=\"switch\"");
        try writer.writeAll(" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, container_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"relative inline-flex items-center shrink-0\">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" class=\"peer sr-only\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (props.disabled) {
        try writer.writeAll("<label data-publr-component=\"switch\"");
        try writer.writeAll(" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, container_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"relative inline-flex items-center shrink-0\">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" class=\"peer sr-only\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else if (props.checked) {
        try writer.writeAll("<label data-publr-component=\"switch\"");
        try writer.writeAll(" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, container_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"relative inline-flex items-center shrink-0\">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" class=\"peer sr-only\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(" checked=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    } else {
        try writer.writeAll("<label data-publr-component=\"switch\"");
        try writer.writeAll(" data-publr-size=\"");
        try runtime.render(writer, props.size);
        try writer.writeAll("\"");
        try writer.writeAll(" data-publr-state=\"");
        try runtime.render(writer, state);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, container_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span class=\"relative inline-flex items-center shrink-0\">");
        try writer.writeAll("\n");
        try writer.writeAll("<input type=\"checkbox\" class=\"peer sr-only\"");
        try writer.writeAll(" name=\"");
        try runtime.render(writer, props.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll(track_size);
        try writer.writeAll(" rounded-full bg-input transition-colors peer-checked:bg-primary");
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("absolute left-0.5 ");
        try writer.writeAll(thumb_size);
        try writer.writeAll(" rounded-full bg-background shadow-xs transition-transform ");
        try writer.writeAll(thumb_translate);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("<span");
        try writer.writeAll(" class=\"");
        try writer.writeAll("text-foreground ");
        try writer.writeAll(label_size);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try runtime.render(writer, props.label);
        try writer.writeAll("</span>");
        try writer.writeAll("\n");
        try writer.writeAll("</label>");
    }
}

};

pub const table = struct {

/// Table — data table with composable parts.
///
/// Sub-components matching shadcn API:
///   - Table: `<table>` element (wrapped in overflow container)
///   - TableCaption: caption text
///   - TableHeader: `<thead>` element
///   - TableBody: `<tbody>` element
///   - TableFooter: `<tfoot>` element
///   - TableRow: `<tr>` element
///   - TableHead: `<th>` element (column header)
///   - TableCell: `<td>` element
///
/// Usage:
///   <Table>
///       <TableHeader>
///           <TableRow>
///               <TableHead>Name</TableHead>
///               <TableHead>Email</TableHead>
///           </TableRow>
///       </TableHeader>
///       <TableBody>
///           <TableRow>
///               <TableCell>Olivia</TableCell>
///               <TableCell>olivia@example.com</TableCell>
///           </TableRow>
///       </TableBody>
///   </Table>
pub const Icon = root.icon.Icon;
// ── Sub-components ──────────────────────────────────
pub const TableProps = struct {
    children: []const u8 = "",
};
pub fn Table(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableProps, _props);
    try writer.writeAll("<div data-publr-component=\"table\" class=\"w-full overflow-auto rounded-lg border border-border\">");
    try writer.writeAll("\n");
    try writer.writeAll("<table class=\"w-full caption-bottom\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</table>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TableCaptionProps = struct {
    children: []const u8 = "",
};
pub fn TableCaption(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableCaptionProps, _props);
    try writer.writeAll("<caption class=\"mt-4 text-sm text-muted-foreground\">");
    try writer.writeAll(props.children);
    try writer.writeAll("</caption>");
}

pub const TableHeaderProps = struct {
    children: []const u8 = "",
};
pub fn TableHeader(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableHeaderProps, _props);
    try writer.writeAll("<thead data-publr-part=\"header\" class=\"bg-muted/40\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</thead>");
}

pub const TableBodyProps = struct {
    children: []const u8 = "",
};
pub fn TableBody(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableBodyProps, _props);
    try writer.writeAll("<tbody data-publr-part=\"body\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</tbody>");
}

pub const TableFooterProps = struct {
    children: []const u8 = "",
};
pub fn TableFooter(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableFooterProps, _props);
    try writer.writeAll("<tfoot data-publr-part=\"footer\" class=\"border-t border-border bg-muted/40\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</tfoot>");
}

pub const TableRowProps = struct {
    children: []const u8 = "",
};
pub fn TableRow(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableRowProps, _props);
    try writer.writeAll("<tr class=\"border-b border-border hover:bg-accent/50 transition-colors\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</tr>");
}

pub const TableHeadProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableHead(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableHeadProps, _props);
    try writer.writeAll("<th");
    try writer.writeAll(" class=\"");
    try writer.writeAll("text-left text-xs font-medium text-muted-foreground px-3 py-2.5 ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</th>");
}

pub const TableCellProps = struct {
    children: []const u8 = "",
    class: []const u8 = "",
};
pub fn TableCell(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableCellProps, _props);
    try writer.writeAll("<td");
    try writer.writeAll(" class=\"");
    try writer.writeAll("px-3 py-2.5 text-sm text-foreground ");
    try writer.writeAll(props.class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</td>");
}

// ── Gallery Demo ────────────────────────────────────
pub const TableDemoProps = struct {
    demo: enum { basic, with_footer, with_actions } = .basic,
};
pub fn TableDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TableDemoProps, _props);
    if (props.demo == .basic) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Name");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Status");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Email");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Amount");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Olivia Martin");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Active");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("olivia@example.com");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$1,250.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Jackson Lee");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Pending");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("jackson@example.com");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$340.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Isabella Nguyen");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Inactive");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("isabella@example.com");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$720.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableBody(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Table(writer, .{ .children = _children_buf_0.items });
        }
    } else if (props.demo == .with_footer) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Name");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Email");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Amount");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Olivia Martin");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("olivia@example.com");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$1,250.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Jackson Lee");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("jackson@example.com");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$340.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableBody(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Total");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$1,590.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableFooter(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Table(writer, .{ .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("A list of recent invoices.");
                try TableCaption(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Invoice");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Status");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Method");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Amount");
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try TableHead(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableHeader(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("INV001");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Paid");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Credit Card");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$250.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("<button class=\"text-xs text-muted-foreground hover:text-foreground\">");
                        try _children_buf_3.writer(_children_alloc_3).writeAll("...");
                        try _children_buf_3.writer(_children_alloc_3).writeAll("</button>");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("INV002");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Pending");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("Bank Transfer");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("$150.00");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    {
                        var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                        const _children_alloc_3 = @import("std").heap.page_allocator;
                        defer _children_buf_3.deinit(_children_alloc_3);
                        try _children_buf_3.writer(_children_alloc_3).writeAll("<button class=\"text-xs text-muted-foreground hover:text-foreground\">");
                        try _children_buf_3.writer(_children_alloc_3).writeAll("...");
                        try _children_buf_3.writer(_children_alloc_3).writeAll("</button>");
                        try TableCell(_children_buf_2.writer(_children_alloc_2), .{ .children = _children_buf_3.items });
                    }
                    try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                    try TableRow(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TableBody(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Table(writer, .{ .children = _children_buf_0.items });
        }
    }
}

};

pub const tabs = struct {

/// Tabs — tabbed content panels.
///
/// Sub-components matching shadcn API:
///   - Tabs: root container (default_value)
///   - TabsList: tab trigger container (variant: default/line)
///   - TabsTrigger: individual tab button (value, disabled)
///   - TabsContent: individual tab panel (value)
///
/// Link triggers to panels via matching `value` prop.
///
/// Usage:
///   <Tabs default_value="account">
///       <TabsList>
///           <TabsTrigger value="account">Account</TabsTrigger>
///           <TabsTrigger value="password">Password</TabsTrigger>
///       </TabsList>
///       <TabsContent value="account">Account settings.</TabsContent>
///       <TabsContent value="password">Password settings.</TabsContent>
///   </Tabs>
// ── Sub-components ──────────────────────────────────
pub const TabsProps = struct {
    default_value: []const u8 = "",
    children: []const u8 = "",
};
pub fn Tabs(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsProps, _props);
    try writer.writeAll("<div data-publr-component=\"tabs\"");
    try writer.writeAll(" data-publr-default-value=\"");
    try runtime.render(writer, props.default_value);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const Variant = enum { default, line };
pub const TabsListProps = struct {
    variant: Variant = .default,
    children: []const u8 = "",
};
pub fn TabsList(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsListProps, _props);
    const list_class = if (props.variant == .line)
        "inline-flex items-center gap-0 border-b border-border"
    else
        "inline-flex items-center gap-1 rounded-lg bg-muted p-1";
    try writer.writeAll("<div data-publr-part=\"list\" role=\"tablist\"");
    try writer.writeAll(" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\"");
    try writer.writeAll(" class=\"");
    try runtime.render(writer, list_class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TabsTriggerProps = struct {
    value: []const u8 = "",
    disabled: bool = false,
    children: []const u8 = "",
};
pub fn TabsTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsTriggerProps, _props);
    const class = "px-3 py-1.5 text-sm font-medium rounded-md transition-colors data-[publr-state=active]:bg-background data-[publr-state=active]:text-foreground data-[publr-state=active]:shadow-xs data-[publr-state=inactive]:text-muted-foreground data-[publr-state=inactive]:hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:text-muted-foreground";
    if (props.disabled) {
        try writer.writeAll("<button data-publr-part=\"trigger\" data-publr-state=\"inactive\" role=\"tab\" aria-selected=\"false\" aria-disabled=\"true\" tabindex=\"-1\"");
        try writer.writeAll(" data-publr-tab=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" id=\"");
        try writer.writeAll("publr-tab-trigger-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-controls=\"");
        try writer.writeAll("publr-tab-content-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(" disabled=\"");
        try runtime.render(writer, true);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    } else {
        try writer.writeAll("<button data-publr-part=\"trigger\" data-publr-state=\"inactive\" role=\"tab\" aria-selected=\"false\" tabindex=\"-1\"");
        try writer.writeAll(" data-publr-tab=\"");
        try runtime.render(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" id=\"");
        try writer.writeAll("publr-tab-trigger-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" aria-controls=\"");
        try writer.writeAll("publr-tab-content-");
        try runtime.escape(writer, props.value);
        try writer.writeAll("\"");
        try writer.writeAll(" class=\"");
        try runtime.render(writer, class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("\n");
        try writer.writeAll(props.children);
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
}

pub const TabsContentProps = struct {
    value: []const u8 = "",
    children: []const u8 = "",
};
pub fn TabsContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-publr-state=\"inactive\" role=\"tabpanel\" class=\"mt-4 text-sm text-foreground\"");
    try writer.writeAll(" data-publr-tab=\"");
    try runtime.render(writer, props.value);
    try writer.writeAll("\"");
    try writer.writeAll(" id=\"");
    try writer.writeAll("publr-tab-content-");
    try runtime.escape(writer, props.value);
    try writer.writeAll("\"");
    try writer.writeAll(" aria-labelledby=\"");
    try writer.writeAll("publr-tab-trigger-");
    try runtime.escape(writer, props.value);
    try writer.writeAll("\"");
    try writer.writeAll(" hidden=\"");
    try runtime.render(writer, true);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const TabsDemoProps = struct {
    demo: enum { default, line } = .default,
    default_value: []const u8 = "tab1",
    // TabsTrigger labels (suffix _N for instance matching)
    label_1: []const u8 = "",
    label_2: []const u8 = "",
    label_3: []const u8 = "",
    // TabsContent text
    content_1: []const u8 = "",
    content_2: []const u8 = "",
    content_3: []const u8 = "",
};
pub fn TabsDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TabsDemoProps, _props);
    if (props.demo == .line) {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_1);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab1", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_2);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab2", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_3);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab3",  .disabled = true, .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsList(_children_buf_0.writer(_children_alloc_0), .{ .variant = .line, .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab1", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_2);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab2", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_3);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab3", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Tabs(writer, .{ .default_value = props.default_value, .children = _children_buf_0.items });
        }
    } else {
        {
            var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_0 = @import("std").heap.page_allocator;
            defer _children_buf_0.deinit(_children_alloc_0);
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_1);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab1", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_2);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab2", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                {
                    var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_2 = @import("std").heap.page_allocator;
                    defer _children_buf_2.deinit(_children_alloc_2);
                    try runtime.render(_children_buf_2.writer(_children_alloc_2), props.label_3);
                    try TabsTrigger(_children_buf_1.writer(_children_alloc_1), .{ .value = "tab3", .children = _children_buf_2.items });
                }
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsList(_children_buf_0.writer(_children_alloc_0), .{ .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab1", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_2);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab2", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            {
                var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_1 = @import("std").heap.page_allocator;
                defer _children_buf_1.deinit(_children_alloc_1);
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try _children_buf_1.writer(_children_alloc_1).writeAll("<p>");
                try runtime.render(_children_buf_1.writer(_children_alloc_1), props.content_3);
                try _children_buf_1.writer(_children_alloc_1).writeAll("</p>");
                try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
                try TabsContent(_children_buf_0.writer(_children_alloc_0), .{ .value = "tab3", .children = _children_buf_1.items });
            }
            try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
            try Tabs(writer, .{ .default_value = props.default_value, .children = _children_buf_0.items });
        }
    }
}

};

pub const text = struct {

/// Text — body text with constrained size and color.
///
/// Usage:
///   <Text size=.sm color=.muted>5 entries found</Text>
///   <Text size=.xs color=.destructive>Required</Text>
pub const TextSize = enum { xs, sm, md, lg };
pub const TextColor = enum { default, muted, primary, destructive, success, warning };
pub const TextWeight = enum { normal, medium, semibold, bold };
pub const TextElement = enum { p, span, div, label };
pub const TextProps = struct {
    size: TextSize = .md,
    color: TextColor = .default,
    weight: TextWeight = .normal,
    as: TextElement = .p,
    children: []const u8 = "",
};
pub fn Text(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TextProps, _props);
    const size_class = if (props.size == .xs) "text-xs" else if (props.size == .sm) "text-sm" else if (props.size == .lg) "text-lg" else "text-md";
    const color_class = if (props.color == .muted) "text-muted-foreground" else if (props.color == .primary) "text-primary" else if (props.color == .destructive) "text-destructive" else if (props.color == .success) "text-success" else if (props.color == .warning) "text-warning" else "text-foreground";
    const weight_class = if (props.weight == .medium) "font-medium" else if (props.weight == .semibold) "font-semibold" else if (props.weight == .bold) "font-bold" else "";
    if (props.as == .span) {
        try writer.writeAll("<span data-publr-component=\"text\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</span>");
    } else if (props.as == .div) {
        try writer.writeAll("<div data-publr-component=\"text\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</div>");
    } else if (props.as == .label) {
        try writer.writeAll("<label data-publr-component=\"text\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</label>");
    } else {
        try writer.writeAll("<p data-publr-component=\"text\"");
        try writer.writeAll(" class=\"");
        try writer.writeAll(size_class);
        try writer.writeAll(" ");
        try writer.writeAll(color_class);
        try writer.writeAll(" ");
        try writer.writeAll(weight_class);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll(props.children);
        try writer.writeAll("</p>");
    }
}

};

pub const toast = struct {

/// Toast — notification feedback.
///
/// Renders a toast element with variant icon (from Icon component) and close button.
/// For the gallery, renders a single visible toast preview.
///
/// In production, a ToastRegion renders hidden templates (one per variant).
/// JS `publr.toast()` clones a template, sets the message, and shows it.
///
/// Data attributes:
///   - `data-publr-component="toast"` — individual toast element
///   - `data-publr-variant="<variant>"` — variant type
///   - `data-publr-part="message"` — text content (JS sets this on clone)
///   - `data-publr-part="close"` — dismiss button
///
/// Example (JS):
///   publr.toast('Changes saved')
///   publr.toast('File uploaded', { variant: 'success' })
///   publr.toast('Something went wrong', { variant: 'error' })
pub const Icon = root.icon.Icon;
pub const Variant = enum { default, success, @"error", warning };
pub const ToastProps = struct {
    message: []const u8 = "Changes saved successfully",
    variant: Variant = .default,
    show_close: bool = true,
};
pub fn Toast(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(ToastProps, _props);
    const border_class = switch (props.variant) {
        .default => "border-border",
        .success => "border-success/30",
        .@"error" => "border-error/30",
        .warning => "border-warning/30",
    };
    try writer.writeAll("<div data-publr-component=\"toast\" class=\"pointer-events-auto\"");
    try writer.writeAll(" data-publr-variant=\"");
    try runtime.render(writer, props.variant);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll("<div");
    try writer.writeAll(" class=\"");
    try writer.writeAll("flex items-center gap-3 rounded-lg border bg-background px-4 py-3 shadow-lg ");
    try writer.writeAll(border_class);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    if (props.variant == .success) {
        try Icon(writer, .{ .name = .check,  .size = 16,  .class = "text-success shrink-0" });
    } else if (props.variant == .@"error") {
        try Icon(writer, .{ .name = .alert_hexagon,  .size = 16,  .class = "text-error shrink-0" });
    } else if (props.variant == .warning) {
        try Icon(writer, .{ .name = .alert_triangle,  .size = 16,  .class = "text-warning shrink-0" });
    }
    try writer.writeAll("\n");
    try writer.writeAll("<p data-publr-part=\"message\" class=\"text-sm text-foreground\">");
    try runtime.render(writer, props.message);
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    if (props.show_close) {
        try writer.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
        try writer.writeAll("\n");
        try Icon(writer, .{ .name = .x_close,  .size = 14,  .class = "" });
        try writer.writeAll("\n");
        try writer.writeAll("</button>");
    }
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

/// ToastRegion — hidden container holding toast templates per variant.
///
/// Render once in your layout. JS reads templates from here to create toasts.
/// Each template is a complete toast with proper icons, ready to be cloned.
///
/// Example:
///   <!-- In your layout, once -->
///   <ToastRegion />
pub const ToastRegionProps = struct {};
pub fn ToastRegion(writer: anytype, props: anytype) !void {
    _ = props;
    try writer.writeAll("<div id=\"publr-toast-region\" aria-live=\"polite\" role=\"status\" style=\"position:fixed;bottom:16px;right:16px;z-index:9999;display:flex;flex-direction:column-reverse;gap:8px;pointer-events:none;max-width:420px;\">");
    try writer.writeAll("\n");
    try writer.writeAll("<template data-publr-toast-template=\"default\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div data-publr-component=\"toast\" data-publr-variant=\"default\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"flex items-center gap-3 rounded-lg border border-border bg-background px-4 py-3 shadow-lg\">");
    try writer.writeAll("\n");
    try writer.writeAll("<p data-publr-part=\"message\" class=\"text-sm text-foreground\">");
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .x_close,  .size = 14,  .class = "" });
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</template>");
    try writer.writeAll("\n");
    try writer.writeAll("<template data-publr-toast-template=\"success\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div data-publr-component=\"toast\" data-publr-variant=\"success\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"flex items-center gap-3 rounded-lg border border-success/30 bg-background px-4 py-3 shadow-lg\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .check,  .size = 16,  .class = "text-success shrink-0" });
    try writer.writeAll("\n");
    try writer.writeAll("<p data-publr-part=\"message\" class=\"text-sm text-foreground\">");
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .x_close,  .size = 14,  .class = "" });
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</template>");
    try writer.writeAll("\n");
    try writer.writeAll("<template data-publr-toast-template=\"error\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div data-publr-component=\"toast\" data-publr-variant=\"error\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"flex items-center gap-3 rounded-lg border border-error/30 bg-background px-4 py-3 shadow-lg\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .alert_hexagon,  .size = 16,  .class = "text-error shrink-0" });
    try writer.writeAll("\n");
    try writer.writeAll("<p data-publr-part=\"message\" class=\"text-sm text-foreground\">");
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .x_close,  .size = 14,  .class = "" });
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</template>");
    try writer.writeAll("\n");
    try writer.writeAll("<template data-publr-toast-template=\"warning\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div data-publr-component=\"toast\" data-publr-variant=\"warning\" class=\"pointer-events-auto\" style=\"opacity:0;transform:translateY(8px);transition:opacity 0.2s,transform 0.2s;\">");
    try writer.writeAll("\n");
    try writer.writeAll("<div class=\"flex items-center gap-3 rounded-lg border border-warning/30 bg-background px-4 py-3 shadow-lg\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .alert_triangle,  .size = 16,  .class = "text-warning shrink-0" });
    try writer.writeAll("\n");
    try writer.writeAll("<p data-publr-part=\"message\" class=\"text-sm text-foreground\">");
    try writer.writeAll("</p>");
    try writer.writeAll("\n");
    try writer.writeAll("<button data-publr-part=\"close\" class=\"ml-auto -mr-1 text-muted-foreground hover:text-foreground transition-colors\" aria-label=\"Close\">");
    try writer.writeAll("\n");
    try Icon(writer, .{ .name = .x_close,  .size = 14,  .class = "" });
    try writer.writeAll("\n");
    try writer.writeAll("</button>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
    try writer.writeAll("\n");
    try writer.writeAll("</template>");
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

};

pub const tooltip = struct {

/// Tooltip — hover/focus-triggered floating label.
///
/// Sub-components matching Radix Tooltip API:
///   - TooltipProvider: global config (delay_duration, skip_delay_duration)
///   - Tooltip: root container (default_open, delay_duration, disable_hoverable_content)
///   - TooltipTrigger: element that triggers the tooltip
///   - TooltipPortal: portals content into document.body
///   - TooltipContent: floating label (side, alignment, side_offset, avoid_collisions, ...)
///   - TooltipArrow: optional pointing arrow (width, height)
///
/// Usage:
///   <TooltipProvider>
///       <Tooltip>
///           <TooltipTrigger><Button label="Hover me" /></TooltipTrigger>
///           <TooltipPortal>
///               <TooltipContent side=.top>
///                   Edit this item
///                   <TooltipArrow />
///               </TooltipContent>
///           </TooltipPortal>
///       </Tooltip>
///   </TooltipProvider>
pub const Button = root.button.Button;
// ── Sub-components ──────────────────────────────────
pub const DelayDuration = enum { instant, fast, default, slow };
pub const Side = enum { top, right, bottom, left };
pub const Alignment = enum { start, center, end };
pub const TooltipProviderProps = struct {
    delay_duration: DelayDuration = .default,
    skip_delay_duration: u16 = 300,
    disable_hoverable_content: bool = false,
    children: []const u8 = "",
};
pub fn TooltipProvider(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipProviderProps, _props);
    try writer.writeAll("<div data-publr-component=\"tooltip-provider\"");
    try writer.writeAll(" data-publr-delay=\"");
    try runtime.render(writer, props.delay_duration);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-skip-delay=\"");
    try runtime.render(writer, props.skip_delay_duration);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-disable-hoverable-content=\"");
    try runtime.render(writer, props.disable_hoverable_content);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TooltipProps = struct {
    default_open: bool = false,
    delay_duration: DelayDuration = .default,
    disable_hoverable_content: bool = false,
    children: []const u8 = "",
};
pub fn Tooltip(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipProps, _props);
    try writer.writeAll("<div data-publr-component=\"tooltip\" class=\"inline-block\"");
    try writer.writeAll(" data-publr-state=\"");
    try runtime.render(writer, if (props.default_open) "open" else "closed");
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-delay=\"");
    try runtime.render(writer, props.delay_duration);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-disable-hoverable-content=\"");
    try runtime.render(writer, props.disable_hoverable_content);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TooltipTriggerProps = struct {
    children: []const u8 = "",
};
pub fn TooltipTrigger(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipTriggerProps, _props);
    try writer.writeAll("<span data-publr-part=\"trigger\" data-state=\"closed\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</span>");
}

pub const TooltipPortalProps = struct {
    children: []const u8 = "",
};
pub fn TooltipPortal(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipPortalProps, _props);
    try writer.writeAll("<div data-publr-part=\"portal\">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TooltipContentProps = struct {
    side: Side = .top,
    alignment: Alignment = .center,
    side_offset: u16 = 0,
    align_offset: u16 = 0,
    avoid_collisions: bool = true,
    collision_padding: u16 = 0,
    arrow_padding: u16 = 0,
    sticky: enum { partial, always } = .partial,
    hide_when_detached: bool = false,
    aria_label: []const u8 = "",
    children: []const u8 = "",
};
pub fn TooltipContent(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipContentProps, _props);
    try writer.writeAll("<div data-publr-part=\"content\" data-state=\"closed\" role=\"tooltip\" class=\"hidden px-2.5 py-1.5 rounded-md bg-primary text-primary-foreground text-xs font-medium shadow-md whitespace-nowrap\"");
    try writer.writeAll(" data-publr-side=\"");
    try runtime.render(writer, props.side);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-align=\"");
    try runtime.render(writer, props.alignment);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-side-offset=\"");
    try runtime.render(writer, props.side_offset);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-align-offset=\"");
    try runtime.render(writer, props.align_offset);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-avoid-collisions=\"");
    try runtime.render(writer, props.avoid_collisions);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-collision-padding=\"");
    try runtime.render(writer, props.collision_padding);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-arrow-padding=\"");
    try runtime.render(writer, props.arrow_padding);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-sticky=\"");
    try runtime.render(writer, props.sticky);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-hide-when-detached=\"");
    try runtime.render(writer, props.hide_when_detached);
    try writer.writeAll("\"");
    try writer.writeAll(" aria-label=\"");
    try runtime.render(writer, props.aria_label);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("\n");
    try writer.writeAll(props.children);
    try writer.writeAll("\n");
    try writer.writeAll("</div>");
}

pub const TooltipArrowProps = struct {
    width: u16 = 10,
    height: u16 = 5,
};
pub fn TooltipArrow(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipArrowProps, _props);
    try writer.writeAll("<div data-publr-part=\"arrow\" class=\"absolute w-2.5 h-1.5 bg-primary rotate-45\"");
    try writer.writeAll(" data-publr-arrow-width=\"");
    try runtime.render(writer, props.width);
    try writer.writeAll("\"");
    try writer.writeAll(" data-publr-arrow-height=\"");
    try runtime.render(writer, props.height);
    try writer.writeAll("\"");
    try writer.writeAll(">");
    try writer.writeAll("</div>");
}

// ── Gallery Demo ────────────────────────────────────
pub const Demo = enum { default };
pub const TooltipDemoProps = struct {
    demo: Demo = .default,
    // TooltipContent
    side: Side = .top,
    alignment: Alignment = .center,
    // Tooltip
    delay_duration: DelayDuration = .default,
    // Content text
    text: []const u8 = "",
    // Trigger label
    trigger_label: []const u8 = "",
};
pub fn TooltipDemo(writer: anytype, _props: anytype) !void {
const props = runtime.withDefaults(TooltipDemoProps, _props);
    {
        var _children_buf_0: @import("std").ArrayListUnmanaged(u8) = .{};
        const _children_alloc_0 = @import("std").heap.page_allocator;
        defer _children_buf_0.deinit(_children_alloc_0);
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        {
            var _children_buf_1: @import("std").ArrayListUnmanaged(u8) = .{};
            const _children_alloc_1 = @import("std").heap.page_allocator;
            defer _children_buf_1.deinit(_children_alloc_1);
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try Button(_children_buf_2.writer(_children_alloc_2), .{ .hierarchy = .secondary,  .label = props.trigger_label,  .size = .sm });
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try TooltipTrigger(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
            }
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            {
                var _children_buf_2: @import("std").ArrayListUnmanaged(u8) = .{};
                const _children_alloc_2 = @import("std").heap.page_allocator;
                defer _children_buf_2.deinit(_children_alloc_2);
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                {
                    var _children_buf_3: @import("std").ArrayListUnmanaged(u8) = .{};
                    const _children_alloc_3 = @import("std").heap.page_allocator;
                    defer _children_buf_3.deinit(_children_alloc_3);
                    try runtime.render(_children_buf_3.writer(_children_alloc_3), props.text);
                    try TooltipContent(_children_buf_2.writer(_children_alloc_2), .{ .side = props.side,  .alignment = props.alignment, .children = _children_buf_3.items });
                }
                try _children_buf_2.writer(_children_alloc_2).writeAll("\n");
                try TooltipPortal(_children_buf_1.writer(_children_alloc_1), .{ .children = _children_buf_2.items });
            }
            try _children_buf_1.writer(_children_alloc_1).writeAll("\n");
            try Tooltip(_children_buf_0.writer(_children_alloc_0), .{ .delay_duration = props.delay_duration, .children = _children_buf_1.items });
        }
        try _children_buf_0.writer(_children_alloc_0).writeAll("\n");
        try TooltipProvider(writer, .{ .children = _children_buf_0.items });
    }
}

};

pub const css =
    \\/*! tailwindcss v4.2.2 | MIT License | https://tailwindcss.com */
    \\@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-translate-x:0;--tw-translate-y:0;--tw-translate-z:0;--tw-rotate-x:initial;--tw-rotate-y:initial;--tw-rotate-z:initial;--tw-skew-x:initial;--tw-skew-y:initial;--tw-space-y-reverse:0;--tw-space-x-reverse:0;--tw-divide-y-reverse:0;--tw-border-style:solid;--tw-leading:initial;--tw-font-weight:initial;--tw-tracking:initial;--tw-shadow:0 0 #0000;--tw-shadow-color:initial;--tw-shadow-alpha:100%;--tw-inset-shadow:0 0 #0000;--tw-inset-shadow-color:initial;--tw-inset-shadow-alpha:100%;--tw-ring-color:initial;--tw-ring-shadow:0 0 #0000;--tw-inset-ring-color:initial;--tw-inset-ring-shadow:0 0 #0000;--tw-ring-inset:initial;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-offset-shadow:0 0 #0000;--tw-outline-style:solid;--tw-blur:initial;--tw-brightness:initial;--tw-contrast:initial;--tw-grayscale:initial;--tw-hue-rotate:initial;--tw-invert:initial;--tw-opacity:initial;--tw-saturate:initial;--tw-sepia:initial;--tw-drop-shadow:initial;--tw-drop-shadow-color:initial;--tw-drop-shadow-alpha:100%;--tw-drop-shadow-size:initial}}}@layer theme{:root,:host{--font-sans:"Geist", -apple-system, BlinkMacSystemFont, sans-serif;--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--color-gray-50:oklch(98.5% .002 247.839);--color-gray-100:oklch(96.7% .003 264.542);--color-gray-200:oklch(92.8% .006 264.531);--color-gray-300:oklch(87.2% .01 258.338);--color-gray-400:oklch(70.7% .022 261.325);--color-gray-500:oklch(55.1% .027 264.364);--color-gray-600:oklch(44.6% .03 256.802);--color-gray-700:oklch(37.3% .034 259.733);--color-gray-800:oklch(27.8% .033 256.848);--color-gray-900:oklch(21% .034 264.665);--color-gray-950:oklch(13% .028 261.692);--color-black:#000;--color-white:#fff;--spacing:.25rem;--container-sm:24rem;--container-md:28rem;--font-weight-medium:500;--font-weight-semibold:600;--tracking-tight:-.025em;--tracking-wider:.05em;--leading-relaxed:1.625;--animate-spin:spin 1s linear infinite;--default-transition-duration:.15s;--default-transition-timing-function:cubic-bezier(.4, 0, .2, 1);--default-font-family:"Geist", -apple-system, BlinkMacSystemFont, sans-serif;--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;-webkit-text-decoration:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab, red, red)){::placeholder{color:color-mix(in oklab, currentcolor 50%, transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}*{border-color:var(--border)}body{background-color:var(--background);color:var(--foreground);font-family:var(--font-sans);margin:0}}@layer components{[data-publr-component=avatar-group]>[data-publr-component=avatar]{box-shadow:0 0 0 2px var(--background)}}@layer utilities{.pointer-events-auto{pointer-events:auto}.pointer-events-none{pointer-events:none}.collapse{visibility:collapse}.visible{visibility:visible}.sr-only{clip-path:inset(50%);white-space:nowrap;border-width:0;width:1px;height:1px;margin:-1px;padding:0;position:absolute;overflow:hidden}.absolute{position:absolute}.fixed{position:fixed}.relative{position:relative}.static{position:static}.sticky{position:sticky}.inset-0{inset:calc(var(--spacing) * 0)}.inset-y-0{inset-block:calc(var(--spacing) * 0)}.start{inset-inline-start:var(--spacing)}.end{inset-inline-end:var(--spacing)}.top-1{top:calc(var(--spacing) * 1)}.top-1\/2{top:50%}.right-0{right:calc(var(--spacing) * 0)}.bottom-0{bottom:calc(var(--spacing) * 0)}.left-0{left:calc(var(--spacing) * 0)}.left-0\.5{left:calc(var(--spacing) * .5)}.left-2{left:calc(var(--spacing) * 2)}.left-2\.5{left:calc(var(--spacing) * 2.5)}.z-50{z-index:50}.container{width:100%}@media (min-width:40rem){.container{max-width:40rem}}@media (min-width:48rem){.container{max-width:48rem}}@media (min-width:64rem){.container{max-width:64rem}}@media (min-width:80rem){.container{max-width:80rem}}@media (min-width:96rem){.container{max-width:96rem}}.m-0{margin:calc(var(--spacing) * 0)}.mx-1{margin-inline:calc(var(--spacing) * 1)}.mx-4{margin-inline:calc(var(--spacing) * 4)}.my-1{margin-block:calc(var(--spacing) * 1)}.my-4{margin-block:calc(var(--spacing) * 4)}.mt-0{margin-top:calc(var(--spacing) * 0)}.mt-0\.5{margin-top:calc(var(--spacing) * .5)}.mt-1{margin-top:calc(var(--spacing) * 1)}.mt-2{margin-top:calc(var(--spacing) * 2)}.mt-3{margin-top:calc(var(--spacing) * 3)}.mt-4{margin-top:calc(var(--spacing) * 4)}.mt-6{margin-top:calc(var(--spacing) * 6)}.-mr-1{margin-right:calc(var(--spacing) * -1)}.mr-0\.5{margin-right:calc(var(--spacing) * .5)}.mb-2{margin-bottom:calc(var(--spacing) * 2)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.mb-4{margin-bottom:calc(var(--spacing) * 4)}.ml-0\.5{margin-left:calc(var(--spacing) * .5)}.ml-1\.5{margin-left:calc(var(--spacing) * 1.5)}.ml-2{margin-left:calc(var(--spacing) * 2)}.ml-3{margin-left:calc(var(--spacing) * 3)}.ml-auto{margin-left:auto}.block{display:block}.contents{display:contents}.flex{display:flex}.grid{display:grid}.hidden{display:none}.inline{display:inline}.inline-block{display:inline-block}.inline-flex{display:inline-flex}.table{display:table}.h-1\.5{height:calc(var(--spacing) * 1.5)}.h-2\.5{height:calc(var(--spacing) * 2.5)}.h-3{height:calc(var(--spacing) * 3)}.h-3\.5{height:calc(var(--spacing) * 3.5)}.h-4{height:calc(var(--spacing) * 4)}.h-5{height:calc(var(--spacing) * 5)}.h-6{height:calc(var(--spacing) * 6)}.h-7{height:calc(var(--spacing) * 7)}.h-8{height:calc(var(--spacing) * 8)}.h-10{height:calc(var(--spacing) * 10)}.h-14{height:calc(var(--spacing) * 14)}.h-\[25vh\]{height:25vh}.h-full{height:100%}.h-px{height:1px}.h-screen{height:100vh}.min-h-0{min-height:calc(var(--spacing) * 0)}.min-h-20{min-height:calc(var(--spacing) * 20)}.w-2{width:calc(var(--spacing) * 2)}.w-2\.5{width:calc(var(--spacing) * 2.5)}.w-2\/5{width:40%}.w-3{width:calc(var(--spacing) * 3)}.w-3\.5{width:calc(var(--spacing) * 3.5)}.w-4{width:calc(var(--spacing) * 4)}.w-5{width:calc(var(--spacing) * 5)}.w-6{width:calc(var(--spacing) * 6)}.w-7{width:calc(var(--spacing) * 7)}.w-8{width:calc(var(--spacing) * 8)}.w-10{width:calc(var(--spacing) * 10)}.w-12{width:calc(var(--spacing) * 12)}.w-14{width:calc(var(--spacing) * 14)}.w-48{width:calc(var(--spacing) * 48)}.w-56{width:calc(var(--spacing) * 56)}.w-72{width:calc(var(--spacing) * 72)}.w-full{width:100%}.max-w-md{max-width:var(--container-md)}.max-w-sm{max-width:var(--container-sm)}.min-w-0{min-width:calc(var(--spacing) * 0)}.min-w-48{min-width:calc(var(--spacing) * 48)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.caption-bottom{caption-side:bottom}.-translate-y-1{--tw-translate-y:calc(var(--spacing) * -1);translate:var(--tw-translate-x) var(--tw-translate-y)}.-translate-y-1\/2{--tw-translate-y:calc(calc(1 / 2 * 100%) * -1);translate:var(--tw-translate-x) var(--tw-translate-y)}.rotate-45{rotate:45deg}.transform{transform:var(--tw-rotate-x,) var(--tw-rotate-y,) var(--tw-rotate-z,) var(--tw-skew-x,) var(--tw-skew-y,)}.animate-spin{animation:var(--animate-spin)}.cursor-default{cursor:default}.cursor-not-allowed{cursor:not-allowed}.cursor-pointer{cursor:pointer}.resize-y{resize:vertical}.grid-cols-\[repeat\(auto-fill\,minmax\(200px\,1fr\)\)\]{grid-template-columns:repeat(auto-fill,minmax(200px,1fr))}.flex-col{flex-direction:column}.flex-row{flex-direction:row}.flex-wrap{flex-wrap:wrap}.items-center{align-items:center}.items-start{align-items:flex-start}.justify-between{justify-content:space-between}.justify-center{justify-content:center}.justify-end{justify-content:flex-end}.gap-0{gap:calc(var(--spacing) * 0)}.gap-0\.5{gap:calc(var(--spacing) * .5)}.gap-1{gap:calc(var(--spacing) * 1)}.gap-1\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-2\.5{gap:calc(var(--spacing) * 2.5)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}.gap-5{gap:calc(var(--spacing) * 5)}:where(.space-y-0\.5>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(calc(var(--spacing) * .5) * var(--tw-space-y-reverse));margin-block-end:calc(calc(var(--spacing) * .5) * calc(1 - var(--tw-space-y-reverse)))}:where(.space-y-1\.5>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(calc(var(--spacing) * 1.5) * var(--tw-space-y-reverse));margin-block-end:calc(calc(var(--spacing) * 1.5) * calc(1 - var(--tw-space-y-reverse)))}:where(.space-y-3>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(calc(var(--spacing) * 3) * var(--tw-space-y-reverse));margin-block-end:calc(calc(var(--spacing) * 3) * calc(1 - var(--tw-space-y-reverse)))}:where(.space-y-6>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(calc(var(--spacing) * 6) * var(--tw-space-y-reverse));margin-block-end:calc(calc(var(--spacing) * 6) * calc(1 - var(--tw-space-y-reverse)))}:where(.-space-x-2>:not(:last-child)){--tw-space-x-reverse:0;margin-inline-start:calc(calc(var(--spacing) * -2) * var(--tw-space-x-reverse));margin-inline-end:calc(calc(var(--spacing) * -2) * calc(1 - var(--tw-space-x-reverse)))}:where(.divide-y>:not(:last-child)){--tw-divide-y-reverse:0;border-bottom-style:var(--tw-border-style);border-top-style:var(--tw-border-style);border-top-width:calc(1px * var(--tw-divide-y-reverse));border-bottom-width:calc(1px * calc(1 - var(--tw-divide-y-reverse)))}:where(.divide-gray-100>:not(:last-child)){border-color:var(--color-gray-100)}.truncate{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.overflow-auto{overflow:auto}.overflow-hidden{overflow:hidden}.overflow-y-auto{overflow-y:auto}.rounded{border-radius:.25rem}.rounded-full{border-radius:3.40282e38px}.rounded-lg{border-radius:var(--radius)}.rounded-md{border-radius:calc(var(--radius) * .8)}.rounded-xl{border-radius:calc(var(--radius) * 1.4)}.border{border-style:var(--tw-border-style);border-width:1px}.border-2{border-style:var(--tw-border-style);border-width:2px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-r{border-right-style:var(--tw-border-style);border-right-width:1px}.border-b{border-bottom-style:var(--tw-border-style);border-bottom-width:1px}.border-l-2{border-left-style:var(--tw-border-style);border-left-width:2px}.border-background{border-color:var(--background)}.border-border{border-color:var(--border)}.border-error,.border-error\/20{border-color:var(--error)}@supports (color:color-mix(in lab, red, red)){.border-error\/20{border-color:color-mix(in oklab, var(--error) 20%, transparent)}}.border-error\/30{border-color:var(--error)}@supports (color:color-mix(in lab, red, red)){.border-error\/30{border-color:color-mix(in oklab, var(--error) 30%, transparent)}}.border-gray-200{border-color:var(--color-gray-200)}.border-gray-300{border-color:var(--color-gray-300)}.border-gray-700{border-color:var(--color-gray-700)}.border-gray-800{border-color:var(--color-gray-800)}.border-input{border-color:var(--input)}.border-sidebar-border{border-color:var(--sidebar-border)}.border-success\/20{border-color:var(--success)}@supports (color:color-mix(in lab, red, red)){.border-success\/20{border-color:color-mix(in oklab, var(--success) 20%, transparent)}}.border-success\/30{border-color:var(--success)}@supports (color:color-mix(in lab, red, red)){.border-success\/30{border-color:color-mix(in oklab, var(--success) 30%, transparent)}}.border-transparent{border-color:#0000}.border-warning\/20{border-color:var(--warning)}@supports (color:color-mix(in lab, red, red)){.border-warning\/20{border-color:color-mix(in oklab, var(--warning) 20%, transparent)}}.border-warning\/30{border-color:var(--warning)}@supports (color:color-mix(in lab, red, red)){.border-warning\/30{border-color:color-mix(in oklab, var(--warning) 30%, transparent)}}.bg-accent,.bg-accent\/50{background-color:var(--accent)}@supports (color:color-mix(in lab, red, red)){.bg-accent\/50{background-color:color-mix(in oklab, var(--accent) 50%, transparent)}}.bg-background{background-color:var(--background)}.bg-black{background-color:var(--color-black)}.bg-black\/50{background-color:#00000080}@supports (color:color-mix(in lab, red, red)){.bg-black\/50{background-color:color-mix(in oklab, var(--color-black) 50%, transparent)}}.bg-border{background-color:var(--border)}.bg-card{background-color:var(--card)}.bg-destructive,.bg-destructive\/10{background-color:var(--destructive)}@supports (color:color-mix(in lab, red, red)){.bg-destructive\/10{background-color:color-mix(in oklab, var(--destructive) 10%, transparent)}}.bg-error,.bg-error\/10{background-color:var(--error)}@supports (color:color-mix(in lab, red, red)){.bg-error\/10{background-color:color-mix(in oklab, var(--error) 10%, transparent)}}.bg-gray-50{background-color:var(--color-gray-50)}.bg-gray-100{background-color:var(--color-gray-100)}.bg-gray-200{background-color:var(--color-gray-200)}.bg-gray-700{background-color:var(--color-gray-700)}.bg-gray-800{background-color:var(--color-gray-800)}.bg-gray-900{background-color:var(--color-gray-900)}.bg-gray-950{background-color:var(--color-gray-950)}.bg-input{background-color:var(--input)}.bg-muted,.bg-muted\/40{background-color:var(--muted)}@supports (color:color-mix(in lab, red, red)){.bg-muted\/40{background-color:color-mix(in oklab, var(--muted) 40%, transparent)}}.bg-popover{background-color:var(--popover)}.bg-primary{background-color:var(--primary)}.bg-secondary{background-color:var(--secondary)}.bg-sidebar{background-color:var(--sidebar)}.bg-sidebar-accent{background-color:var(--sidebar-accent)}.bg-sidebar-primary{background-color:var(--sidebar-primary)}.bg-success,.bg-success\/10{background-color:var(--success)}@supports (color:color-mix(in lab, red, red)){.bg-success\/10{background-color:color-mix(in oklab, var(--success) 10%, transparent)}}.bg-transparent{background-color:#0000}.bg-warning,.bg-warning\/10{background-color:var(--warning)}@supports (color:color-mix(in lab, red, red)){.bg-warning\/10{background-color:color-mix(in oklab, var(--warning) 10%, transparent)}}.bg-white{background-color:var(--color-white)}.object-cover{object-fit:cover}.p-1{padding:calc(var(--spacing) * 1)}.p-3{padding:calc(var(--spacing) * 3)}.p-4{padding:calc(var(--spacing) * 4)}.p-6{padding:calc(var(--spacing) * 6)}.px-1\.5{padding-inline:calc(var(--spacing) * 1.5)}.px-2{padding-inline:calc(var(--spacing) * 2)}.px-2\.5{padding-inline:calc(var(--spacing) * 2.5)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-3\.5{padding-inline:calc(var(--spacing) * 3.5)}.px-4{padding-inline:calc(var(--spacing) * 4)}.px-5{padding-inline:calc(var(--spacing) * 5)}.px-\[30px\]{padding-inline:30px}.py-0\.5{padding-block:calc(var(--spacing) * .5)}.py-1{padding-block:calc(var(--spacing) * 1)}.py-1\.5{padding-block:calc(var(--spacing) * 1.5)}.py-2{padding-block:calc(var(--spacing) * 2)}.py-2\.5{padding-block:calc(var(--spacing) * 2.5)}.py-3{padding-block:calc(var(--spacing) * 3)}.py-4{padding-block:calc(var(--spacing) * 4)}.py-12{padding-block:calc(var(--spacing) * 12)}.pt-0{padding-top:calc(var(--spacing) * 0)}.pt-2{padding-top:calc(var(--spacing) * 2)}.pr-3{padding-right:calc(var(--spacing) * 3)}.pr-10{padding-right:calc(var(--spacing) * 10)}.pb-0{padding-bottom:calc(var(--spacing) * 0)}.pb-4{padding-bottom:calc(var(--spacing) * 4)}.pl-3{padding-left:calc(var(--spacing) * 3)}.pl-8{padding-left:calc(var(--spacing) * 8)}.pl-10{padding-left:calc(var(--spacing) * 10)}.text-center{text-align:center}.text-left{text-align:left}.text-lg{font-size:1.125rem;line-height:var(--tw-leading,1.75rem)}.text-md{font-size:1rem;line-height:var(--tw-leading,1.5rem)}.text-sm{font-size:.875rem;line-height:var(--tw-leading,1.25rem)}.text-xs{font-size:.75rem;line-height:var(--tw-leading,1.125rem)}.text-\[10px\]{font-size:10px}.leading-relaxed{--tw-leading:var(--leading-relaxed);line-height:var(--leading-relaxed)}.font-medium{--tw-font-weight:var(--font-weight-medium);font-weight:var(--font-weight-medium)}.font-semibold{--tw-font-weight:var(--font-weight-semibold);font-weight:var(--font-weight-semibold)}.tracking-tight{--tw-tracking:var(--tracking-tight);letter-spacing:var(--tracking-tight)}.tracking-wider{--tw-tracking:var(--tracking-wider);letter-spacing:var(--tracking-wider)}.whitespace-nowrap{white-space:nowrap}.text-accent-foreground{color:var(--accent-foreground)}.text-card-foreground{color:var(--card-foreground)}.text-destructive{color:var(--destructive)}.text-error{color:var(--error)}.text-error-foreground{color:var(--error-foreground)}.text-foreground{color:var(--foreground)}.text-gray-300{color:var(--color-gray-300)}.text-gray-400{color:var(--color-gray-400)}.text-gray-500{color:var(--color-gray-500)}.text-gray-600{color:var(--color-gray-600)}.text-gray-700{color:var(--color-gray-700)}.text-gray-900{color:var(--color-gray-900)}.text-muted-foreground{color:var(--muted-foreground)}.text-popover-foreground{color:var(--popover-foreground)}.text-primary{color:var(--primary)}.text-primary-foreground{color:var(--primary-foreground)}.text-secondary-foreground{color:var(--secondary-foreground)}.text-sidebar-accent-foreground{color:var(--sidebar-accent-foreground)}.text-sidebar-foreground{color:var(--sidebar-foreground)}.text-sidebar-primary-foreground{color:var(--sidebar-primary-foreground)}.text-success{color:var(--success)}.text-success-foreground{color:var(--success-foreground)}.text-warning{color:var(--warning)}.text-warning-foreground{color:var(--warning-foreground)}.text-white{color:var(--color-white)}.uppercase{text-transform:uppercase}.placeholder-muted-foreground::placeholder{color:var(--muted-foreground)}.accent-foreground{accent-color:var(--foreground)}.accent-primary{accent-color:var(--primary)}.opacity-0{opacity:0}.opacity-50{opacity:.5}.shadow{--tw-shadow:0 1px 3px 0 var(--tw-shadow-color,#0000001a), 0 1px 2px -1px var(--tw-shadow-color,#0000001a);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.shadow-lg{--tw-shadow:0 8px 24px var(--tw-shadow-color,oklch(0% 0 0/.12));box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.shadow-md{--tw-shadow:0 2px 8px var(--tw-shadow-color,oklch(0% 0 0/.08));box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.shadow-sm{--tw-shadow:0 1px 3px 0 var(--tw-shadow-color,oklch(0% 0 0/.06));box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.shadow-xl{--tw-shadow:0 20px 25px -5px var(--tw-shadow-color,#0000001a), 0 8px 10px -6px var(--tw-shadow-color,#0000001a);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.shadow-xs{--tw-shadow:0 1px 2px 0 var(--tw-shadow-color,oklch(0% 0 0/.05));box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.ring,.ring-1{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.ring-error{--tw-ring-color:var(--error)}.ring-ring{--tw-ring-color:var(--ring)}.outline{outline-style:var(--tw-outline-style);outline-width:1px}.blur{--tw-blur:blur(8px);filter:var(--tw-blur,) var(--tw-brightness,) var(--tw-contrast,) var(--tw-grayscale,) var(--tw-hue-rotate,) var(--tw-invert,) var(--tw-saturate,) var(--tw-sepia,) var(--tw-drop-shadow,)}.filter{filter:var(--tw-blur,) var(--tw-brightness,) var(--tw-contrast,) var(--tw-grayscale,) var(--tw-hue-rotate,) var(--tw-invert,) var(--tw-saturate,) var(--tw-sepia,) var(--tw-drop-shadow,)}.transition{transition-property:color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to,opacity,box-shadow,transform,translate,scale,rotate,filter,-webkit-backdrop-filter,backdrop-filter,display,content-visibility,overlay,pointer-events;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration))}.transition-colors{transition-property:color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration))}.transition-opacity{transition-property:opacity;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration))}.transition-transform{transition-property:transform,translate,scale,rotate;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration))}.outline-none{--tw-outline-style:none;outline-style:none}.select-all{-webkit-user-select:all;user-select:all}.group-data-\[publr-state\=open\]\:pointer-events-auto:is(:where(.group)[data-publr-state=open] *){pointer-events:auto}.group-data-\[publr-state\=open\]\:block:is(:where(.group)[data-publr-state=open] *){display:block}.group-data-\[publr-state\=open\]\:opacity-100:is(:where(.group)[data-publr-state=open] *),.group-data-\[publr-state\=selected\]\:opacity-100:is(:where(.group)[data-publr-state=selected] *){opacity:1}.peer-checked\:translate-x-4:is(:where(.peer):checked~*){--tw-translate-x:calc(var(--spacing) * 4);translate:var(--tw-translate-x) var(--tw-translate-y)}.peer-checked\:translate-x-5:is(:where(.peer):checked~*){--tw-translate-x:calc(var(--spacing) * 5);translate:var(--tw-translate-x) var(--tw-translate-y)}.peer-checked\:translate-x-6:is(:where(.peer):checked~*){--tw-translate-x:calc(var(--spacing) * 6);translate:var(--tw-translate-x) var(--tw-translate-y)}.peer-checked\:bg-primary:is(:where(.peer):checked~*){background-color:var(--primary)}.file\:border-0::file-selector-button{border-style:var(--tw-border-style);border-width:0}.file\:bg-transparent::file-selector-button{background-color:#0000}.file\:text-sm::file-selector-button{font-size:.875rem;line-height:var(--tw-leading,1.25rem)}.file\:text-foreground::file-selector-button{color:var(--foreground)}.placeholder\:text-muted-foreground::placeholder{color:var(--muted-foreground)}@media (hover:hover){.hover\:bg-accent:hover,.hover\:bg-accent\/50:hover{background-color:var(--accent)}@supports (color:color-mix(in lab, red, red)){.hover\:bg-accent\/50:hover{background-color:color-mix(in oklab, var(--accent) 50%, transparent)}}.hover\:bg-destructive\/10:hover{background-color:var(--destructive)}@supports (color:color-mix(in lab, red, red)){.hover\:bg-destructive\/10:hover{background-color:color-mix(in oklab, var(--destructive) 10%, transparent)}}.hover\:bg-destructive\/90:hover{background-color:var(--destructive)}@supports (color:color-mix(in lab, red, red)){.hover\:bg-destructive\/90:hover{background-color:color-mix(in oklab, var(--destructive) 90%, transparent)}}.hover\:bg-gray-50:hover{background-color:var(--color-gray-50)}.hover\:bg-gray-700:hover{background-color:var(--color-gray-700)}.hover\:bg-primary\/90:hover{background-color:var(--primary)}@supports (color:color-mix(in lab, red, red)){.hover\:bg-primary\/90:hover{background-color:color-mix(in oklab, var(--primary) 90%, transparent)}}.hover\:bg-sidebar-accent:hover{background-color:var(--sidebar-accent)}.hover\:text-accent-foreground:hover{color:var(--accent-foreground)}.hover\:text-foreground:hover{color:var(--foreground)}.hover\:text-gray-600:hover{color:var(--color-gray-600)}.hover\:text-gray-700:hover{color:var(--color-gray-700)}.hover\:text-primary\/80:hover{color:var(--primary)}@supports (color:color-mix(in lab, red, red)){.hover\:text-primary\/80:hover{color:color-mix(in oklab, var(--primary) 80%, transparent)}}.hover\:text-sidebar-accent-foreground:hover{color:var(--sidebar-accent-foreground)}.hover\:text-sidebar-foreground:hover{color:var(--sidebar-foreground)}.hover\:text-white:hover{color:var(--color-white)}}.focus\:border-sidebar-ring:focus{border-color:var(--sidebar-ring)}.focus\:ring-1:focus{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.focus\:ring-2:focus{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.focus\:ring-sidebar-ring:focus{--tw-ring-color:var(--sidebar-ring)}.focus\:ring-offset-2:focus{--tw-ring-offset-width:2px;--tw-ring-offset-shadow:var(--tw-ring-inset,) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color)}.focus\:outline-hidden:focus{--tw-outline-style:none;outline-style:none}@media (forced-colors:active){.focus\:outline-hidden:focus{outline-offset:2px;outline:2px solid #0000}}.focus-visible\:bg-accent:focus-visible{background-color:var(--accent)}.focus-visible\:bg-destructive\/10:focus-visible{background-color:var(--destructive)}@supports (color:color-mix(in lab, red, red)){.focus-visible\:bg-destructive\/10:focus-visible{background-color:color-mix(in oklab, var(--destructive) 10%, transparent)}}.focus-visible\:text-accent-foreground:focus-visible{color:var(--accent-foreground)}.focus-visible\:ring-2:focus-visible{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.focus-visible\:ring-4:focus-visible{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(4px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.focus-visible\:ring-ring:focus-visible{--tw-ring-color:var(--ring)}.focus-visible\:ring-offset-2:focus-visible{--tw-ring-offset-width:2px;--tw-ring-offset-shadow:var(--tw-ring-inset,) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color)}.focus-visible\:outline-hidden:focus-visible{--tw-outline-style:none;outline-style:none}@media (forced-colors:active){.focus-visible\:outline-hidden:focus-visible{outline-offset:2px;outline:2px solid #0000}}.focus-visible\:outline-none:focus-visible{--tw-outline-style:none;outline-style:none}.disabled\:pointer-events-none:disabled{pointer-events:none}.disabled\:cursor-not-allowed:disabled{cursor:not-allowed}.disabled\:text-muted-foreground:disabled{color:var(--muted-foreground)}.disabled\:opacity-50:disabled{opacity:.5}@media (hover:hover){.disabled\:hover\:text-muted-foreground:disabled:hover{color:var(--muted-foreground)}}.data-\[publr-state\=active\]\:bg-background[data-publr-state=active]{background-color:var(--background)}.data-\[publr-state\=active\]\:text-foreground[data-publr-state=active]{color:var(--foreground)}.data-\[publr-state\=active\]\:shadow-xs[data-publr-state=active]{--tw-shadow:0 1px 2px 0 var(--tw-shadow-color,oklch(0% 0 0/.05));box-shadow:var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)}.data-\[publr-state\=inactive\]\:text-muted-foreground[data-publr-state=inactive]{color:var(--muted-foreground)}@media (hover:hover){.data-\[publr-state\=inactive\]\:hover\:text-foreground[data-publr-state=inactive]:hover{color:var(--foreground)}}.data-\[publr-state\=open\]\:pointer-events-auto[data-publr-state=open]{pointer-events:auto}.data-\[publr-state\=open\]\:opacity-100[data-publr-state=open]{opacity:1}}:root{--radius:.5rem;--background:oklch(100% 0 0);--foreground:oklch(14.5% 0 0);--card:oklch(100% 0 0);--card-foreground:oklch(14.5% 0 0);--popover:oklch(100% 0 0);--popover-foreground:oklch(14.5% 0 0);--primary:oklch(55% .17 250);--primary-foreground:oklch(98.5% 0 0);--secondary:oklch(97% 0 0);--secondary-foreground:oklch(20.5% 0 0);--muted:oklch(97% 0 0);--muted-foreground:oklch(55.6% 0 0);--accent:oklch(97% 0 0);--accent-foreground:oklch(20.5% 0 0);--destructive:oklch(57.7% .245 27.325);--error:oklch(57.7% .245 27.325);--error-foreground:oklch(98.5% 0 0);--success:oklch(56% .16 145);--success-foreground:oklch(98.5% 0 0);--warning:oklch(68% .16 75);--warning-foreground:oklch(21% .034 46);--border:oklch(92.2% 0 0);--input:oklch(88.2% 0 0);--ring:oklch(55% .17 250);--sidebar:oklch(98.5% 0 0);--sidebar-foreground:oklch(14.5% 0 0);--sidebar-primary:oklch(55% .17 250);--sidebar-primary-foreground:oklch(98.5% 0 0);--sidebar-accent:oklch(97% 0 0);--sidebar-accent-foreground:oklch(20.5% 0 0);--sidebar-border:oklch(92.2% 0 0);--sidebar-ring:oklch(55% .17 250)}.dark{--background:oklch(14.5% 0 0);--foreground:oklch(98.5% 0 0);--card:oklch(20.5% 0 0);--card-foreground:oklch(98.5% 0 0);--popover:oklch(20.5% 0 0);--popover-foreground:oklch(98.5% 0 0);--primary:oklch(65% .17 250);--primary-foreground:oklch(14.5% 0 0);--secondary:oklch(26.9% 0 0);--secondary-foreground:oklch(98.5% 0 0);--muted:oklch(26.9% 0 0);--muted-foreground:oklch(70.8% 0 0);--accent:oklch(26.9% 0 0);--accent-foreground:oklch(98.5% 0 0);--destructive:oklch(70.4% .191 22.216);--error:oklch(70.4% .191 22.216);--error-foreground:oklch(98.5% 0 0);--success:oklch(65% .16 145);--success-foreground:oklch(14.5% 0 0);--warning:oklch(75% .16 75);--warning-foreground:oklch(14.5% 0 0);--border:oklch(100% 0 0/.1);--input:oklch(100% 0 0/.15);--ring:oklch(65% .17 250);--sidebar:oklch(20.5% 0 0);--sidebar-foreground:oklch(98.5% 0 0);--sidebar-primary:oklch(65% .17 250);--sidebar-primary-foreground:oklch(98.5% 0 0);--sidebar-accent:oklch(26.9% 0 0);--sidebar-accent-foreground:oklch(98.5% 0 0);--sidebar-border:oklch(100% 0 0/.1);--sidebar-ring:oklch(65% .17 250)}@property --tw-translate-x{syntax:"*";inherits:false;initial-value:0}@property --tw-translate-y{syntax:"*";inherits:false;initial-value:0}@property --tw-translate-z{syntax:"*";inherits:false;initial-value:0}@property --tw-rotate-x{syntax:"*";inherits:false}@property --tw-rotate-y{syntax:"*";inherits:false}@property --tw-rotate-z{syntax:"*";inherits:false}@property --tw-skew-x{syntax:"*";inherits:false}@property --tw-skew-y{syntax:"*";inherits:false}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-space-x-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-divide-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}@property --tw-leading{syntax:"*";inherits:false}@property --tw-font-weight{syntax:"*";inherits:false}@property --tw-tracking{syntax:"*";inherits:false}@property --tw-shadow{syntax:"*";inherits:false;initial-value:0 0 #0000}@property --tw-shadow-color{syntax:"*";inherits:false}@property --tw-shadow-alpha{syntax:"<percentage>";inherits:false;initial-value:100%}@property --tw-inset-shadow{syntax:"*";inherits:false;initial-value:0 0 #0000}@property --tw-inset-shadow-color{syntax:"*";inherits:false}@property --tw-inset-shadow-alpha{syntax:"<percentage>";inherits:false;initial-value:100%}@property --tw-ring-color{syntax:"*";inherits:false}@property --tw-ring-shadow{syntax:"*";inherits:false;initial-value:0 0 #0000}@property --tw-inset-ring-color{syntax:"*";inherits:false}@property --tw-inset-ring-shadow{syntax:"*";inherits:false;initial-value:0 0 #0000}@property --tw-ring-inset{syntax:"*";inherits:false}@property --tw-ring-offset-width{syntax:"<length>";inherits:false;initial-value:0}@property --tw-ring-offset-color{syntax:"*";inherits:false;initial-value:#fff}@property --tw-ring-offset-shadow{syntax:"*";inherits:false;initial-value:0 0 #0000}@property --tw-outline-style{syntax:"*";inherits:false;initial-value:solid}@property --tw-blur{syntax:"*";inherits:false}@property --tw-brightness{syntax:"*";inherits:false}@property --tw-contrast{syntax:"*";inherits:false}@property --tw-grayscale{syntax:"*";inherits:false}@property --tw-hue-rotate{syntax:"*";inherits:false}@property --tw-invert{syntax:"*";inherits:false}@property --tw-opacity{syntax:"*";inherits:false}@property --tw-saturate{syntax:"*";inherits:false}@property --tw-sepia{syntax:"*";inherits:false}@property --tw-drop-shadow{syntax:"*";inherits:false}@property --tw-drop-shadow-color{syntax:"*";inherits:false}@property --tw-drop-shadow-alpha{syntax:"<percentage>";inherits:false;initial-value:100%}@property --tw-drop-shadow-size{syntax:"*";inherits:false}@keyframes spin{to{transform:rotate(360deg)}}
    \\
;

pub const checkbox_js =
    \\import{r as n,i as a}from"./publr-core.js";n("checkbox",i=>{const e=i.querySelector('input[type="checkbox"]');if(!e)return;e.dataset.publrIndeterminate==="true"&&(e.indeterminate=!0);function r(){const t=e.indeterminate?"indeterminate":e.checked?"checked":"unchecked";i.dataset.publrState=t,e.dataset.publrIndeterminate=t==="indeterminate"?"true":"false",t==="indeterminate"?e.setAttribute("aria-checked","mixed"):e.setAttribute("aria-checked",e.checked?"true":"false")}r(),e.addEventListener("change",r)});a();
    \\
;

pub const core_js =
    \\const a=new Map;function i(t,e){a.set(t,e)}function r(t=document){t.querySelectorAll("[data-publr-component]").forEach(e=>{const o=e.dataset.publrComponent,n=a.get(o);n&&!e._publrInit&&(e._publrInit=!0,n(e))})}document.addEventListener("publr:init",t=>r(t.target));function u(t){return t.dataset.publrState==="open"}function s(t){t.dataset.publrState="open";const e=t.querySelector('[data-publr-part="trigger"]');e&&e.setAttribute("aria-expanded","true")}function d(t){t.dataset.publrState="closed";const e=t.querySelector('[data-publr-part="trigger"]');e&&e.setAttribute("aria-expanded","false"),t._publrOnClose&&(t._publrOnClose(),delete t._publrOnClose)}function c(t){u(t)?d(t):s(t)}i("toggle",t=>{const e=t.querySelector('[data-publr-part="trigger"]');e&&e.addEventListener("click",()=>c(t))});document.readyState==="loading"?document.addEventListener("DOMContentLoaded",()=>r()):r();export{u as a,d as c,r as i,s as o,i as r};
    \\
;

pub const dialog_js =
    \\import{r as g,o as m,c as q,i as S}from"./publr-core.js";import{t as v}from"./publr-focus.js";import{o as E}from"./publr-dismiss.js";let k=0;g("dialog",t=>{const s=t.querySelector('[data-publr-part="trigger"]'),c=t.querySelector('[data-publr-part="overlay"]'),a=t.querySelector('[data-publr-part="content"]'),i=t.querySelector('[data-publr-part="close"]'),o=t.querySelector('[data-publr-part="confirm"]'),n=t.querySelector('[data-publr-part="title"]'),u=t.querySelector('[data-publr-part="description"]');if(!s||!c||!a)return;const d=s.querySelector("button")||s,p=(i==null?void 0:i.querySelector("button"))||i,f=(o==null?void 0:o.querySelector("button"))||o,b=t.dataset.publrId||`publr-dialog-${++k}`;t.dataset.publrId=b,n?(n.id=`${b}-title`,a.setAttribute("aria-labelledby",n.id)):a.removeAttribute("aria-labelledby"),u?(u.id=`${b}-description`,a.setAttribute("aria-describedby",u.id)):a.removeAttribute("aria-describedby");let e=null,r=null;function l(){e&&(e(),e=null),r&&(r(),r=null),q(t),d.focus()}d.addEventListener("click",()=>{m(t),e=v(a),r=E(t,l),t._publrOnClose=()=>{e&&(e(),e=null),r&&(r(),r=null),d.focus()}}),p&&p.addEventListener("click",l),f&&f.addEventListener("click",()=>{l()}),c.addEventListener("click",y=>{y.target===c&&t.dataset.publrDismissable!=="false"&&l()})});S();
    \\
;

pub const dismiss_js =
    \\function c(t,r,n=[]){function e(i){if(!t.contains(i.target)){for(const o of n)if(o&&o.contains(i.target))return;r()}}return requestAnimationFrame(()=>{document.addEventListener("click",e,!0)}),function(){document.removeEventListener("click",e,!0)}}function a(t,r){function n(e){e.key==="Escape"&&t.dataset.publrDismissable!=="false"&&r()}return document.addEventListener("keydown",n),function(){document.removeEventListener("keydown",n)}}export{c as a,a as o};
    \\
;

pub const dropdown_js =
    \\import{r as k,a as y,c as v,o as g,i as w}from"./publr-core.js";import{p as h}from"./publr-portal.js";import{p as D}from"./publr-position.js";import{a as E,o as A}from"./publr-dismiss.js";k("dropdown",n=>{const c=n.querySelector('[data-publr-part="trigger"]'),r=n.querySelector('[data-publr-part="content"]');if(!c||!r)return;let o=null,s=null,i=null;function b(){return[...r.querySelectorAll('[data-publr-part="item"]')].filter(t=>!t.disabled&&!t.hasAttribute("aria-disabled"))}function u(t,e){var a;t.forEach((l,d)=>{l.tabIndex=d===e?0:-1}),(a=t[e])==null||a.focus()}function f(){s&&(s(),s=null),i&&(i(),i=null),r.style.display="",o&&(o(),o=null),v(n),(c.querySelector("button")||c).focus()}function m(){g(n),o=h(r),r.style.display="block",D(r,c,{placement:"bottom-start",offset:12}),s=E(n,f,[r]),i=A(n,f);const t=b();t.length&&u(t,0),n._publrOnClose=()=>{s&&(s(),s=null),i&&(i(),i=null),r.style.display="",o&&(o(),o=null)}}c.addEventListener("click",()=>{y(n)?f():m()}),c.addEventListener("keydown",t=>{(t.key==="ArrowDown"||t.key==="Enter"||t.key===" ")&&!y(n)&&(t.preventDefault(),m())}),r.addEventListener("keydown",t=>{const e=b();if(!e.length)return;const a=e.indexOf(document.activeElement);switch(t.key){case"ArrowDown":{t.preventDefault();const l=a<e.length-1?a+1:0;u(e,l);break}case"ArrowUp":{t.preventDefault();const l=a>0?a-1:e.length-1;u(e,l);break}case"Home":{t.preventDefault(),u(e,0);break}case"End":{t.preventDefault(),u(e,e.length-1);break}case"Enter":case" ":{t.preventDefault(),a>=0&&(e[a].click(),f());break}case"Tab":{t.preventDefault(),f();break}default:if(t.key.length===1&&!t.ctrlKey&&!t.metaKey&&!t.altKey){const l=t.key.toLowerCase(),d=e.find(p=>p.textContent.trim().toLowerCase().startsWith(l));if(d){const p=e.indexOf(d);u(e,p)}}}}),r.addEventListener("click",t=>{const e=t.target.closest('[data-publr-part="item"]');e&&!e.disabled&&e.getAttribute("aria-disabled")!=="true"&&f()})});w();
    \\
;

pub const focus_js =
    \\const a='a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';function r(n,o={}){const i=()=>n.querySelectorAll(a),c=i();if(!c.length)return()=>{};const s=document.activeElement;o.initialFocus?o.initialFocus.focus():c[0].focus();function u(e){if(e.key!=="Tab")return;const t=i();if(!t.length)return;const l=t[0],f=t[t.length-1];e.shiftKey&&document.activeElement===l?(e.preventDefault(),f.focus()):!e.shiftKey&&document.activeElement===f&&(e.preventDefault(),l.focus())}return n.addEventListener("keydown",u),function(){n.removeEventListener("keydown",u),s&&s.focus&&s.focus()}}export{r as t};
    \\
;

pub const keyboard_js =
    \\
    \\
;

pub const popover_js =
    \\import{r as y,a as v,c as g,o as O,i as S}from"./publr-core.js";import{p as C}from"./publr-portal.js";import{p as k}from"./publr-position.js";import{t as q}from"./publr-focus.js";import{a as x,o as E}from"./publr-dismiss.js";y("popover",e=>{const i=e.querySelector('[data-publr-part="trigger"]'),t=e.querySelector('[data-publr-part="content"]');if(!i||!t)return;let o=null,s=null,l=null,n=null;function r(){n&&(n(),n=null),s&&(s(),s=null),l&&(l(),l=null),t.style.display="",o&&(o(),o=null),g(e),(i.querySelector("button")||i).focus()}function p(){O(e),o=C(t),t.style.display="block";const a=t.dataset.publrSide||"bottom",c=t.dataset.publrAlign||"center",d=parseInt(t.dataset.publrSideOffset||"0",10),f=t.dataset.publrAvoidCollisions!=="false",b=e.dataset.publrModal==="true",m=c==="center"?a:`${a}-${c}`;if(k(t,i,{placement:m,offset:d||12,flip:f}),s=x(e,r,[t]),l=E(e,r),b)n=q(t);else{const u=t.querySelector('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])');u&&u.focus()}e._publrOnClose=()=>{n&&(n(),n=null),s&&(s(),s=null),l&&(l(),l=null),t.style.display="",o&&(o(),o=null)}}i.addEventListener("click",()=>{v(e)?r():p()})});S();
    \\
;

pub const portal_js =
    \\let n=null;function r(){return n||(n=document.createElement("div"),n.id="publr-portal",n.style.cssText="position:fixed;top:0;left:0;z-index:9999;pointer-events:none;",document.body.appendChild(n)),n}function i(t){return t._publrOriginalParent=t.parentNode,t._publrOriginalNext=t.nextSibling,t.style.pointerEvents="auto",r().appendChild(t),()=>e(t)}function e(t){t._publrOriginalParent&&(t._publrOriginalParent.insertBefore(t,t._publrOriginalNext),delete t._publrOriginalParent,delete t._publrOriginalNext,t.style.pointerEvents="")}export{i as p,e as u};
    \\
;

pub const position_js =
    \\const h={"top-start":{primary:"top",align:"start"},top:{primary:"top",align:"center"},"top-end":{primary:"top",align:"end"},"bottom-start":{primary:"bottom",align:"start"},bottom:{primary:"bottom",align:"center"},"bottom-end":{primary:"bottom",align:"end"},"left-start":{primary:"left",align:"start"},left:{primary:"left",align:"center"},"left-end":{primary:"left",align:"end"},"right-start":{primary:"right",align:"start"},right:{primary:"right",align:"center"},"right-end":{primary:"right",align:"end"}},u={top:"bottom",bottom:"top",left:"right",right:"left"};function y(t,e,i,s,r){let l,o;return i==="bottom"?l=t.bottom+r:i==="top"?l=t.top-e.height-r:i==="left"?o=t.left-e.width-r:o=t.right+r,i==="top"||i==="bottom"?s==="start"?o=t.left:s==="end"?o=t.right-e.width:o=t.left+(t.width-e.width)/2:s==="start"?l=t.top:s==="end"?l=t.bottom-e.height:l=t.top+(t.height-e.height)/2,{top:l,left:o}}function b(t,e){return t.top<0||t.left<0||t.top+e.height>window.innerHeight||t.left+e.width>window.innerWidth}function C(t,e,i={}){const s=i.placement||"bottom-start",r=i.offset??4,l=i.flip!==!1,o=h[s]||h["bottom-start"],f=e.getBoundingClientRect();t.style.position="fixed",t.style.visibility="hidden",t.style.top="0",t.style.left="0";const p=t.getBoundingClientRect();t.style.visibility="";let{primary:n,align:m}=o,d=y(f,p,n,m,r);if(l&&b(d,p)){const a=u[n],g=y(f,p,a,m,r);b(g,p)||(n=a,d=g)}return t.style.top=`${d.top}px`,t.style.left=`${d.left}px`,m==="center"?n:`${n}-${m}`}export{C as p};
    \\
;

pub const radio_group_js =
    \\import{r as i,i as s}from"./publr-core.js";i("radio-group",t=>{const r=t.dataset.publrName||"",a=[...t.querySelectorAll('[data-publr-part="item"]')],o=a.map(e=>e.querySelector('input[type="radio"]')).filter(Boolean);r&&o.forEach(e=>{e.name||(e.name=r)});function c(){a.forEach(e=>{const n=e.querySelector('input[type="radio"]');n&&(e.dataset.publrState=n.checked?"checked":"unchecked")})}c(),o.forEach(e=>e.addEventListener("change",c))});s();
    \\
;

pub const select_js =
    \\import{r as S,a as x,c as w,o as C,i as A}from"./publr-core.js";import{p as q}from"./publr-portal.js";import{p as I}from"./publr-position.js";import{a as K,o as V}from"./publr-dismiss.js";S("select",n=>{var h;const i=n.querySelector('[data-publr-part="trigger"]'),l=n.querySelector('[data-publr-part="content"]'),d=n.querySelector('[data-publr-part="value"]'),s=n.querySelector('[data-publr-part="label"]');if(!i||!l)return;const L=((h=s==null?void 0:s.textContent)==null?void 0:h.trim())||"";let f=null,p=null,b=null;function g(t){return t.hasAttribute("aria-disabled")||t.dataset.publrState==="disabled"}function m(){return[...l.querySelectorAll('[data-publr-part="option"]')].filter(t=>!g(t))}function D(t){var e,a;return((a=(e=t.querySelector('[data-publr-part="option-label"]'))==null?void 0:e.textContent)==null?void 0:a.trim())||t.textContent.trim()}function c(t,e){var a;t.forEach((o,r)=>{o.tabIndex=r===e?0:-1,o.classList.toggle("bg-accent",r===e),o.classList.toggle("text-accent-foreground",r===e)}),(a=t[e])==null||a.focus()}function v(t,{closeAfter:e=!0}={}){if(!t||g(t))return;const a=t.dataset.value,o=D(t);d&&(d.value=a),s&&(s.textContent=o,s.classList.remove("text-muted-foreground"),s.classList.add("text-foreground")),l.querySelectorAll('[data-publr-part="option"]').forEach(r=>{r.setAttribute("aria-selected",r===t?"true":"false"),r.dataset.publrState=r===t?"selected":g(r)?"disabled":"unselected"}),e&&u()}function u(){p&&(p(),p=null),b&&(b(),b=null),l.style.display="",f&&(f(),f=null),w(n),i.focus()}function y(){C(n),f=q(l),l.style.display="block",I(l,i,{placement:"bottom-start",offset:4}),p=K(n,u,[l]),b=V(n,u);const t=m(),e=t.findIndex(a=>a.getAttribute("aria-selected")==="true");t.length&&c(t,e>=0?e:0)}i.addEventListener("click",()=>{x(n)?u():y()}),i.addEventListener("keydown",t=>{(t.key==="ArrowDown"||t.key==="Enter"||t.key===" ")&&!x(n)&&(t.preventDefault(),y())}),l.addEventListener("keydown",t=>{const e=m();if(!e.length)return;const a=e.indexOf(document.activeElement);switch(t.key){case"ArrowDown":{t.preventDefault(),c(e,a<e.length-1?a+1:0);break}case"ArrowUp":{t.preventDefault(),c(e,a>0?a-1:e.length-1);break}case"Home":{t.preventDefault(),c(e,0);break}case"End":{t.preventDefault(),c(e,e.length-1);break}case"Enter":case" ":{t.preventDefault(),a>=0&&v(e[a]);break}case"Tab":{t.preventDefault(),u();break}default:if(t.key.length===1&&!t.ctrlKey&&!t.metaKey&&!t.altKey){const o=t.key.toLowerCase(),r=e.find(O=>O.textContent.trim().toLowerCase().startsWith(o));r&&c(e,e.indexOf(r))}}}),l.addEventListener("click",t=>{const e=t.target.closest('[data-publr-part="option"]');e&&!g(e)&&v(e)});const E=n.dataset.publrDefaultValue,k=m().find(t=>t.dataset.value===E);k?v(k,{closeAfter:!1}):s&&(d&&(d.value=""),s.textContent=L,s.classList.add("text-muted-foreground"),s.classList.remove("text-foreground"))});A();
    \\
;

pub const sidebar_js =
    \\import{r as n,i as c}from"./publr-core.js";n("sidebar",s=>{s.querySelectorAll('[data-publr-part="section-trigger"]').forEach(e=>{e.addEventListener("click",()=>{const t=e.closest('[data-publr-part="section"]');if(!t)return;const r=t.dataset.publrState==="open";t.dataset.publrState=r?"closed":"open";const a=t.querySelector('[data-publr-part="section-content"]');a&&(a.hidden=!!r);const o=e.querySelector("svg");o&&(o.style.transform=r?"rotate(-90deg)":"")})})});c();
    \\
;

pub const switch_js =
    \\import{r as n,i}from"./publr-core.js";n("switch",t=>{const e=t.querySelector('input[type="checkbox"]');if(!e)return;function c(){t.dataset.publrState=e.checked?"checked":"unchecked"}c(),e.addEventListener("change",c)});i();
    \\
;

pub const tabs_js =
    \\import{r as b,i as o}from"./publr-core.js";b("tabs",n=>{const l=n.querySelector('[data-publr-part="list"]');if(!l)return;function s(){return[...l.querySelectorAll('[data-publr-part="trigger"]')].filter(t=>!t.disabled)}function i(t){if(!t||t.disabled)return;const a=t.dataset.publrTab;n.querySelectorAll('[data-publr-part="trigger"]').forEach(e=>{e.dataset.publrState="inactive",e.setAttribute("aria-selected","false"),e.tabIndex=-1}),n.querySelectorAll('[data-publr-part="content"]').forEach(e=>{e.dataset.publrState="inactive",e.hidden=!0}),t.dataset.publrState="active",t.setAttribute("aria-selected","true"),t.tabIndex=0;const r=n.querySelector(`[data-publr-part="content"][data-publr-tab="${a}"]`);r&&(r.dataset.publrState="active",r.hidden=!1)}l.addEventListener("click",t=>{const a=t.target.closest('[data-publr-part="trigger"]');a&&!a.disabled&&i(a)}),l.addEventListener("keydown",t=>{const a=s(),r=a.indexOf(document.activeElement);if(r===-1)return;let e=r;switch(t.key){case"ArrowRight":t.preventDefault(),e=r<a.length-1?r+1:0;break;case"ArrowLeft":t.preventDefault(),e=r>0?r-1:a.length-1;break;case"Home":t.preventDefault(),e=0;break;case"End":t.preventDefault(),e=a.length-1;break;default:return}a[e].focus(),i(a[e])});const u=s(),c=n.dataset.publrDefaultValue,d=u.find(t=>t.dataset.publrTab===c)||u[0];d&&i(d)});o();
    \\
;

pub const toast_js =
    \\import{r as d,i as p}from"./publr-core.js";let f=0;function m(){return document.getElementById("publr-toast-region")}function y(t,o={}){const a=o.variant||"default",n=o.duration??4e3,s=++f,r=m();if(!r)return console.warn("publr.toast: no #publr-toast-region found. Add <ToastRegion /> to your layout."),null;const i=r.querySelector(`template[data-publr-toast-template="${a}"]`);if(!i)return console.warn(`publr.toast: no template for variant "${a}"`),null;const e=i.content.firstElementChild.cloneNode(!0);e.dataset.toastId=s;const l=e.querySelector('[data-publr-part="message"]');l&&(l.textContent=t);const u=e.querySelector('[data-publr-part="close"]');return u&&u.addEventListener("click",()=>c(e)),r.appendChild(e),requestAnimationFrame(()=>{e.style.opacity="1",e.style.transform="translateY(0)"}),n>0&&n!==1/0&&setTimeout(()=>c(e),n),s}function c(t){t.style.opacity="0",t.style.transform="translateY(8px)",setTimeout(()=>t.remove(),200)}typeof window<"u"&&(window.publr=window.publr||{},window.publr.toast=y);d("toast",t=>{const o=t.querySelector('[data-publr-part="close"]');o&&o.addEventListener("click",()=>{t.style.opacity="0",t.style.transform="translateY(8px)",t.style.transition="opacity 0.2s, transform 0.2s",setTimeout(()=>{t.style.display="none"},200)})});p();
    \\
;

pub const tooltip_js =
    \\import{r as T,o as q,c as v,i as A}from"./publr-core.js";import{p as D,u as d}from"./publr-portal.js";import{p as H}from"./publr-position.js";const I={instant:0,fast:200,default:700,slow:1e3};let u=0;T("tooltip-provider",()=>{});T("tooltip",t=>{const s=t.querySelector('[data-publr-part="trigger"]'),a=t.querySelector('[data-publr-part="portal"]'),e=t.querySelector('[data-publr-part="content"]');if(!s||!e)return;const o=t.closest('[data-publr-component="tooltip-provider"]'),E=t.dataset.publrDelay||o&&o.dataset.publrDelay||"default",S=I[E]??700,L=o?parseInt(o.dataset.publrSkipDelay||"300",10):300,g=(t.dataset.publrDisableHoverableContent||o&&o.dataset.publrDisableHoverableContent)==="true";let p=null,l=null,i=!1;function r(n){t.dataset.publrState=n,s.dataset.state=n,e.dataset.state=n}function f(n){clearTimeout(l);const m=Date.now()-u<L?0:S;r(m>0?"delayed-open":"instant-open"),p=setTimeout(()=>{q(t),r("instant-open"),a?D(a):D(e),i=!0,e.style.display="block";const b=e.dataset.publrSide||"top",y=e.dataset.publrAlign||"center",k=parseInt(e.dataset.publrSideOffset||"0",10),C=e.dataset.publrAvoidCollisions!=="false",h=y==="center"?b:`${b}-${y}`;H(e,s,{placement:h,offset:k||6,flip:C})},m)}function c(){clearTimeout(p),l=setTimeout(()=>{e.style.display="",i&&(a?d(a):d(e),i=!1),v(t),r("closed"),u=Date.now()},100)}function w(){clearTimeout(p),clearTimeout(l),e.style.display="",i&&(a?d(a):d(e),i=!1),v(t),r("closed"),u=Date.now()}s.addEventListener("mouseenter",()=>f()),s.addEventListener("mouseleave",c),s.addEventListener("focusin",()=>f()),s.addEventListener("focusout",c),g||(e.addEventListener("mouseenter",()=>clearTimeout(l)),e.addEventListener("mouseleave",c)),s.addEventListener("keydown",n=>{n.key==="Escape"&&w()})});A();
    \\
;

