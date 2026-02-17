const std = @import("std");
const core_init = @import("core_init");
const core_time = @import("core_time");
const Db = @import("db").Db;
const fmt = @import("cli_format");

pub const GlobalOptions = struct {
    db_path: []const u8 = "data/publr.db",
    format: fmt.OutputFormat = .table,
    quiet: bool = false,
};

pub const ParsedCli = struct {
    opts: GlobalOptions,
    args: []const []const u8,
};

pub fn extractGlobalOptions(allocator: std.mem.Allocator, raw_args: []const []const u8) !ParsedCli {
    var opts = GlobalOptions{};
    var cleaned: std.ArrayList([]const u8) = .{};
    errdefer cleaned.deinit(allocator);

    var i: usize = 0;
    while (i < raw_args.len) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= raw_args.len) return error.MissingDbPath;
            opts.db_path = raw_args[i];
        } else if (std.mem.startsWith(u8, arg, "--db=")) {
            opts.db_path = arg["--db=".len..];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= raw_args.len) return error.MissingFormat;
            opts.format = fmt.OutputFormat.fromString(raw_args[i]) orelse return error.InvalidFormat;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            opts.format = fmt.OutputFormat.fromString(value) orelse return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else {
            try cleaned.append(allocator, arg);
        }
        i += 1;
    }

    return .{
        .opts = opts,
        .args = try cleaned.toOwnedSlice(allocator),
    };
}

pub fn openDb(allocator: std.mem.Allocator, opts: GlobalOptions) !Db {
    var db = try core_init.initDatabase(allocator, opts.db_path);
    errdefer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);
    return db;
}

pub fn promptConfirm(prompt: []const u8, force: bool) !bool {
    if (force) return true;

    const stdin = std.fs.File.stdin();
    if (!std.posix.isatty(stdin.handle)) {
        return error.ForceRequiredForNonInteractive;
    }

    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.print("{s} [y/N]: ", .{prompt});

    var buf: [32]u8 = undefined;
    const n = try stdin.read(&buf);
    if (n == 0) return false;

    const answer = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "YES");
}

pub fn parseIsoTimestamp(value: []const u8) !i64 {
    return core_time.parseIso8601ToUnix(value);
}

pub fn printUsageError(message: []const u8) void {
    std.debug.print("Error: {s}\n", .{message});
}

test "cli common: extractGlobalOptions parses variants" {
    const parsed = try extractGlobalOptions(std.testing.allocator, &.{
        "content",
        "list",
        "post",
        "--db=/tmp/custom.db",
        "--format",
        "json",
        "--quiet",
    });
    defer std.testing.allocator.free(parsed.args);

    try std.testing.expectEqualStrings("/tmp/custom.db", parsed.opts.db_path);
    try std.testing.expectEqual(fmt.OutputFormat.json, parsed.opts.format);
    try std.testing.expect(parsed.opts.quiet);
    try std.testing.expectEqual(@as(usize, 3), parsed.args.len);
}

test "cli common: extractGlobalOptions validates format errors" {
    try std.testing.expectError(error.MissingFormat, extractGlobalOptions(std.testing.allocator, &.{ "content", "list", "post", "--format" }));
    try std.testing.expectError(error.InvalidFormat, extractGlobalOptions(std.testing.allocator, &.{ "content", "list", "post", "--format", "bad" }));
}

test "cli common: promptConfirm force bypass" {
    try std.testing.expect(try promptConfirm("ignored", true));
}

test "cli common: openDb initializes schema" {
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/publr-cli-common-{d}.db", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(db_path);
    defer std.fs.cwd().deleteFile(db_path) catch {};

    var db = try openDb(std.testing.allocator, .{
        .db_path = db_path,
        .format = .table,
        .quiet = false,
    });
    defer db.deinit();

    var stmt = try db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='content_types'");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnInt(0) >= 1);
}

test "cli common: parseIsoTimestamp parses ISO-8601" {
    const ts = try parseIsoTimestamp("2030-01-01T00:00:00Z");
    try std.testing.expect(ts > 0);
}

test "cli common: printUsageError callable" {
    printUsageError("example");
}

test "cli common: public API coverage" {
    _ = extractGlobalOptions;
    _ = openDb;
    _ = promptConfirm;
    _ = parseIsoTimestamp;
    _ = printUsageError;
}
