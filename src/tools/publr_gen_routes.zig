//! Route Table Generator — walks theme pages/ directory and generates routes.zig.
//!
//! Usage: publr_gen_routes <pages_dir> <output_file>
//!
//! The generated routes.zig contains a sorted route table referencing
//! theme render functions via the theme module namespace.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const routes = @import("publr_routes");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: publr_gen_routes <theme_dir> <output_dir>\n", .{});
        std.process.exit(1);
    }

    const theme_dir = args[1];
    const output_dir = args[2];

    // Walk content/ subdirectory within theme
    const pages_dir = try fs.path.join(allocator, &.{ theme_dir, "content" });
    defer allocator.free(pages_dir);

    const output_file = try fs.path.join(allocator, &.{ output_dir, "routes.zig" });
    defer allocator.free(output_file);

    try generateRoutes(allocator, pages_dir, output_file);
}

fn generateRoutes(allocator: Allocator, pages_dir: []const u8, output_file: []const u8) !void {
    // Collect .publr files from pages/
    var page_files = std.ArrayListUnmanaged([]u8){};
    defer {
        for (page_files.items) |f| allocator.free(f);
        page_files.deinit(allocator);
    }

    var dir = try fs.cwd().openDir(pages_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.path, ".publr")) {
            const duped = try allocator.dupe(u8, entry.path);
            try page_files.append(allocator, duped);
        }
    }

    // Build route infos
    var route_infos = std.ArrayListUnmanaged(routes.RouteInfo){};
    defer {
        for (route_infos.items) |r| {
            allocator.free(r.url_pattern);
            allocator.free(r.module_path);
        }
        route_infos.deinit(allocator);
    }

    var error_404_module: ?[]const u8 = null;
    defer if (error_404_module) |m| allocator.free(m);

    for (page_files.items) |rel_path| {
        const is_error = routes.isErrorPage(rel_path);
        const module_path = try routes.filePathToModulePath(allocator, rel_path);

        if (is_error) {
            if (mem.endsWith(u8, rel_path, "404.publr")) {
                error_404_module = try allocator.dupe(u8, module_path);
            }
            allocator.free(module_path);
            continue;
        }

        const raw_pattern = try routes.filePathToUrlPattern(allocator, rel_path);

        // Convert bracket-style params to router-style params
        const url_pattern = try convertParams(allocator, raw_pattern);
        allocator.free(raw_pattern);

        try route_infos.append(allocator, .{
            .url_pattern = url_pattern,
            .module_path = module_path,
            .kind = routes.classifyRoute(url_pattern),
            .is_error_page = false,
            .content_type_id = routes.contentTypeFromPath(rel_path),
        });
    }

    // Sort: static → dynamic → catch_all, then alphabetical
    mem.sort(routes.RouteInfo, route_infos.items, {}, routes.routeLessThan);

    // Generate routes.zig
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("// Generated from theme pages - do not edit\n");
    try w.writeAll("const theme = @import(\"theme\");\n\n");

    // ThemeRoute struct
    try w.writeAll(
        \\pub const RouteKind = enum { static, dynamic, catch_all };
        \\
        \\pub const ThemeRoute = struct {
        \\    pattern: []const u8,
        \\    page: type,
        \\    kind: RouteKind,
        \\    content_type_id: ?[]const u8 = null,
        \\};
        \\
        \\
    );

    // Route table
    try w.print("pub const route_table = [_]ThemeRoute{{\n", .{});
    for (route_infos.items) |r| {
        if (r.content_type_id) |ct| {
            try w.print("    .{{ .pattern = \"{s}\", .page = theme.content.{s}, .kind = .{s}, .content_type_id = \"{s}\" }},\n", .{
                r.url_pattern,
                r.module_path,
                @tagName(r.kind),
                ct,
            });
        } else {
            try w.print("    .{{ .pattern = \"{s}\", .page = theme.content.{s}, .kind = .{s} }},\n", .{
                r.url_pattern,
                r.module_path,
                @tagName(r.kind),
            });
        }
    }
    try w.writeAll("};\n\n");

    // Error page (if exists)
    if (error_404_module) |mod| {
        try w.print("pub const error_404 = theme.content.{s};\n", .{mod});
    } else {
        try w.writeAll("pub const error_404 = null;\n");
    }

    // Ensure output directory exists
    if (fs.path.dirname(output_file)) |dir_path| {
        fs.cwd().makePath(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    var file = try fs.cwd().createFile(output_file, .{});
    defer file.close();
    try file.writeAll(output.items);
}

/// Convert bracket params to router params: [slug] → :slug, [...path] → *path
fn convertParams(allocator: Allocator, pattern: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '[') {
            // Find closing bracket
            const close = mem.indexOfScalarPos(u8, pattern, i + 1, ']') orelse {
                try w.writeByte(pattern[i]);
                i += 1;
                continue;
            };
            const inner = pattern[i + 1 .. close];
            if (mem.startsWith(u8, inner, "...")) {
                // Catch-all: [...param] → *param
                try w.writeByte('*');
                try w.writeAll(inner[3..]);
            } else {
                // Dynamic: [param] → :param
                try w.writeByte(':');
                try w.writeAll(inner);
            }
            i = close + 1;
        } else {
            try w.writeByte(pattern[i]);
            i += 1;
        }
    }

    return try buf.toOwnedSlice(allocator);
}
