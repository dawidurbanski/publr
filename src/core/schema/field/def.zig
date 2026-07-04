//! FieldDef + shared helpers used by every builder in `field/`.
//!
//! Two helpers absorb repetition the builders used to ship inline:
//!   - `requiredCheck` is the "if opts.required and empty, fail" check
//!     that ran in 13 of the builders verbatim.
//!   - `humanize` capitalizes snake_case at comptime.
//!
//! (The label-row HTML is now emitted by the FieldLabelRow ZSX component; the
//! former `writeFieldLabelRow` + `FieldLabelKind` were removed once every field
//! renders through its ZSX component — see epic #191 / A5.)

const std = @import("std");

// =============================================================================
// Core Types
// =============================================================================

/// Context passed to field render functions.
pub const RenderContext = struct {
    name: []const u8,
    display_name: []const u8,
    value: ?[]const u8,
    required: bool,
    errors: ?[]const []const u8 = null,
    allocator: ?std.mem.Allocator = null,
};

/// Storage hint for the field — determines where data is persisted.
pub const StorageHint = enum {
    data_only,
    data_and_meta,
    taxonomy,
};

/// Meta value type for entry_meta storage.
pub const MetaValueType = enum {
    text,
    int,
    real,
};

/// Field position in the edit layout.
pub const Position = enum {
    main,
    side,
};

/// Locale behavior for a field.
pub const TranslatableMode = enum {
    synced,
    independent,
    with_fallback,
};

/// Field definition — the unit of schema composition.
pub const FieldDef = struct {
    name: []const u8,
    display_name: []const u8,
    field_type_id: []const u8,
    required: bool = false,
    translatable_mode: TranslatableMode = .independent,
    storage: StorageHint = .data_only,
    meta_type: MetaValueType = .text,
    filterable: bool = false,
    searchable: bool = false,
    multi: bool = false,
    taxonomy_id: ?[]const u8 = null,
    position: Position = .main,
    source_field: ?[]const u8 = null,
    sub_fields: []const FieldDef = &.{},
    validate: *const fn (value: []const u8) ?[]const u8,
    render: *const fn (writer: std.io.AnyWriter, ctx: RenderContext) anyerror!void,

    pub fn jsonStringify(self: FieldDef, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("display_name");
        try jw.write(self.display_name);
        try jw.objectField("field_type_id");
        try jw.write(self.field_type_id);
        try jw.objectField("required");
        try jw.write(self.required);
        try jw.objectField("translatable_mode");
        try jw.write(@tagName(self.translatable_mode));
        try jw.objectField("storage");
        try jw.write(@tagName(self.storage));
        try jw.objectField("meta_type");
        try jw.write(@tagName(self.meta_type));
        try jw.objectField("filterable");
        try jw.write(self.filterable);
        try jw.objectField("searchable");
        try jw.write(self.searchable);
        try jw.objectField("multi");
        try jw.write(self.multi);
        try jw.objectField("taxonomy_id");
        try jw.write(self.taxonomy_id);
        try jw.objectField("position");
        try jw.write(@tagName(self.position));
        try jw.objectField("source_field");
        try jw.write(self.source_field);
        try jw.endObject();
    }
};

// =============================================================================
// Comptime helpers
// =============================================================================

/// Convert snake_case to Title Case: "featured_image" -> "Featured Image".
pub fn humanize(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var result: [name.len]u8 = undefined;
        var capitalize_next = true;

        for (name, 0..) |ch, i| {
            if (ch == '_') {
                result[i] = ' ';
                capitalize_next = true;
            } else if (capitalize_next) {
                result[i] = std.ascii.toUpper(ch);
                capitalize_next = false;
            } else {
                result[i] = ch;
            }
        }

        const final = result;
        break :blk &final;
    };
}

/// No-op validation. Used by builders that don't need any validation.
pub fn noValidation(_: []const u8) ?[]const u8 {
    return null;
}

/// No-op render. Placeholder for built-in field types still under construction.
pub fn noRender(_: std.io.AnyWriter, _: RenderContext) !void {}

// =============================================================================
// Render helpers shared across builders
// =============================================================================

/// The "if required and empty" check that 13 scalar builders ran verbatim.
/// Returns the canonical error message; pass a different one via
/// `requiredCheckMsg` if a builder ever needs to customize.
pub fn requiredCheck(opts: anytype, value: []const u8) ?[]const u8 {
    if (opts.required and value.len == 0) return "This field is required";
    return null;
}
