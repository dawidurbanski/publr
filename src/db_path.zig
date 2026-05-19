//! Canonical DB path resolution — single source of truth for every entry
//! point (CLI commands, `serve`, build-time tools).
//!
//! Resolution priority:
//!   1. Explicit `--db <path>` flag from the caller
//!   2. `PUBLR_DB` env var
//!   3. `<project_root>/data/publr.db` — project_root is the topmost
//!      ancestor of CWD containing a `publr.zon` marker
//!   4. `data/publr.db` (relative to CWD) — last-resort fallback
//!
//! Anchoring to the project root makes the resolved path stable regardless
//! of the working directory the binary was invoked from. Without this, a
//! `publr starter add post` from `zig-out/bin/` writes to a different DB
//! than `publr serve` started from the project root.

const std = @import("std");

pub const Resolved = struct {
    path: []const u8,
    /// True when `path` is heap-allocated and the caller must free it.
    owned: bool,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

pub fn resolve(allocator: std.mem.Allocator, cli_arg: ?[]const u8) !Resolved {
    if (cli_arg) |p| if (p.len > 0) return .{ .path = p, .owned = false };

    if (std.posix.getenv("PUBLR_DB")) |env_path| {
        if (env_path.len > 0) return .{ .path = env_path, .owned = false };
    }

    if (try findProjectRoot(allocator)) |root| {
        defer allocator.free(root);
        const joined = try std.fs.path.join(allocator, &.{ root, "data", "publr.db" });
        return .{ .path = joined, .owned = true };
    }

    return .{ .path = "data/publr.db", .owned = false };
}

/// Walk up from CWD and return the topmost ancestor that contains a
/// `publr.zon` marker. "Topmost" rather than "nearest" because nested
/// `publr.zon` files exist (e.g. theme manifests in `themes/*/publr.zon`)
/// and we want the outer project root, not the inner theme directory.
/// Bounded to 32 levels to keep the walk cheap and pathological-cwd-proof.
fn findProjectRoot(allocator: std.mem.Allocator) !?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur: []const u8 = std.fs.cwd().realpath(".", &cwd_buf) catch return null;

    var topmost: ?[]const u8 = null;
    errdefer if (topmost) |t| allocator.free(t);

    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, "{s}/publr.zon", .{cur}) catch break;
        if (std.fs.accessAbsolute(marker, .{})) {
            if (topmost) |t| allocator.free(t);
            topmost = try allocator.dupe(u8, cur);
        } else |_| {}

        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }

    return topmost;
}

// =============================================================================
// Tests
// =============================================================================

test "resolve: explicit cli_arg wins" {
    const r = try resolve(std.testing.allocator, "/tmp/explicit.db");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/explicit.db", r.path);
    try std.testing.expect(!r.owned);
}

test "resolve: empty cli_arg falls through to other sources" {
    const r = try resolve(std.testing.allocator, "");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.path.len > 0);
}

test "Resolved.deinit is a no-op when !owned" {
    const r = Resolved{ .path = "static", .owned = false };
    r.deinit(std.testing.allocator);
}
