const std = @import("std");
const builtin = @import("builtin");
const Db = @import("db").Db;
const storage = @import("storage");

pub const RunResult = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

pub const CliTestRunner = struct {
    allocator: std.mem.Allocator,
    bin_path: []const u8,
    db_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !CliTestRunner {
        if (builtin.os.tag == .wasi) return error.UnsupportedOnWasi;

        const db_path = try std.fmt.allocPrint(allocator, "/tmp/publr-cli-test-{d}.db", .{std.time.nanoTimestamp()});
        return .{
            .allocator = allocator,
            .bin_path = "zig-out/bin/publr",
            .db_path = db_path,
        };
    }

    pub fn deinit(self: *CliTestRunner) void {
        cleanupFilesystemMediaForDb(self.allocator, self.db_path);
        std.fs.cwd().deleteFile(self.db_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
        self.allocator.free(self.db_path);
    }

    pub fn run(self: *CliTestRunner, args: []const []const u8) !RunResult {
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, self.bin_path);
        for (args) |arg| try argv.append(self.allocator, arg);
        if (!hasDbFlag(args)) {
            try argv.append(self.allocator, "--db");
            try argv.append(self.allocator, self.db_path);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .max_output_bytes = 256 * 1024,
        });

        const exit_code: u8 = switch (result.term) {
            .Exited => |code| code,
            else => 255,
        };

        return .{
            .allocator = self.allocator,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = exit_code,
        };
    }
};

pub fn expectSuccess(result: RunResult) !void {
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

pub fn expectFailure(result: RunResult) !void {
    try std.testing.expect(result.exit_code != 0);
}

pub fn expectStdoutContains(result: RunResult, expected: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected) != null);
}

pub fn expectStderrContains(result: RunResult, expected: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
}

pub fn expectJsonOutput(allocator: std.mem.Allocator, result: RunResult) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
}

fn hasDbFlag(args: []const []const u8) bool {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--db")) return i + 1 < args.len;
        if (std.mem.startsWith(u8, arg, "--db=")) return true;
    }
    return false;
}

fn cleanupFilesystemMediaForDb(allocator: std.mem.Allocator, db_path: []const u8) void {
    std.fs.cwd().access(db_path, .{}) catch return;

    var db = Db.init(allocator, db_path) catch return;
    defer db.deinit();

    var stmt = db.prepare("SELECT storage_key FROM media") catch return;
    defer stmt.deinit();

    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;
        const storage_key = stmt.columnText(0) orelse continue;
        const key_copy = allocator.dupe(u8, storage_key) catch continue;
        storage.filesystem.delete(allocator, key_copy) catch {};
        allocator.free(key_copy);
    }
}
