//! cr-sqlite changeset wire format.
//!
//! Captures local changes from `crsql_changes` and applies remote ones
//! back into the same vtab. cr-sqlite's merge engine does the heavy
//! lifting — this module is just the serialization layer + a
//! high-water-mark for incremental capture.
//!
//! Wire format is a JSON array of row objects:
//!   {
//!     "t":   <table_name>,         // CRR table this row belongs to
//!     "pk":  "<hex>",              // primary key blob, hex-encoded
//!     "cid": <column_name>,        // column being modified
//!     "val": <typed>,              // see below
//!     "cv":  <col_version>,        // cr-sqlite per-column clock
//!     "dv":  <db_version>,         // cr-sqlite DB-wide clock
//!     "sid": "<hex>",              // originating site_id, hex-encoded
//!     "cl":  <causal_length>,
//!     "seq": <intra-tx-seq>
//!   }
//!
//! `val` types:
//!   - JSON null     → SQLite NULL
//!   - JSON string   → SQLite TEXT
//!   - JSON number   → SQLite INTEGER (no fractional) or REAL
//!   - {"b":"<hex>"} → SQLite BLOB (hex-encoded bytes)
//!
//! Identical to the wire format the POC at /demos/crsqlite-content-poc
//! uses, so a relay running this plugin can broadcast frames to / accept
//! frames from any POC replica.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;

// In-memory high-water-mark of the local `db_version` we've already
// broadcast. Survives only as long as the process; on restart we
// re-broadcast everything (cr-sqlite's merge is idempotent — replicas
// see they already have these rows and drop them). A persistent
// watermark would be a nice optimization, not a correctness fix.
var state_lock: std.Thread.Mutex = .{};
var last_db_version: i64 = 0;

// =============================================================================
// Capture: local DB → JSON
// =============================================================================

/// Read every `crsql_changes` row with `db_version > last_seen`, render
/// to JSON, advance the high-water-mark. Caller owns the returned slice.
pub fn captureChanges(d: *Db, alloc: std.mem.Allocator) ![]u8 {
    state_lock.lock();
    const since = last_db_version;
    state_lock.unlock();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    var max_dv: i64 = since;
    try w.writeByte('[');

    const sql =
        \\SELECT "table", pk, cid, val, col_version, db_version,
        \\       COALESCE(site_id, crsql_site_id()) AS site_id, cl, seq
        \\FROM crsql_changes
        \\WHERE db_version > ?1
        \\ORDER BY db_version, seq;
    ;
    var stmt = try d.prepare(sql);
    defer stmt.deinit();
    try stmt.bindInt(1, since);

    var first = true;
    while (try stmt.step()) {
        if (!first) try w.writeByte(',');
        first = false;

        try w.writeAll("{\"t\":");
        try writeJsonString(w, stmt.columnText(0) orelse "");
        try w.writeAll(",\"pk\":\"");
        try hexEncode(w, stmt.columnBlob(1) orelse &.{});
        try w.writeAll("\",\"cid\":");
        try writeJsonString(w, stmt.columnText(2) orelse "");
        try w.writeAll(",\"val\":");
        try writeVal(w, &stmt, 3);
        const cv = stmt.columnInt(4);
        const dv = stmt.columnInt(5);
        if (dv > max_dv) max_dv = dv;
        try w.print(",\"cv\":{d},\"dv\":{d},\"sid\":\"", .{ cv, dv });
        try hexEncode(w, stmt.columnBlob(6) orelse &.{});
        try w.print("\",\"cl\":{d},\"seq\":{d}}}", .{
            stmt.columnInt(7),
            stmt.columnInt(8),
        });
    }

    try w.writeByte(']');

    state_lock.lock();
    if (max_dv > last_db_version) last_db_version = max_dv;
    state_lock.unlock();

    return buf.toOwnedSlice(alloc);
}

fn writeVal(w: anytype, stmt: *Statement, idx: u32) !void {
    switch (stmt.columnSqliteType(idx)) {
        .Null => try w.writeAll("null"),
        .Text => try writeJsonString(w, stmt.columnText(idx) orelse ""),
        .Integer => try w.print("{d}", .{stmt.columnInt(idx)}),
        .Real => try w.print("{d}", .{stmt.columnReal(idx)}),
        .Blob => {
            try w.writeAll("{\"b\":\"");
            try hexEncode(w, stmt.columnBlob(idx) orelse &.{});
            try w.writeAll("\"}");
        },
    }
}

/// Reset the high-water-mark and capture everything in `crsql_changes`.
/// Used for catch-up emit when a sync transport becomes available — e.g.
/// the WS just connected on a WASM replica that has OPFS-restored state,
/// or a fresh replica connected to a long-lived relay. cr-sqlite's merge
/// dedupes against existing rows so receivers handle re-sends safely.
pub fn captureAll(d: *Db, alloc: std.mem.Allocator) ![]u8 {
    state_lock.lock();
    last_db_version = 0;
    state_lock.unlock();
    return captureChanges(d, alloc);
}

// =============================================================================
// Apply: JSON → local DB
// =============================================================================

/// Parse `payload` (the JSON array of rows produced by `captureChanges`)
/// and INSERT every row into `crsql_changes`. cr-sqlite's merge engine
/// picks them up from there. Wrapped in a single transaction so a
/// half-parsed frame doesn't leave the DB in a partial state.
pub fn applyChanges(d: *Db, alloc: std.mem.Allocator, payload: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotAnArray;

    try d.exec("BEGIN;");
    errdefer d.exec("ROLLBACK;") catch {};

    var ins = try d.prepare(
        \\INSERT INTO crsql_changes
        \\  ("table", pk, cid, val, col_version, db_version, site_id, cl, seq)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
    );
    defer ins.deinit();

    for (parsed.value.array.items) |row| {
        if (row != .object) return error.RowNotObject;
        const obj = row.object;
        ins.reset();

        try ins.bindText(1, jsonString(obj, "t") orelse return error.MissingT);

        const pk_hex = jsonString(obj, "pk") orelse return error.MissingPk;
        const pk = try alloc.alloc(u8, pk_hex.len / 2);
        defer alloc.free(pk);
        try hexDecode(pk, pk_hex);
        try ins.bindBlob(2, pk);

        try ins.bindText(3, jsonString(obj, "cid") orelse return error.MissingCid);

        try bindVal(&ins, alloc, obj.get("val") orelse return error.MissingVal);

        try ins.bindInt(5, jsonInt(obj, "cv") orelse return error.MissingCv);
        try ins.bindInt(6, jsonInt(obj, "dv") orelse return error.MissingDv);

        const sid_hex = jsonString(obj, "sid") orelse return error.MissingSid;
        const sid = try alloc.alloc(u8, sid_hex.len / 2);
        defer alloc.free(sid);
        try hexDecode(sid, sid_hex);
        try ins.bindBlob(7, sid);

        try ins.bindInt(8, jsonInt(obj, "cl") orelse return error.MissingCl);
        try ins.bindInt(9, jsonInt(obj, "seq") orelse return error.MissingSeq);

        _ = try ins.step();
    }

    try d.exec("COMMIT;");
}

fn bindVal(ins: *Statement, alloc: std.mem.Allocator, val: std.json.Value) !void {
    switch (val) {
        .null => try ins.bindNull(4),
        .string => |s| try ins.bindText(4, s),
        .integer => |i| try ins.bindInt(4, i),
        .float => |f| try ins.bindReal(4, f),
        .number_string => |s| try ins.bindText(4, s),
        .object => |o| {
            // Blob variant: {"b": "<hex>"}.
            const hex = if (o.get("b")) |v| switch (v) {
                .string => |s| s,
                else => return error.BlobNotString,
            } else return error.UnsupportedValType;
            const blob = try alloc.alloc(u8, hex.len / 2);
            defer alloc.free(blob);
            try hexDecode(blob, hex);
            try ins.bindBlob(4, blob);
        },
        else => return error.UnsupportedValType,
    }
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

// =============================================================================
// Encoding helpers
// =============================================================================

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn hexEncode(w: anytype, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        try w.writeByte(hex[b >> 4]);
        try w.writeByte(hex[b & 0x0f]);
    }
}

fn hexDecode(out: []u8, hex: []const u8) !void {
    if (hex.len != out.len * 2) return error.InvalidHexLength;
    for (out, 0..) |*b, i| {
        const hi = try std.fmt.charToDigit(hex[i * 2], 16);
        const lo = try std.fmt.charToDigit(hex[i * 2 + 1], 16);
        b.* = (hi << 4) | lo;
    }
}
