const std = @import("std");

pub const ParseError = error{
    InvalidFormat,
    InvalidDate,
};

/// Parse ISO-8601/RFC3339 datetime into unix timestamp (seconds).
/// Supported formats:
/// - `YYYY-MM-DDTHH:MM:SSZ`
/// - `YYYY-MM-DDTHH:MM:SS+HH:MM`
/// - `YYYY-MM-DDTHH:MM:SS-HH:MM`
/// - Unix timestamp in seconds (`1700000000`) for compatibility.
pub fn parseIso8601ToUnix(value: []const u8) !i64 {
    if (value.len == 0) return ParseError.InvalidFormat;

    // Backward-compatible fallback for plain unix seconds.
    if (isAllDigits(value)) {
        return std.fmt.parseInt(i64, value, 10) catch ParseError.InvalidFormat;
    }

    if (value.len < 20) return ParseError.InvalidFormat;
    if (value[4] != '-' or value[7] != '-') return ParseError.InvalidFormat;
    if (value[10] != 'T' and value[10] != ' ') return ParseError.InvalidFormat;
    if (value[13] != ':' or value[16] != ':') return ParseError.InvalidFormat;

    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return ParseError.InvalidFormat;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return ParseError.InvalidFormat;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return ParseError.InvalidFormat;
    const hour = std.fmt.parseInt(i64, value[11..13], 10) catch return ParseError.InvalidFormat;
    const minute = std.fmt.parseInt(i64, value[14..16], 10) catch return ParseError.InvalidFormat;
    const second = std.fmt.parseInt(i64, value[17..19], 10) catch return ParseError.InvalidFormat;

    if (month < 1 or month > 12) return ParseError.InvalidDate;
    if (hour < 0 or hour > 23) return ParseError.InvalidDate;
    if (minute < 0 or minute > 59) return ParseError.InvalidDate;
    if (second < 0 or second > 59) return ParseError.InvalidDate;

    const max_day = daysInMonth(year, month);
    if (day < 1 or day > max_day) return ParseError.InvalidDate;

    var idx: usize = 19;
    // Optional fractional seconds.
    if (idx < value.len and value[idx] == '.') {
        idx += 1;
        const start = idx;
        while (idx < value.len and std.ascii.isDigit(value[idx])) : (idx += 1) {}
        if (idx == start) return ParseError.InvalidFormat;
    }

    var offset_seconds: i64 = 0;
    if (idx >= value.len) return ParseError.InvalidFormat;
    const tz = value[idx];
    if (tz == 'Z' or tz == 'z') {
        idx += 1;
    } else if (tz == '+' or tz == '-') {
        if (idx + 6 > value.len) return ParseError.InvalidFormat;
        if (value[idx + 3] != ':') return ParseError.InvalidFormat;
        const tz_hour = std.fmt.parseInt(i64, value[idx + 1 .. idx + 3], 10) catch return ParseError.InvalidFormat;
        const tz_min = std.fmt.parseInt(i64, value[idx + 4 .. idx + 6], 10) catch return ParseError.InvalidFormat;
        if (tz_hour > 23 or tz_min > 59) return ParseError.InvalidDate;
        offset_seconds = tz_hour * 3600 + tz_min * 60;
        if (tz == '-') offset_seconds = -offset_seconds;
        idx += 6;
    } else {
        return ParseError.InvalidFormat;
    }

    if (idx != value.len) return ParseError.InvalidFormat;

    const days = daysFromCivil(year, month, day);
    const local_seconds = days * 86400 + hour * 3600 + minute * 60 + second;
    return local_seconds - offset_seconds;
}

fn isAllDigits(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0) and ((@mod(year, 100) != 0) or (@mod(year, 400) == 0));
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Howard Hinnant civil-date to days-from-epoch conversion.
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const m = @as(i64, month);
    const d = @as(i64, day);
    const y = year - (if (m <= 2) @as(i64, 1) else @as(i64, 0));
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = m + (if (m > 2) @as(i64, -3) else @as(i64, 9)); // Mar=0..Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

test "parse iso8601 Z timestamp" {
    const ts = try parseIso8601ToUnix("1970-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "parse iso8601 with positive offset" {
    const ts = try parseIso8601ToUnix("1970-01-01T01:00:00+01:00");
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "parse iso8601 with negative offset" {
    const ts = try parseIso8601ToUnix("1970-01-01T00:30:00-00:30");
    try std.testing.expectEqual(@as(i64, 3600), ts);
}

test "parse unix seconds compatibility" {
    const ts = try parseIso8601ToUnix("1700000000");
    try std.testing.expectEqual(@as(i64, 1700000000), ts);
}

test "reject invalid timestamp" {
    try std.testing.expectError(ParseError.InvalidFormat, parseIso8601ToUnix("nope"));
}

test "time: public API coverage" {
    _ = parseIso8601ToUnix;
}
