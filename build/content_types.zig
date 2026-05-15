//! Compile-in content type auto-discovery.
//!
//! Scans the given directories for `*.zig` files that expose
//! `pub const content_types: []const ContentTypeDef`. Generates a single
//! `compiled_in_content_types.zig` module whose `pub const all` concatenates
//! every discovered slice. Mirrors `build/plugins.zig`'s discovery shape.
//!
//! Today the discovery slice is empty (Post and Page still live in the
//! comptime `schemas.content_types` tuple). Task 05 flips this on by moving
//! starter types into a discoverable plugin.

const std = @import("std");

pub const Discovery = struct {
    module: *std.Build.Module,
    sources: []const Source,
};

pub const Source = struct {
    /// Symbolic name (used in the generated @import alias).
    name: []const u8,
    /// Source file path relative to the build root.
    src: []const u8,
};

pub fn discover(
    b: *std.Build,
    dirs: []const []const u8,
    imports_for_sources: []const std.Build.Module.Import,
) Discovery {
    var found: std.ArrayList(Source) = .empty;
    var seen: std.StringHashMap(void) = .init(b.allocator);

    for (dirs) |base| {
        var dir_open = b.build_root.handle.openDir(base, .{ .iterate = true }) catch continue;
        defer dir_open.close();
        var walker = dir_open.walk(b.allocator) catch continue;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.endsWith(u8, entry.basename, ".test.zig")) continue;

            const rel_path = b.fmt("{s}/{s}", .{ base, entry.path });
            if (!exposesContentTypes(b, rel_path)) continue;

            const name = sanitizeName(b, entry.path);
            if (seen.contains(name)) continue;
            seen.put(name, {}) catch @panic("OOM");

            found.append(b.allocator, .{ .name = name, .src = rel_path }) catch @panic("OOM");
        }
    }

    const sources = found.toOwnedSlice(b.allocator) catch @panic("OOM");

    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\const content_type = @import("content_type");
        \\
        \\
    ) catch @panic("OOM");

    for (sources) |s| {
        manifest.writer(b.allocator).print(
            "const src_{s} = @import(\"src_{s}\");\n",
            .{ s.name, s.name },
        ) catch @panic("OOM");
    }

    if (sources.len == 0) {
        // No discovered plugins — emit an explicit empty slice. Task 05
        // flips this path on when starter types move into a plugin file.
        manifest.appendSlice(b.allocator,
            \\
            \\pub const all: []const content_type.ContentTypeDef = &.{};
            \\
        ) catch @panic("OOM");
    } else {
        manifest.appendSlice(b.allocator,
            \\
            \\pub const all: []const content_type.ContentTypeDef = blk: {
            \\    comptime var count: usize = 0;
            \\
        ) catch @panic("OOM");

        for (sources) |s| {
            manifest.writer(b.allocator).print(
                "    count += src_{s}.content_types.len;\n",
                .{s.name},
            ) catch @panic("OOM");
        }

        manifest.appendSlice(b.allocator,
            \\    comptime var out: [count]content_type.ContentTypeDef = undefined;
            \\    comptime var i: usize = 0;
            \\
        ) catch @panic("OOM");

        for (sources) |s| {
            manifest.writer(b.allocator).print(
                "    for (src_{s}.content_types) |ct| : (i += 1) out[i] = ct;\n",
                .{s.name},
            ) catch @panic("OOM");
        }

        manifest.appendSlice(b.allocator,
            \\    const final = out;
            \\    break :blk &final;
            \\};
            \\
        ) catch @panic("OOM");
    }

    const wf = b.addWriteFiles();
    const manifest_path = wf.add("compiled_in_content_types.zig", manifest.items);
    const module = b.createModule(.{ .root_source_file = manifest_path });

    for (imports_for_sources) |imp| module.addImport(imp.name, imp.module);

    for (sources) |s| {
        const src_module = b.createModule(.{
            .root_source_file = b.path(s.src),
            .imports = imports_for_sources,
        });
        module.addImport(b.fmt("src_{s}", .{s.name}), src_module);
    }

    return .{ .module = module, .sources = sources };
}

/// Cheap text scan — if the file declares `pub const content_types`, it's a
/// content-type-exposing source. Avoids parsing Zig.
fn exposesContentTypes(b: *std.Build, rel_path: []const u8) bool {
    const source = b.build_root.handle.readFileAlloc(b.allocator, rel_path, 1 * 1024 * 1024) catch return false;
    return std.mem.indexOf(u8, source, "pub const content_types") != null;
}

fn sanitizeName(b: *std.Build, path: []const u8) []const u8 {
    var buf = b.allocator.alloc(u8, path.len) catch @panic("OOM");
    for (path, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9' => ch,
            else => '_',
        };
    }
    return buf;
}
