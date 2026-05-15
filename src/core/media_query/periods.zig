//! Distinct year/month period queries — used to drive the date picker in
//! the media library sidebar.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;

const Allocator = std.mem.Allocator;

/// A distinct year/month period found in media created_at timestamps.
pub const DatePeriod = struct { year: u16, month: u8 };

/// Get distinct year/month periods, ordered newest first.
pub fn getDistinctDatePeriods(allocator: Allocator, db: *Db) ![]DatePeriod {
    var stmt = try db.prepare(
        \\SELECT DISTINCT
        \\  CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER),
        \\  CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER)
        \\FROM media ORDER BY 1 DESC, 2 DESC
    );
    defer stmt.deinit();

    var items: std.ArrayListUnmanaged(DatePeriod) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const y = stmt.columnInt(0);
        const m = stmt.columnInt(1);
        if (y > 0 and m > 0 and m <= 12) {
            try items.append(allocator, .{
                .year = @intCast(y),
                .month = @intCast(m),
            });
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Get distinct years from media (deduplicated).
pub fn getDistinctYears(allocator: Allocator, db: *Db) ![]u16 {
    var stmt = try db.prepare(
        "SELECT DISTINCT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) FROM media ORDER BY 1 DESC",
    );
    defer stmt.deinit();

    var items: std.ArrayListUnmanaged(u16) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const y = stmt.columnInt(0);
        if (y > 0) try items.append(allocator, @intCast(y));
    }

    return items.toOwnedSlice(allocator);
}

/// Get months available in a given year.
pub fn getMonthsForYear(allocator: Allocator, db: *Db, year: u16) ![]u8 {
    var stmt = try db.prepare(
        "SELECT DISTINCT CAST(strftime('%m', created_at, 'unixepoch') AS INTEGER) FROM media WHERE CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) = ?1 ORDER BY 1 DESC",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, @intCast(year));

    var items: std.ArrayListUnmanaged(u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        const m = stmt.columnInt(0);
        if (m > 0 and m <= 12) try items.append(allocator, @intCast(m));
    }

    return items.toOwnedSlice(allocator);
}
