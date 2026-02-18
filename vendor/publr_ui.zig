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

pub const icons_data = struct {

pub const Name = enum { arrow_left, bookmark, chart, check, chevron_down, chevron_left, chevron_right, chevron_up, components, copy, dot_filled, dot_half, dot_outline, edit, file, folder_plus, folder, grid, home, image, list, lock, logout, more, package, plus_circle, plus, search, settings, sync, tag, trash, upload, user, users, x_close };

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
pub const ButtonProps = struct {
    label: []const u8 = "Button CTA",
    hierarchy: Hierarchy = .primary,
    size: Size = .md,
    disabled: bool = false,
    @"type": Type = .button,
};
pub fn Button(writer: anytype, props: anytype) !void {
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
    try writer.writeAll(base);
    try writer.writeAll(" ");
    try writer.writeAll(size_classes);
    try writer.writeAll(" ");
    try writer.writeAll(hierarchy_classes);
    try writer.writeAll(" ");
    try writer.writeAll(focus);
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
pub const DialogProps = struct {
    trigger_label: []const u8,
    title: []const u8,
    body: []const u8,
    dismiss_label: []const u8 = "Cancel",
    confirm_label: []const u8 = "",
    dismissable: bool = true,
};
pub fn Dialog(writer: anytype, props: anytype) !void {
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
pub const icons = icons_data;
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
pub fn Icon(writer: anytype, props: anytype) !void {
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

pub const css =
    \\*,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }::backdrop{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{border:0 solid #e9eaeb}:after,:before{--tw-content:""}:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:Geist,-apple-system,BlinkMacSystemFont,sans-serif;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}body{line-height:inherit}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}small{font-size:80%}sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:baseline}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}button,select{text-transform:none}button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:transparent;background-image:none}:-moz-focusring{outline:auto}:-moz-ui-invalid{box-shadow:none}progress{vertical-align:baseline}::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}[type=search]{-webkit-appearance:textfield;outline-offset:-2px}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}summary{display:list-item}blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}fieldset{margin:0}fieldset,legend{padding:0}menu,ol,ul{list-style:none;margin:0;padding:0}dialog{padding:0}textarea{resize:vertical}input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#a4a7ae}input::placeholder,textarea::placeholder{opacity:1;color:#a4a7ae}[role=button],button{cursor:pointer}:disabled{cursor:default}audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}img,video{max-width:100%;height:auto}[hidden]:where(:not([hidden=until-found])){display:none}*,:after,:before{box-sizing:border-box}body{margin:0;font-family:Geist,-apple-system,BlinkMacSystemFont,sans-serif;color:#181d27;background:#fafafa}.container{width:100%}@media (min-width:640px){.container{max-width:640px}}@media (min-width:768px){.container{max-width:768px}}@media (min-width:1024px){.container{max-width:1024px}}@media (min-width:1280px){.container{max-width:1280px}}@media (min-width:1536px){.container{max-width:1536px}}.pointer-events-none{pointer-events:none}.fixed{position:fixed}.absolute{position:absolute}.relative{position:relative}.inset-0{inset:0}.left-2\.5{left:.625rem}.top-1\/2{top:50%}.z-50{z-index:50}.m-0{margin:0}.mx-1{margin-left:.25rem;margin-right:.25rem}.mx-4{margin-left:1rem;margin-right:1rem}.ml-2{margin-left:.5rem}.ml-3{margin-left:.75rem}.ml-auto{margin-left:auto}.mt-0\.5{margin-top:.125rem}.mt-2{margin-top:.5rem}.mt-6{margin-top:1.5rem}.block{display:block}.flex{display:flex}.inline-flex{display:inline-flex}.grid{display:grid}.hidden{display:none}.h-10{height:2.5rem}.h-3{height:.75rem}.h-3\.5{height:.875rem}.h-4{height:1rem}.h-5{height:1.25rem}.h-6{height:1.5rem}.h-7{height:1.75rem}.h-8{height:2rem}.h-\[25vh\]{height:25vh}.h-full{height:100%}.h-screen{height:100vh}.min-h-0{min-height:0}.w-2\/5{width:40%}.w-3{width:.75rem}.w-3\.5{width:.875rem}.w-4{width:1rem}.w-5{width:1.25rem}.w-6{width:1.5rem}.w-7{width:1.75rem}.w-8{width:2rem}.w-full{width:100%}.min-w-0{min-width:0}.max-w-md{max-width:28rem}.flex-1{flex:1 1 0%}.shrink-0{flex-shrink:0}.-translate-y-1\/2{--tw-translate-y:-50%;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}.cursor-not-allowed{cursor:not-allowed}.grid-cols-\[repeat\(auto-fill\2c minmax\(200px\2c 1fr\)\)\]{grid-template-columns:repeat(auto-fill,minmax(200px,1fr))}.flex-col{flex-direction:column}.items-center{align-items:center}.justify-end{justify-content:flex-end}.justify-center{justify-content:center}.justify-between{justify-content:space-between}.gap-0\.5{gap:.125rem}.gap-2{gap:.5rem}.gap-3{gap:.75rem}.gap-5{gap:1.25rem}.gap-sm{gap:6px}.gap-xs{gap:4px}.divide-y>:not([hidden])~:not([hidden]){--tw-divide-y-reverse:0;border-top-width:calc(1px*(1 - var(--tw-divide-y-reverse)));border-bottom-width:calc(1px*var(--tw-divide-y-reverse))}.divide-gray-100>:not([hidden])~:not([hidden]){--tw-divide-opacity:1;border-color:rgb(245 245 245/var(--tw-divide-opacity,1))}.overflow-auto{overflow:auto}.overflow-hidden{overflow:hidden}.overflow-y-auto{overflow-y:auto}.truncate{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.rounded{border-radius:.25rem}.rounded-md{border-radius:8px}.rounded-xl{border-radius:12px}.border{border-width:1px}.border-b{border-bottom-width:1px}.border-r{border-right-width:1px}.border-t{border-top-width:1px}.border-gray-200{--tw-border-opacity:1;border-color:rgb(233 234 235/var(--tw-border-opacity,1))}.border-gray-300{--tw-border-opacity:1;border-color:rgb(213 215 218/var(--tw-border-opacity,1))}.border-gray-700{--tw-border-opacity:1;border-color:rgb(65 70 81/var(--tw-border-opacity,1))}.border-gray-800{--tw-border-opacity:1;border-color:rgb(37 43 55/var(--tw-border-opacity,1))}.bg-black\/50{background-color:rgba(0,0,0,.5)}.bg-brand-500{--tw-bg-opacity:1;background-color:rgb(18 173 255/var(--tw-bg-opacity,1))}.bg-brand-600{--tw-bg-opacity:1;background-color:rgb(2 162 255/var(--tw-bg-opacity,1))}.bg-gray-100{--tw-bg-opacity:1;background-color:rgb(245 245 245/var(--tw-bg-opacity,1))}.bg-gray-50{--tw-bg-opacity:1;background-color:rgb(250 250 250/var(--tw-bg-opacity,1))}.bg-gray-700{--tw-bg-opacity:1;background-color:rgb(65 70 81/var(--tw-bg-opacity,1))}.bg-gray-800{--tw-bg-opacity:1;background-color:rgb(37 43 55/var(--tw-bg-opacity,1))}.bg-gray-900{--tw-bg-opacity:1;background-color:rgb(24 29 39/var(--tw-bg-opacity,1))}.bg-gray-950{--tw-bg-opacity:1;background-color:rgb(10 13 18/var(--tw-bg-opacity,1))}.bg-white{--tw-bg-opacity:1;background-color:rgb(255 255 255/var(--tw-bg-opacity,1))}.p-3{padding:.75rem}.p-4{padding:1rem}.p-6{padding:1.5rem}.px-2{padding-left:.5rem;padding-right:.5rem}.px-2\.5{padding-left:.625rem;padding-right:.625rem}.px-3{padding-left:.75rem;padding-right:.75rem}.px-3\.5{padding-left:.875rem;padding-right:.875rem}.px-4{padding-left:1rem;padding-right:1rem}.px-\[30px\]{padding-left:30px;padding-right:30px}.py-1{padding-top:.25rem;padding-bottom:.25rem}.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}.py-2{padding-top:.5rem;padding-bottom:.5rem}.py-2\.5{padding-top:.625rem;padding-bottom:.625rem}.py-3{padding-top:.75rem;padding-bottom:.75rem}.pb-4{padding-bottom:1rem}.pl-8{padding-left:2rem}.pr-3{padding-right:.75rem}.text-\[10px\]{font-size:10px}.text-lg{font-size:1.125rem;line-height:1.75rem}.text-md{font-size:1rem;line-height:1.5rem}.text-sm{font-size:.875rem;line-height:1.25rem}.text-xs{font-size:.75rem;line-height:1.125rem}.font-medium{font-weight:500}.font-semibold{font-weight:600}.uppercase{text-transform:uppercase}.leading-relaxed{line-height:1.625}.tracking-tight{letter-spacing:-.025em}.tracking-wider{letter-spacing:.05em}.text-brand-700{--tw-text-opacity:1;color:rgb(0 136 214/var(--tw-text-opacity,1))}.text-gray-300{--tw-text-opacity:1;color:rgb(213 215 218/var(--tw-text-opacity,1))}.text-gray-400{--tw-text-opacity:1;color:rgb(164 167 174/var(--tw-text-opacity,1))}.text-gray-500{--tw-text-opacity:1;color:rgb(113 118 128/var(--tw-text-opacity,1))}.text-gray-600{--tw-text-opacity:1;color:rgb(83 88 98/var(--tw-text-opacity,1))}.text-gray-700{--tw-text-opacity:1;color:rgb(65 70 81/var(--tw-text-opacity,1))}.text-gray-900{--tw-text-opacity:1;color:rgb(24 29 39/var(--tw-text-opacity,1))}.text-white{--tw-text-opacity:1;color:rgb(255 255 255/var(--tw-text-opacity,1))}.placeholder-gray-500::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(113 118 128/var(--tw-placeholder-opacity,1))}.placeholder-gray-500::placeholder{--tw-placeholder-opacity:1;color:rgb(113 118 128/var(--tw-placeholder-opacity,1))}.opacity-0{opacity:0}.shadow-btn-primary{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05),inset 0 0 0 1px rgba(10,13,18,.18),inset 0 -2px 0 0 rgba(10,13,18,.05),inset 0 0 0 2px hsla(0,0%,100%,.12);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color),inset 0 0 0 1px var(--tw-shadow-color),inset 0 -2px 0 0 var(--tw-shadow-color),inset 0 0 0 2px var(--tw-shadow-color)}.shadow-btn-primary,.shadow-btn-secondary{box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.shadow-btn-secondary{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05),inset 0 0 0 1px #d5d7da,inset 0 -2px 0 0 rgba(10,13,18,.05);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color),inset 0 0 0 1px var(--tw-shadow-color),inset 0 -2px 0 0 var(--tw-shadow-color)}.shadow-xl{--tw-shadow:0 20px 25px -5px rgba(0,0,0,.1),0 8px 10px -6px rgba(0,0,0,.1);--tw-shadow-colored:0 20px 25px -5px var(--tw-shadow-color),0 8px 10px -6px var(--tw-shadow-color)}.shadow-xl,.shadow-xs{box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.shadow-xs{--tw-shadow:0 1px 2px 0 rgba(10,13,18,.05);--tw-shadow-colored:0 1px 2px 0 var(--tw-shadow-color)}.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}.transition-colors{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.transition-opacity{transition-property:opacity;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.hover\:bg-brand-700:hover{--tw-bg-opacity:1;background-color:rgb(0 136 214/var(--tw-bg-opacity,1))}.hover\:bg-gray-50:hover{--tw-bg-opacity:1;background-color:rgb(250 250 250/var(--tw-bg-opacity,1))}.hover\:bg-gray-700:hover{--tw-bg-opacity:1;background-color:rgb(65 70 81/var(--tw-bg-opacity,1))}.hover\:text-brand-800:hover{--tw-text-opacity:1;color:rgb(0 105 166/var(--tw-text-opacity,1))}.hover\:text-gray-600:hover{--tw-text-opacity:1;color:rgb(83 88 98/var(--tw-text-opacity,1))}.hover\:text-gray-700:hover{--tw-text-opacity:1;color:rgb(65 70 81/var(--tw-text-opacity,1))}.hover\:text-white:hover{--tw-text-opacity:1;color:rgb(255 255 255/var(--tw-text-opacity,1))}.focus\:border-brand-500:focus{--tw-border-opacity:1;border-color:rgb(18 173 255/var(--tw-border-opacity,1))}.focus\:outline-none:focus{outline:2px solid transparent;outline-offset:2px}.focus\:ring-1:focus{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color)}.focus\:ring-1:focus,.focus\:ring-2:focus{box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000)}.focus\:ring-2:focus{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color)}.focus\:ring-brand-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(18 173 255/var(--tw-ring-opacity,1))}.focus\:ring-offset-2:focus{--tw-ring-offset-width:2px}.focus-visible\:outline-none:focus-visible{outline:2px solid transparent;outline-offset:2px}.focus-visible\:ring-4:focus-visible{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(4px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000)}.focus-visible\:ring-brand-200:focus-visible{--tw-ring-opacity:1;--tw-ring-color:rgb(153 221 255/var(--tw-ring-opacity,1))}.focus-visible\:ring-offset-2:focus-visible{--tw-ring-offset-width:2px}.data-\[publr-state\=open\]\:pointer-events-auto[data-publr-state=open]{pointer-events:auto}.data-\[publr-state\=open\]\:opacity-100[data-publr-state=open]{opacity:1}
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

