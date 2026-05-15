const std = @import("std");
const common = @import("common.zig");
const content_cli = @import("content.zig");
const version_cli = @import("version.zig");
const release_cli = @import("release.zig");
const media_cli = @import("media.zig");
const taxonomy_cli = @import("taxonomy.zig");
const user_cli = @import("user.zig");
const schema_cli = @import("schema.zig");
const db_cli = @import("db.zig");
const info_cli = @import("info.zig");
const starter_cli = @import("starter.zig");

pub fn run(allocator: std.mem.Allocator, first_command: []const u8, args_it: *std.process.ArgIterator) !void {
    var raw: std.ArrayList([]const u8) = .{};
    defer raw.deinit(allocator);
    try raw.append(allocator, first_command);
    while (args_it.next()) |arg| {
        try raw.append(allocator, arg);
    }

    if (raw.items.len == 0) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, raw.items[0], "help") or std.mem.eql(u8, raw.items[0], "--help") or std.mem.eql(u8, raw.items[0], "-h")) {
        printUsage();
        return;
    }

    const parsed = try common.extractGlobalOptions(allocator, raw.items);
    defer allocator.free(parsed.args);

    if (parsed.args.len == 0) {
        printUsage();
        return;
    }

    const command = parsed.args[0];
    if (std.mem.eql(u8, command, "db")) {
        if (parsed.args.len < 2) return error.MissingDbSubcommand;
        return db_cli.run(allocator, parsed.opts, parsed.args[1..]);
    }

    var db = try common.openDb(allocator, parsed.opts);
    defer db.deinit();

    if (std.mem.eql(u8, command, "content")) {
        if (parsed.args.len < 2) return error.MissingContentSubcommand;
        return content_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "version")) {
        if (parsed.args.len < 2) return error.MissingVersionSubcommand;
        return version_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "release")) {
        if (parsed.args.len < 2) return error.MissingReleaseSubcommand;
        return release_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "media")) {
        if (parsed.args.len < 2) return error.MissingMediaSubcommand;
        return media_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "taxonomy")) {
        if (parsed.args.len < 2) return error.MissingTaxonomySubcommand;
        return taxonomy_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "user")) {
        if (parsed.args.len < 2) return error.MissingUserSubcommand;
        return user_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "schema")) {
        if (parsed.args.len < 2) return error.MissingSchemaSubcommand;
        return schema_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }
    if (std.mem.eql(u8, command, "info")) {
        return info_cli.run(allocator, &db, parsed.opts);
    }
    if (std.mem.eql(u8, command, "starter")) {
        if (parsed.args.len < 2) return error.MissingStarterSubcommand;
        return starter_cli.run(allocator, &db, parsed.opts, parsed.args[1..]);
    }

    return error.UnknownCommand;
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  publr serve [--port <port>] [--db <path>] [--dev] [--watch]
        \\  publr <command> [options]
        \\
        \\Commands:
        \\  content    Content lifecycle (list/get/create/update/delete/publish/unpublish/discard/archive)
        \\  version    Version history commands
        \\  release    Release lifecycle commands
        \\  media      Media commands (list/upload/get/delete/sync)
        \\  taxonomy   Taxonomy term commands
        \\  user       User management commands
        \\  schema     Schema introspection commands
        \\  db         Database commands (init/seed/export/import)
        \\  info       System overview
        \\  starter    Install starter content types (post/page)
        \\
        \\Global options:
        \\  --db <path>
        \\  --format <table|json|jsonl>
        \\  --quiet
        \\
    , .{});
}

test "cli main: help and unknown command" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();

    var help = try runner.run(&.{"--help"});
    defer help.deinit();
    try helpers.runner_mod.expectSuccess(help);
    try helpers.runner_mod.expectStderrContains(help, "Usage");

    var unknown = try runner.run(&.{"unknown-command"});
    defer unknown.deinit();
    try helpers.runner_mod.expectFailure(unknown);
}

test "cli main: public API coverage" {
    _ = run;
    _ = printUsage;
}
