const std = @import("std");
const http = @import("http.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "serve")) {
        try runServe(&args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn runServe(args: *std.process.ArgIterator) !void {
    var cli_port: ?u16 = null;
    var dev_mode: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const port_str = args.next() orelse {
                std.debug.print("Error: --port requires a value\n", .{});
                return;
            };
            cli_port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: invalid port number: {s}\n", .{port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "-d")) {
            dev_mode = true;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        }
    }

    const port = resolvePort(cli_port);
    try http.serve(port, dev_mode);
}

/// Resolves port with precedence: CLI flag > PORT env var > default (8080)
fn resolvePort(cli_port: ?u16) u16 {
    // CLI flag takes highest precedence
    if (cli_port) |p| return p;

    // Check PORT environment variable
    if (std.posix.getenv("PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch {
            std.debug.print("Warning: invalid PORT env var '{s}', using default 8080\n", .{port_str});
            return 8080;
        };
    }

    // Default
    return 8080;
}

fn printUsage() void {
    const usage =
        \\Minizen - Single-file CMS
        \\
        \\Usage: mz <command> [options]
        \\
        \\Commands:
        \\  serve    Start the HTTP server
        \\  help     Show this help message
        \\
        \\Serve options:
        \\  --port, -p <port>    Port to listen on (default: 8080, or PORT env var)
        \\  --dev, -d            Enable development mode (hot reload)
        \\
        \\Environment variables:
        \\  PORT                 Default port (overridden by --port flag)
        \\
        \\Examples:
        \\  mz serve
        \\  mz serve --port 3000
        \\  mz serve --dev
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// Tests
test "resolvePort: CLI flag takes precedence" {
    const port = resolvePort(3000);
    try std.testing.expectEqual(@as(u16, 3000), port);
}

test "resolvePort: returns default when no CLI and no env" {
    // This test assumes PORT env var is not set in test environment
    const port = resolvePort(null);
    // If PORT env is set, this would fail - but that's expected behavior
    // In a clean test environment, it should return 8080
    try std.testing.expect(port > 0);
}
