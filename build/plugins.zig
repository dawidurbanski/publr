//! Plugin auto-discovery.
//!
//! Scans one or more directories for plugin entry points:
//!   - flat file <name>.zig   → plugin "<name>"
//!   - subdirectory <name>/   → plugin "<name>" (entry point is main.zig)
//!   - mod.zig is reserved
//!
//! For each discovered plugin, scans its source (recursively for directory
//! plugins) for `@import("name")` calls and attaches only the matching subset
//! of the `available_imports` pool. Drop a new file at <dir>/<name>.zig (or
//! <dir>/<name>/main.zig) and it auto-registers — no build.zig edits required
//! unless the plugin reaches for a module that isn't in `available_imports`.
//! First-seen wins on name collisions across directories.

const std = @import("std");

pub const Plugin = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub const Discovery = struct {
    plugins: []const Plugin,
    manifest_module: *std.Build.Module,
};

pub fn load(
    b: *std.Build,
    dirs: []const []const u8,
    available_imports: []const std.Build.Module.Import,
) Discovery {
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator, "pub const plugins = .{\n") catch @panic("OOM");

    var found: std.ArrayList(Plugin) = .empty;
    var seen: std.StringHashMap(void) = .init(b.allocator);

    for (dirs) |base| {
        var dir_open = b.build_root.handle.openDir(base, .{ .iterate = true }) catch continue;
        defer dir_open.close();
        var it = dir_open.iterate();
        while (it.next() catch null) |entry| {
            if (std.mem.eql(u8, entry.name, "mod.zig")) continue;

            const resolved: ?struct { name: []const u8, src: []const u8 } = blk: {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                    const stem = entry.name[0 .. entry.name.len - 4];
                    break :blk .{
                        .name = b.dupe(stem),
                        .src = b.fmt("{s}/{s}", .{ base, entry.name }),
                    };
                }
                if (entry.kind == .directory) {
                    const main_path = b.fmt("{s}/{s}/main.zig", .{ base, entry.name });
                    b.build_root.handle.access(main_path, .{}) catch break :blk null;
                    break :blk .{
                        .name = b.dupe(entry.name),
                        .src = main_path,
                    };
                }
                break :blk null;
            };

            const info = resolved orelse continue;
            if (seen.contains(info.name)) continue;
            seen.put(info.name, {}) catch @panic("OOM");

            const scan_root = if (entry.kind == .directory) b.fmt("{s}/{s}", .{ base, entry.name }) else info.src;
            const plugin_imports = selectImports(b, scan_root, available_imports);

            const plugin_module = b.createModule(.{
                .root_source_file = b.path(info.src),
                .imports = plugin_imports,
            });

            found.append(b.allocator, .{ .name = info.name, .module = plugin_module }) catch @panic("OOM");

            manifest.writer(b.allocator).print(
                "    .{{ .name = \"{s}\", .mod = @import(\"plugin_{s}\") }},\n",
                .{ info.name, info.name },
            ) catch @panic("OOM");
        }
    }

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const wf = b.addWriteFiles();
    const manifest_path = wf.add("plugin_registry.zig", manifest.items);
    const manifest_module = b.createModule(.{ .root_source_file = manifest_path });

    for (found.items) |p| {
        manifest_module.addImport(b.fmt("plugin_{s}", .{p.name}), p.module);
    }

    return .{
        .plugins = found.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .manifest_module = manifest_module,
    };
}

/// Return the subset of `available` whose names appear in @import("name")
/// calls under `scan_root`. If `scan_root` is a directory, recursively scans
/// every .zig file inside. Skips std/builtin and path-style imports.
fn selectImports(
    b: *std.Build,
    scan_root: []const u8,
    available: []const std.Build.Module.Import,
) []const std.Build.Module.Import {
    var seen: std.StringHashMap(void) = .init(b.allocator);
    var picked: std.ArrayList(std.Build.Module.Import) = .empty;

    const stat = b.build_root.handle.statFile(scan_root) catch return available;
    switch (stat.kind) {
        .file => scanImportsInto(b, scan_root, available, &seen, &picked),
        .directory => {
            var dir = b.build_root.handle.openDir(scan_root, .{ .iterate = true }) catch return available;
            defer dir.close();
            var walker = dir.walk(b.allocator) catch return available;
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                const path = b.fmt("{s}/{s}", .{ scan_root, entry.path });
                scanImportsInto(b, path, available, &seen, &picked);
            }
        },
        else => return available,
    }

    return picked.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn scanImportsInto(
    b: *std.Build,
    rel_path: []const u8,
    available: []const std.Build.Module.Import,
    seen: *std.StringHashMap(void),
    picked: *std.ArrayList(std.Build.Module.Import),
) void {
    const source = b.build_root.handle.readFileAlloc(b.allocator, rel_path, 1 * 1024 * 1024) catch return;

    const needle = "@import(\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, needle)) |found_at| {
        const start = found_at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const name = source[start..end];
        i = end + 1;

        if (std.mem.eql(u8, name, "std")) continue;
        if (std.mem.eql(u8, name, "builtin")) continue;
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        if (std.mem.endsWith(u8, name, ".zig")) continue;
        if (seen.contains(name)) continue;

        for (available) |imp| {
            if (std.mem.eql(u8, imp.name, name)) {
                seen.put(b.dupe(name), {}) catch @panic("OOM");
                picked.append(b.allocator, imp) catch @panic("OOM");
                break;
            }
        }
    }
}
