//! Storage routing for content entries.
//!
//! The runtime registry declares which fields are `.filterable` (project to
//! `entry_meta` typed columns for index-friendly filter/sort) and which are
//! `.searchable` (project to the `entries_fts` FTS5 virtual table). This
//! module owns those projections.
//!
//! Reads stay JOIN-free: the canonical record is `content_entries.data`
//! JSON. `entry_meta` and `entries_fts` are write-only duplicates kept in
//! sync inside the same transaction as the parent `content_entries` write.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const Statement = db_mod.Statement;
const field_mod = @import("field");
const content_type_mod = @import("content_type");
const entry_mod = @import("entry");

const FieldDef = field_mod.FieldDef;
const ContentTypeDef = content_type_mod.ContentTypeDef;

/// Unified field-value map. Same shape used by reads (parsed from
/// `entries.data` JSON) and writes (projected to `entry_meta` /
/// `entries_fts`).
pub const FieldMap = entry_mod.FieldMap;
pub const FieldValue = entry_mod.FieldValue;

pub const Error = error{
    BindFailed,
    StepFailed,
    PrepareFailed,
    ExecFailed,
    OutOfMemory,
    AllocationFailed,
};

/// Insert/upsert one `entry_meta` row for the given field. Empty/null
/// values still write a row (so a NULL → not-NULL update goes through one
/// path), but callers can skip entirely by not calling this for absent
/// fields.
pub fn writeEntryMetaRow(
    db: *Db,
    entry_id: []const u8,
    field: FieldDef,
    value: FieldValue,
) Db.Error!void {
    var stmt = try db.prepare(
        \\INSERT INTO entry_meta (entry_id, field_name, text_value, int_value, real_value, datetime_value)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        \\ON CONFLICT(entry_id, field_name) DO UPDATE SET
        \\  text_value = excluded.text_value,
        \\  int_value = excluded.int_value,
        \\  real_value = excluded.real_value,
        \\  datetime_value = excluded.datetime_value
    );
    defer stmt.deinit();

    try stmt.bindText(1, entry_id);
    try stmt.bindText(2, field.name);
    try bindFieldValue(&stmt, value);
    _ = try stmt.step();
}

/// Write every filterable field on `def` to `entry_meta`. Fields missing
/// from `data` are skipped — the typed column row only exists if the
/// caller provided a value.
pub fn writeEntryMeta(
    db: *Db,
    entry_id: []const u8,
    def: *const ContentTypeDef,
    data: FieldMap,
) Db.Error!void {
    for (def.fields) |f| {
        if (!f.filterable) continue;
        const value = data.get(f.name) orelse continue;
        try writeEntryMetaRow(db, entry_id, f, value);
    }
}

/// Bind a `FieldValue` to indices 3..6 of an `entry_meta` insert statement.
/// Routes the value to the column that matches its variant: `.text` →
/// `text_value`, `.int`/`.bool_` → `int_value`, `.real` → `real_value`,
/// `.datetime` → `datetime_value`. `.json` and `.null_` write all-NULL.
fn bindFieldValue(stmt: *Statement, value: FieldValue) Db.Error!void {
    try stmt.bindNull(3);
    try stmt.bindNull(4);
    try stmt.bindNull(5);
    try stmt.bindNull(6);

    switch (value) {
        .text => |s| try stmt.bindText(3, s),
        .int => |n| try stmt.bindInt(4, n),
        .real => |n| try stmt.bindReal(5, n),
        .bool_ => |b| try stmt.bindInt(4, if (b) 1 else 0),
        .datetime => |t| try stmt.bindInt(6, t),
        .json, .null_ => {},
    }
}

/// Convenience: build a `FieldValue` from a text representation, coerced
/// according to the field's declared `meta_type`. Returns `.null_` when
/// the input is empty/unparseable.
pub fn fieldValueFromText(
    field: FieldDef,
    text: ?[]const u8,
) FieldValue {
    const t = text orelse return .null_;
    return switch (field.meta_type) {
        .text => .{ .text = t },
        .int => if (std.fmt.parseInt(i64, t, 10)) |n| .{ .int = n } else |_| .null_,
        .real => if (std.fmt.parseFloat(f64, t)) |n| .{ .real = n } else |_| .null_,
    };
}

/// Delete every `entry_meta` row for an entry. Usually redundant — the
/// `ON DELETE CASCADE` FK does this automatically — but useful when
/// rebuilding meta without dropping the parent row.
pub fn deleteEntryMeta(db: *Db, entry_id: []const u8) Db.Error!void {
    var stmt = try db.prepare("DELETE FROM entry_meta WHERE entry_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

/// Rewrite every `entries_fts` row for an entry. FTS5 has no UPSERT path
/// for arbitrary content, so we clear-and-reinsert. Called from `writeEntry`
/// inside the parent transaction.
pub fn writeEntryFts(
    db: *Db,
    entry_id: []const u8,
    def: *const ContentTypeDef,
    data: FieldMap,
) Db.Error!void {
    try deleteEntryFts(db, entry_id);

    var stmt = try db.prepare(
        \\INSERT INTO entries_fts (entry_id, content_type_id, field_name, value)
        \\VALUES (?1, ?2, ?3, ?4)
    );
    defer stmt.deinit();

    for (def.fields) |f| {
        if (!f.searchable) continue;
        const value = data.get(f.name) orelse continue;
        const text = switch (value) {
            .text => |s| if (s.len > 0) s else continue,
            else => continue, // only text values are FTS-indexable
        };

        try stmt.bindText(1, entry_id);
        try stmt.bindText(2, def.type_id);
        try stmt.bindText(3, f.name);
        try stmt.bindText(4, text);
        _ = try stmt.step();
        stmt.reset();
    }
}

/// Remove every `entries_fts` row for an entry. FTS5 is a separate
/// virtual table — `ON DELETE CASCADE` on `content_entries` doesn't reach
/// it, so call this explicitly when an entry is deleted.
pub fn deleteEntryFts(db: *Db, entry_id: []const u8) Db.Error!void {
    var stmt = try db.prepare("DELETE FROM entries_fts WHERE entry_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

/// Transactional projection write. Wraps `writeEntryMeta` +
/// `writeEntryFts` in a single transaction so meta and FTS rows stay in
/// sync with the parent `content_entries` row.
///
/// Note: the caller is responsible for writing the `content_entries` row
/// itself before calling this. Task 03 wires this into `cms.createEntry`.
pub fn writeEntry(
    db: *Db,
    entry_id: []const u8,
    def: *const ContentTypeDef,
    data: FieldMap,
) Db.Error!void {
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};

    try writeEntryMeta(db, entry_id, def, data);
    try writeEntryFts(db, entry_id, def, data);

    try db.exec("COMMIT");
}

// Tests for this module live in `src/tests/storage_tests.zig` — the test
// runner aggregates them there so the schema SQL embed resolves through
// the package boundary and so Zig 0.15 actually discovers the test blocks.
