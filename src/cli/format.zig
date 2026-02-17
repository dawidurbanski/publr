const std = @import("std");

pub const OutputFormat = enum {
    table,
    json,
    jsonl,

    pub fn fromString(value: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, value, "table")) return .table;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "jsonl")) return .jsonl;
        return null;
    }

    pub fn toString(self: OutputFormat) []const u8 {
        return @tagName(self);
    }
};

pub const KeyValueRow = struct {
    key: []const u8,
    value: []const u8,
};

pub fn printJson(value: anytype) !void {
    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.print("{f}", .{std.json.fmt(value, .{})});
    try stdout.interface.writeByte('\n');
}

pub fn printJsonLine(value: anytype) !void {
    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.print("{f}", .{std.json.fmt(value, .{})});
    try stdout.interface.writeByte('\n');
}

pub fn printTable(headers: []const []const u8, rows: []const []const []const u8, quiet: bool, allocator: std.mem.Allocator) !void {
    var stdout = std.fs.File.stdout().writer(&.{});
    if (headers.len == 0) return;

    var widths = try allocator.alloc(usize, headers.len);
    defer allocator.free(widths);

    for (headers, 0..) |header, i| {
        widths[i] = header.len;
    }

    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i < widths.len) {
                widths[i] = @max(widths[i], cell.len);
            }
        }
    }

    if (!quiet) {
        for (headers, 0..) |header, i| {
            try stdout.interface.print("{s}", .{header});
            const padding = widths[i] - header.len + 2;
            for (0..padding) |_| try stdout.interface.writeByte(' ');
        }
        try stdout.interface.writeByte('\n');

        for (widths) |width| {
            for (0..width) |_| try stdout.interface.writeByte('-');
            try stdout.interface.writeAll("  ");
        }
        try stdout.interface.writeByte('\n');
    }

    for (rows) |row| {
        for (row, 0..) |cell, i| {
            try stdout.interface.print("{s}", .{cell});
            if (i < widths.len) {
                const padding = widths[i] - cell.len + 2;
                for (0..padding) |_| try stdout.interface.writeByte(' ');
            }
        }
        try stdout.interface.writeByte('\n');
    }
}

pub fn printKeyValueRows(rows: []const KeyValueRow, quiet: bool, allocator: std.mem.Allocator) !void {
    var table_rows: std.ArrayList([]const []const u8) = .{};
    defer table_rows.deinit(allocator);

    for (rows) |row| {
        const cols = try allocator.alloc([]const u8, 2);
        cols[0] = row.key;
        cols[1] = row.value;
        try table_rows.append(allocator, cols);
    }
    defer {
        for (table_rows.items) |cols| allocator.free(cols);
    }

    try printTable(&.{ "Field", "Value" }, table_rows.items, quiet, allocator);
}

test "cli format: output format conversion branches" {
    try std.testing.expectEqual(OutputFormat.table, OutputFormat.fromString("table").?);
    try std.testing.expectEqual(OutputFormat.json, OutputFormat.fromString("json").?);
    try std.testing.expectEqual(OutputFormat.jsonl, OutputFormat.fromString("jsonl").?);
    try std.testing.expect(OutputFormat.fromString("invalid") == null);
    try std.testing.expectEqualStrings("json", OutputFormat.json.toString());
}

test "cli format: print helpers are callable" {
    try printJson(.{ .ok = true });
    try printJsonLine(.{ .ok = true });

    const rows = [_][]const []const u8{
        &.{ "1", "Alice" },
        &.{ "2", "Bob" },
    };
    try printTable(&.{ "ID", "Name" }, &rows, false, std.testing.allocator);

    const kv = [_]KeyValueRow{
        .{ .key = "id", .value = "1" },
        .{ .key = "name", .value = "Alice" },
    };
    try printKeyValueRows(&kv, true, std.testing.allocator);
}

test "cli format: public API coverage" {
    _ = printJson;
    _ = printJsonLine;
    _ = printTable;
    _ = printKeyValueRows;
}
