const std = @import("std");
const Db = @import("db").Db;
const registry = @import("schema_registry");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) return listSchemas(allocator, opts);
    if (std.mem.eql(u8, sub, "show")) {
        if (args.len < 2) return error.MissingType;
        return showSchema(allocator, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "fields")) {
        if (args.len < 2) return error.MissingType;
        return fieldsSchema(allocator, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "validate")) {
        return validateSchema(db, opts);
    }
    return error.UnknownSchemaCommand;
}

fn listSchemas(allocator: std.mem.Allocator, opts: common.GlobalOptions) !void {
    if (opts.format == .json) {
        try fmt.printJson(.{ .data = registry.registered_types });
        return;
    }
    if (opts.format == .jsonl) {
        for (registry.registered_types) |info| {
            try fmt.printJsonLine(info);
        }
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }

    for (registry.registered_types) |info| {
        const cols = try allocator.alloc([]const u8, 5);
        cols[0] = info.id;
        cols[1] = info.display_name;
        cols[2] = try std.fmt.allocPrint(allocator, "{d}", .{info.fields.len});
        cols[3] = if (info.localized) "true" else "false";
        cols[4] = if (info.internal) "true" else "false";
        try rows.append(allocator, cols);
    }
    defer {
        for (rows.items) |row| allocator.free(row[2]);
    }

    try fmt.printTable(
        &.{ "ID", "Display Name", "Fields", "Localized", "Internal" },
        rows.items,
        opts.quiet,
        allocator,
    );
}

fn showSchema(allocator: std.mem.Allocator, opts: common.GlobalOptions, type_id: []const u8) !void {
    const info = registry.getTypeInfo(type_id) orelse return error.UnknownContentType;
    if (opts.format == .json) {
        try fmt.printJson(.{ .data = info });
        return;
    }
    if (opts.format == .jsonl) {
        try fmt.printJsonLine(info);
        return;
    }

    var kv = [_]fmt.KeyValueRow{
        .{ .key = "id", .value = info.id },
        .{ .key = "display_name", .value = info.display_name },
        .{ .key = "display_name_plural", .value = info.display_name_plural },
        .{ .key = "icon", .value = info.icon },
        .{ .key = "localized", .value = if (info.localized) "true" else "false" },
        .{ .key = "internal", .value = if (info.internal) "true" else "false" },
        .{ .key = "is_taxonomy", .value = if (info.is_taxonomy) "true" else "false" },
    };
    try fmt.printKeyValueRows(&kv, opts.quiet, allocator);
    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.writeAll("\n");
    try fieldsSchema(allocator, opts, type_id);
}

fn fieldsSchema(allocator: std.mem.Allocator, opts: common.GlobalOptions, type_id: []const u8) !void {
    const info = registry.getTypeInfo(type_id) orelse return error.UnknownContentType;
    if (opts.format == .json) {
        try fmt.printJson(.{ .data = info.fields });
        return;
    }
    if (opts.format == .jsonl) {
        for (info.fields) |field| try fmt.printJsonLine(field);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }

    for (info.fields) |field| {
        const cols = try allocator.alloc([]const u8, 6);
        cols[0] = field.name;
        cols[1] = field.display_name;
        cols[2] = field.field_type;
        cols[3] = if (field.required) "true" else "false";
        cols[4] = @tagName(field.translatable_mode);
        cols[5] = @tagName(field.position);
        try rows.append(allocator, cols);
    }

    try fmt.printTable(
        &.{ "Name", "Display", "Type", "Required", "Translatable", "Position" },
        rows.items,
        opts.quiet,
        allocator,
    );
}

fn validateSchema(db: *Db, opts: common.GlobalOptions) !void {
    for (registry.registered_types) |info| {
        var stmt = try db.prepare("SELECT 1 FROM content_types WHERE id = ?1 LIMIT 1");
        defer stmt.deinit();
        try stmt.bindText(1, info.id);
        if (!try stmt.step()) return error.SchemaMismatch;
    }

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .valid = true } });
    } else if (!opts.quiet) {
        std.debug.print("Schema validation passed.\n", .{});
    }
}

test "cli schema: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingType, run(std.testing.allocator, &dummy_db, .{}, &.{"show"}));
    try std.testing.expectError(error.UnknownSchemaCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli schema: list show fields validate via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    var list = try runner.run(&.{ "schema", "list", "--format", "json" });
    defer list.deinit();
    try helpers.runner_mod.expectSuccess(list);

    var show = try runner.run(&.{ "schema", "show", "post", "--format", "json" });
    defer show.deinit();
    try helpers.runner_mod.expectSuccess(show);

    var fields = try runner.run(&.{ "schema", "fields", "post", "--format", "json" });
    defer fields.deinit();
    try helpers.runner_mod.expectSuccess(fields);

    var validate = try runner.run(&.{ "schema", "validate", "--format", "json" });
    defer validate.deinit();
    try helpers.runner_mod.expectSuccess(validate);
}

test "cli schema: public API coverage" {
    _ = run;
}
