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
    /// Set when the plugin's manifest.zon declares `.requires_schema = .loose`.
    /// Plugins requiring the CRDT-compatible schema flavor (cr-sqlite, etc.)
    /// flip this; the build aggregates and picks the loose schema file when
    /// any plugin requires it.
    requires_loose_schema: bool = false,
    /// Set when the plugin's manifest.zon declares `.sqlite_override_dir = "..."`.
    /// Absolute build-root-relative path of a directory containing the
    /// plugin's vendored sqlite3.c + glue. Only one plugin per build may
    /// declare this; the build errors if two collide.
    sqlite_override_dir: ?[]const u8 = null,
};

pub const Discovery = struct {
    plugins: []const Plugin,
    manifest_module: *std.Build.Module,
    /// True if any plugin's manifest requested the loose schema.
    requires_loose_schema: bool,
    /// Set to the single plugin-declared sqlite override directory, if any.
    sqlite_override_dir: ?[]const u8,
};

/// Aggregated manifest decisions, read by a quick pre-scan of all
/// plugins/<name>/manifest.zon files. Called before module registration
/// so the build can wire the anonymous schema_sql import + vendor options to the right files
/// before they're frozen into module imports.
pub const PreScan = struct {
    requires_loose_schema: bool,
    sqlite_override_dir: ?[]const u8,
    sqlite_override_cflags: []const []const u8,
};

pub fn preScan(b: *std.Build, dirs: []const []const u8) PreScan {
    var any_loose = false;
    var sqlite_dir: ?[]const u8 = null;
    var sqlite_dir_owner: []const u8 = "";
    var sqlite_cflags: []const []const u8 = &.{};

    for (dirs) |base| {
        var dir_open = b.build_root.handle.openDir(base, .{ .iterate = true }) catch continue;
        defer dir_open.close();
        var it = dir_open.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const plugin_dir = b.fmt("{s}/{s}", .{ base, entry.name });
            const info = readManifest(b, plugin_dir);
            if (info.requires_loose_schema) any_loose = true;
            if (info.sqlite_override_dir) |dir| {
                if (sqlite_dir) |existing| {
                    std.debug.print(
                        "build error: plugins '{s}' and '{s}' both declare sqlite_override_dir " ++
                            "('{s}' vs '{s}'). Only one plugin per build may swap sqlite.\n",
                        .{ sqlite_dir_owner, entry.name, existing, dir },
                    );
                    @panic("sqlite_override_dir collision");
                }
                sqlite_dir = dir;
                sqlite_dir_owner = b.dupe(entry.name);
                sqlite_cflags = info.sqlite_override_cflags;
            }
        }
    }

    return .{
        .requires_loose_schema = any_loose,
        .sqlite_override_dir = sqlite_dir,
        .sqlite_override_cflags = sqlite_cflags,
    };
}

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

            // Manifest is optional and only meaningful for directory-style
            // plugins (flat .zig plugins are simple comptime hooks with no
            // build-time concerns). Absent file → defaults.
            const manifest_info: ManifestInfo = if (entry.kind == .directory)
                readManifest(b, b.fmt("{s}/{s}", .{ base, entry.name }))
            else
                .{};

            found.append(b.allocator, .{
                .name = info.name,
                .module = plugin_module,
                .requires_loose_schema = manifest_info.requires_loose_schema,
                .sqlite_override_dir = manifest_info.sqlite_override_dir,
            }) catch @panic("OOM");

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

    // Aggregate manifest-derived decisions. At most one plugin may declare
    // a sqlite override — collision is a build error since both can't win.
    var any_loose = false;
    var sqlite_dir: ?[]const u8 = null;
    var sqlite_dir_owner: []const u8 = "";
    for (found.items) |p| {
        if (p.requires_loose_schema) any_loose = true;
        if (p.sqlite_override_dir) |dir| {
            if (sqlite_dir) |existing| {
                std.debug.print(
                    "build error: plugins '{s}' and '{s}' both declare sqlite_override_dir " ++
                        "('{s}' vs '{s}'). Only one plugin per build may swap sqlite.\n",
                    .{ sqlite_dir_owner, p.name, existing, dir },
                );
                @panic("sqlite_override_dir collision");
            }
            sqlite_dir = dir;
            sqlite_dir_owner = p.name;
        }
    }

    return .{
        .plugins = found.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .manifest_module = manifest_module,
        .requires_loose_schema = any_loose,
        .sqlite_override_dir = sqlite_dir,
    };
}

const ManifestInfo = struct {
    requires_loose_schema: bool = false,
    sqlite_override_dir: ?[]const u8 = null,
    /// Extra C flags applied to glue C sources in the override dir.
    /// Plugin authors supply these as a comma-separated string in
    /// manifest.zon: `.sqlite_override_cflags = "-DA,-DB"`.
    sqlite_override_cflags: []const []const u8 = &.{},
};

/// Read `<plugin_dir>/manifest.zon` if present and pull out the optional
/// `requires_schema` and `sqlite_override_dir` fields. Returns defaults
/// on missing file or absent fields. Format is a plain zon literal:
///
///     .{
///         .requires_schema = .loose,
///         .sqlite_override_dir = "vendor",
///     }
///
/// Both fields optional. Path is interpreted relative to the plugin's
/// directory; we resolve to build-root-relative here.
fn readManifest(b: *std.Build, plugin_dir: []const u8) ManifestInfo {
    const manifest_rel = b.fmt("{s}/manifest.zon", .{plugin_dir});
    const source = b.build_root.handle.readFileAlloc(b.allocator, manifest_rel, 64 * 1024) catch return .{};

    var info: ManifestInfo = .{};

    if (findField(source, ".requires_schema")) |val| {
        if (std.mem.eql(u8, val, ".loose")) info.requires_loose_schema = true;
    }
    if (findFieldString(b.allocator, source, ".sqlite_override_dir")) |path| {
        info.sqlite_override_dir = b.fmt("{s}/{s}", .{ plugin_dir, path });
    }
    if (findFieldString(b.allocator, source, ".sqlite_override_cflags")) |cflags_str| {
        info.sqlite_override_cflags = splitCflags(b.allocator, cflags_str);
    }

    return info;
}

fn splitCflags(allocator: std.mem.Allocator, csv: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        list.append(allocator, allocator.dupe(u8, trimmed) catch continue) catch continue;
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

/// Find `<field> = <value>` in a zon source. Returns the trimmed value
/// token (e.g. `.loose`, `42`, `"some,string"`) up to the next `,` or `}`
/// at the same nesting level. Quoted strings are returned including their
/// surrounding `"`; commas/newlines inside the quotes don't terminate.
fn findField(source: []const u8, field: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, source, field) orelse return null;
    var i = idx + field.len;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '=')) i += 1;
    const start = i;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (in_string) {
            if (ch == '"') in_string = false;
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == ',' or ch == '\n' or ch == '}') break;
    }
    return std.mem.trim(u8, source[start..i], " \t\r");
}

/// Same as `findField` but unquotes a `"..."` string value. Returns null
/// when the field is absent or the value isn't a string literal.
fn findFieldString(allocator: std.mem.Allocator, source: []const u8, field: []const u8) ?[]const u8 {
    const raw = findField(source, field) orelse return null;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return allocator.dupe(u8, raw[1 .. raw.len - 1]) catch null;
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
