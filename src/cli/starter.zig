//! Starter content type CLI.
//!
//! `publr starter list` — print available starters.
//! `publr starter add <name>` — register the named starter + persist to the
//! `content_types` table so it survives restarts.
//!
//! Starters are pure `ContentTypeDef` literals embedded in the binary.
//! Adding a starter goes through the exact same `schema_registry.register`
//! call third-party plugins use — no privileged internal surface.

const std = @import("std");
const Db = @import("db").Db;
const content_type = @import("content_type");
const schema_registry = @import("schema_registry");
const common = @import("common.zig");

const post_starter = @import("starter/post.zig");
const page_starter = @import("starter/page.zig");

const ContentTypeDef = content_type.ContentTypeDef;

const Starter = struct {
    name: []const u8,
    def: ContentTypeDef,
};

const starters: []const Starter = &.{
    .{ .name = "post", .def = post_starter.def },
    .{ .name = "page", .def = page_starter.def },
};

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) return list(opts);
    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 2) return error.MissingStarterName;
        return add(allocator, db, opts, args[1]);
    }
    return error.UnknownStarterCommand;
}

/// Resolve `opts.db_path` to an absolute filesystem path for display. Falls
/// back to the raw path if absolute-ification fails (e.g. `:memory:`).
fn absoluteDbPath(allocator: std.mem.Allocator, db_path: []const u8) []const u8 {
    return std.fs.cwd().realpathAlloc(allocator, db_path) catch allocator.dupe(u8, db_path) catch db_path;
}

/// Print available starter names.
pub fn list(opts: common.GlobalOptions) !void {
    if (opts.format == .json or opts.format == .jsonl) {
        var stdout = std.fs.File.stdout().writer(&.{});
        try stdout.interface.writeAll("[");
        for (starters, 0..) |s, i| {
            if (i > 0) try stdout.interface.writeAll(",");
            try stdout.interface.print("\"{s}\"", .{s.name});
        }
        try stdout.interface.writeAll("]\n");
        return;
    }
    if (!opts.quiet) std.debug.print("Available starters:\n", .{});
    for (starters) |s| std.debug.print("  {s}\n", .{s.name});
}

/// Register `name` with the runtime registry and persist it to the
/// `content_types` DB table. Errors with `AlreadyRegistered` if a content
/// type with the same `type_id` is already registered.
pub fn add(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, name: []const u8) !void {
    try install(allocator, db, name);
    const abs = absoluteDbPath(allocator, opts.db_path);
    defer if (abs.ptr != opts.db_path.ptr) allocator.free(abs);
    if (opts.format == .json or opts.format == .jsonl) {
        var stdout = std.fs.File.stdout().writer(&.{});
        try stdout.interface.print("{{\"installed\":true,\"name\":\"{s}\",\"db\":\"{s}\"}}\n", .{ name, abs });
    } else if (!opts.quiet) {
        std.debug.print("Installed starter content type: {s}\n", .{name});
        std.debug.print("  db: {s}\n", .{abs});
    }
}

/// Programmatic install — used by both the CLI and test fixtures.
pub fn install(allocator: std.mem.Allocator, db: *Db, name: []const u8) !void {
    const def = find(name) orelse return error.UnknownStarter;
    if (schema_registry.findById(def.type_id) != null) return error.AlreadyRegistered;
    try schema_registry.register(def);
    try persistToDb(allocator, db, def);
}

/// Find a starter by name. Returns null if not found.
pub fn find(name: []const u8) ?ContentTypeDef {
    for (starters) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.def;
    }
    return null;
}

/// Insert/upsert a row into the `content_types` table so the starter
/// survives restarts and shows up in admin listings.
fn persistToDb(allocator: std.mem.Allocator, db: *Db, def: ContentTypeDef) !void {
    var fields_json: std.ArrayList(u8) = .{};
    defer fields_json.deinit(allocator);
    try fields_json.writer(allocator).print("{f}", .{std.json.fmt(def.fields, .{})});

    var stmt = try db.prepare(
        \\INSERT OR REPLACE INTO content_types
        \\  (id, slug, name, name_plural, icon, fields, source, localized, locales, workflow, internal, is_taxonomy)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
    );
    defer stmt.deinit();
    try stmt.bindText(1, def.type_id);
    try stmt.bindText(2, def.handle);
    try stmt.bindText(3, def.display_name);
    try stmt.bindText(4, def.display_name_plural);
    try stmt.bindText(5, def.icon orelse "bookmark");
    try stmt.bindText(6, fields_json.items);
    try stmt.bindText(7, "starter");

    try stmt.bindInt(8, if (def.localized) 1 else 0);
    if (def.locales.len > 0) {
        var locales_csv: std.ArrayList(u8) = .{};
        defer locales_csv.deinit(allocator);
        for (def.locales, 0..) |loc, i| {
            if (i > 0) try locales_csv.append(allocator, ',');
            try locales_csv.appendSlice(allocator, loc);
        }
        try stmt.bindText(9, locales_csv.items);
    } else {
        try stmt.bindNull(9);
    }

    if (def.workflow) |w| try stmt.bindText(10, w) else try stmt.bindNull(10);
    try stmt.bindInt(11, if (def.internal) 1 else 0);
    try stmt.bindInt(12, if (def.taxonomy != null) 1 else 0);

    _ = try stmt.step();
}

test "starter: find returns def by name" {
    const post = find("post") orelse return error.NotFound;
    try std.testing.expectEqualStrings("post", post.type_id);

    const page = find("page") orelse return error.NotFound;
    try std.testing.expectEqualStrings("page", page.type_id);

    try std.testing.expect(find("nonexistent") == null);
}

test "starter: public API coverage" {
    _ = run;
    _ = list;
    _ = add;
    _ = install;
    _ = find;
}
