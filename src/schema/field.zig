//! Field Definition and Builder Functions
//!
//! Provides the FieldDef struct and comptime builder functions for defining
//! content type schemas. Core fields and plugin fields are identical - same
//! FieldDef struct, same pattern, no second-class citizens.
//!
//! Example:
//! ```zig
//! const Post = ContentType("post", .{ .name = "Blog Post" }, &.{
//!     field.String("title", .{ .required = true, .max_length = 200 }),
//!     field.Slug("slug", .{ .source = "title" }),
//!     field.Text("body", .{ .required = true }),
//!     field.Taxonomy("category"),
//!     field.Integer("view_count", .{ .filterable = true }),
//! });
//! ```

const std = @import("std");

// =============================================================================
// Core Types
// =============================================================================

/// Context passed to field render functions
pub const RenderContext = struct {
    /// Field name (form input name)
    name: []const u8,
    /// Human-readable display name
    display_name: []const u8,
    /// Current field value (null if not set)
    value: ?[]const u8,
    /// Whether field is required
    required: bool,
    /// Validation errors for this field
    errors: ?[]const []const u8 = null,
};

/// Storage hint for the field - determines where data is persisted
pub const StorageHint = enum {
    /// Store only in entries.data JSON blob
    data_only,
    /// Store in entries.data AND entry_meta table for filtering
    data_and_meta,
    /// Store in entry_terms table (taxonomies)
    taxonomy,
};

/// Meta value type for entry_meta storage
pub const MetaValueType = enum {
    text,
    int,
    real,
};

/// Field position in the edit layout
pub const Position = enum {
    /// Main editor area (left side)
    main,
    /// Sidebar (right side) — used for metadata, images, taxonomies
    side,
};

/// Field definition - the unit of schema composition
pub const FieldDef = struct {
    /// Field identifier (used as JSON key and form input name)
    name: []const u8,

    /// Human-readable label
    display_name: []const u8,

    /// Field type identifier (e.g., "string", "text", "taxonomy")
    field_type_id: []const u8,

    /// Zig type for this field's data (used in comptime struct generation)
    zig_type: type,

    /// Whether field is required
    required: bool = false,

    /// Whether this field's value varies per locale (i18n).
    /// Default true for most fields. Ref and Image fields force false.
    /// Inert until i18n epic — no runtime behavior change.
    translatable: bool = true,

    /// Storage hint - where to persist this field's data
    storage: StorageHint = .data_only,

    /// Meta value type (only used when storage = .data_and_meta)
    meta_type: MetaValueType = .text,

    /// Taxonomy ID (only used when storage = .taxonomy)
    taxonomy_id: ?[]const u8 = null,

    /// Position in edit layout: main editor or sidebar
    position: Position = .main,

    /// Source field for auto-generation (e.g., slug from title)
    source_field: ?[]const u8 = null,

    /// Validation function - returns error message or null if valid
    validate: *const fn (value: []const u8) ?[]const u8,

    /// Render function - emits field HTML to writer
    render: *const fn (writer: std.io.AnyWriter, ctx: RenderContext) anyerror!void,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert snake_case to Title Case: "featured_image" -> "Featured Image"
pub fn humanize(comptime name: []const u8) []const u8 {
    comptime {
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
        return &final;
    }
}

/// No-op validation - always passes
fn noValidation(_: []const u8) ?[]const u8 {
    return null;
}

/// No-op render - does nothing
fn noRender(_: std.io.AnyWriter, _: RenderContext) !void {}

// =============================================================================
// Builder Functions
// =============================================================================

/// Single-line text input
pub fn String(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    max_length: ?usize = null,
    min_length: ?usize = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (opts.min_length) |min| {
                if (value.len > 0 and value.len < min) {
                    return "Value is too short";
                }
            }
            if (opts.max_length) |max| {
                if (value.len > max) {
                    return "Value is too long";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="text" class="form-control" id="{s}" name="{s}" value="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });

            if (opts.max_length) |max| {
                try writer.print(" maxlength=\"{}\"", .{max});
            }
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "string",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Multi-line text input (textarea)
pub fn Text(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    rows: u8 = 5,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <textarea class="form-control" id="{s}" name="{s}" rows="{}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, opts.rows });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.print(">{s}</textarea>\n</div>\n", .{ctx.value orelse ""});
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "text",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// URL-friendly slug, optionally auto-generated from a source field
pub fn Slug(comptime name: []const u8, comptime opts: struct {
    source: ?[]const u8 = null,
    required: bool = false,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            for (value) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') {
                    return "Slug can only contain letters, numbers, hyphens, and underscores";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="text" class="form-control" id="{s}" name="{s}" value="{s}"
                \\         data-widget="slug"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (opts.source) |src| {
                try writer.print(" data-source=\"{s}\"", .{src});
            }
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "slug",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = .data_only,
        .position = opts.position,
        .source_field = opts.source,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Reference to another content type entry
pub fn Ref(comptime name: []const u8, comptime opts: struct {
    to: []const u8,
    many: bool = false,
    required: bool = false,
    display: ?[]const u8 = null,
    translatable: bool = false,
    position: Position = .main,
}) FieldDef {
    if (opts.translatable) {
        @compileError("Ref fields cannot be translatable — references are locale-independent");
    }
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            // References should be entry IDs (e_xxx format)
            if (value.len > 0 and !std.mem.startsWith(u8, value, "e_")) {
                return "Invalid entry reference";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <div data-widget="ref-picker" data-ref-type="{s}" data-ref-many="{s}"
                \\       data-name="{s}" data-value="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" />
                \\    <button type="button" class="btn btn-sm">Select {s}</button>
                \\  </div>
                \\</div>
            , .{
                ctx.name,
                ctx.name,
                ctx.display_name,
                ctx.name,
                ctx.name,
                opts.to,
                if (opts.many) "true" else "false",
                ctx.name,
                ctx.value orelse "",
                ctx.name,
                ctx.value orelse "",
                opts.to,
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "reference",
        .zig_type = if (opts.many) []const []const u8 else []const u8,
        .required = opts.required,
        .translatable = false,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Dropdown select with fixed options
pub fn Select(comptime name: []const u8, comptime opts: struct {
    options: []const []const u8,
    required: bool = false,
    default_value: ?[]const u8 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (value.len > 0) {
                for (opts.options) |opt| {
                    if (std.mem.eql(u8, value, opt)) return null;
                }
                return "Invalid option selected";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <select class="form-control" id="{s}" name="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(">\n");

            // Empty option if not required
            if (!ctx.required) {
                try writer.writeAll("    <option value=\"\">-- Select --</option>\n");
            }

            const current = ctx.value orelse opts.default_value orelse "";
            inline for (opts.options) |opt| {
                const selected = if (std.mem.eql(u8, current, opt)) " selected" else "";
                try writer.print("    <option value=\"{s}\"{s}>{s}</option>\n", .{ opt, selected, opt });
            }

            try writer.writeAll("  </select>\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "select",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Boolean checkbox
pub fn Boolean(comptime name: []const u8, comptime opts: struct {
    default_value: bool = false,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const checked = if (ctx.value) |v|
                std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")
            else
                opts.default_value;

            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <span class="form-label">{s}</span>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <label class="form-check">
                \\    <input type="checkbox" class="form-check-input" name="{s}" value="true"{s} />
                \\    <span class="form-check-label">{s}</span>
                \\  </label>
                \\</div>
            , .{
                ctx.name,
                ctx.display_name,
                ctx.name,
                ctx.name,
                ctx.name,
                if (checked) " checked" else "",
                ctx.display_name,
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "boolean",
        .zig_type = bool,
        .required = false,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Date/time picker
pub fn DateTime(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            // TODO: validate datetime format
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="datetime-local" class="form-control" id="{s}" name="{s}" value="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "datetime",
        .zig_type = ?i64, // Unix timestamp
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .int,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Image/media reference
pub fn Image(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    translatable: bool = false,
    position: Position = .side,
}) FieldDef {
    if (opts.translatable) {
        @compileError("Image fields cannot be translatable — media references are locale-independent");
    }
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            // Media IDs should be m_xxx format
            if (value.len > 0 and !std.mem.startsWith(u8, value, "m_")) {
                return "Invalid media reference";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const value = ctx.value orelse "";
            const has_value = value.len > 0;
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <div class="image-picker" data-publr-component="image-picker" data-publr-state="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" data-publr-part="value" />
                \\    <div class="image-picker-preview" data-publr-part="preview">
            , .{
                ctx.name,
                ctx.name,
                ctx.display_name,
                ctx.name,
                ctx.name,
                if (has_value) "selected" else "empty",
                ctx.name,
                value,
            });
            // Preview content - placeholder or thumbnail
            if (has_value) {
                // When selected, show thumbnail via media URL
                try writer.print(
                    \\      <img src="/admin/media/picker/thumb/{s}" alt="" class="image-picker-thumb" />
                , .{value});
            } else {
                try writer.writeAll(
                    \\      <div class="image-picker-placeholder">
                    \\        <svg class="icon" viewBox="0 0 24 24" fill="none"><path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
                    \\        <span>No image selected</span>
                    \\      </div>
                );
            }
            try writer.print(
                \\    </div>
                \\    <div class="image-picker-actions">
                \\      <button type="button" class="btn btn-sm" data-publr-part="trigger">
                \\        {s}
                \\      </button>
                \\      <button type="button" class="btn btn-sm btn-ghost{s}" data-publr-part="remove">
                \\        Remove
                \\      </button>
                \\    </div>
                \\    <div class="image-picker-alt" data-publr-part="alt"></div>
                \\  </div>
                \\</div>
            , .{
                if (has_value) "Change Image" else "Select Image",
                if (has_value) "" else " hidden",
            });
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "image",
        .zig_type = ?[]const u8,
        .required = opts.required,
        .translatable = false,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Integer number input
pub fn Integer(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    min: ?i64 = null,
    max: ?i64 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (value.len > 0) {
                const parsed = std.fmt.parseInt(i64, value, 10) catch {
                    return "Must be a valid integer";
                };
                if (opts.min) |min| {
                    if (parsed < min) return "Value is too small";
                }
                if (opts.max) |max| {
                    if (parsed > max) return "Value is too large";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="number" class="form-control" id="{s}" name="{s}" value="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (opts.min) |min| {
                try writer.print(" min=\"{}\"", .{min});
            }
            if (opts.max) |max| {
                try writer.print(" max=\"{}\"", .{max});
            }
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "integer",
        .zig_type = ?i64,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .int,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Floating-point number input
pub fn Number(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (value.len > 0) {
                const parsed = std.fmt.parseFloat(f64, value) catch {
                    return "Must be a valid number";
                };
                if (opts.min) |min| {
                    if (parsed < min) return "Value is too small";
                }
                if (opts.max) |max| {
                    if (parsed > max) return "Value is too large";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="number" class="form-control" id="{s}" name="{s}" value="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (opts.min) |min| {
                try writer.print(" min=\"{d}\"", .{min});
            }
            if (opts.max) |max| {
                try writer.print(" max=\"{d}\"", .{max});
            }
            if (opts.step) |step| {
                try writer.print(" step=\"{d}\"", .{step});
            } else {
                try writer.writeAll(" step=\"any\"");
            }
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "number",
        .zig_type = ?f64,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .real,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Rich text input with editor widget
pub fn RichText(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <textarea class="form-control" id="{s}" name="{s}" rows="12"
                \\            data-widget="richtext"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.print(">{s}</textarea>\n</div>\n", .{ctx.value orelse ""});
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "richtext",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = .data_only,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Email input with basic format validation
pub fn Email(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (value.len > 0) {
                // Basic format: something@something.something
                const at_pos = std.mem.indexOfScalar(u8, value, '@') orelse {
                    return "Invalid email address";
                };
                if (at_pos == 0) return "Invalid email address";
                const domain = value[at_pos + 1 ..];
                if (domain.len == 0) return "Invalid email address";
                if (std.mem.indexOfScalar(u8, domain, '.') == null) {
                    return "Invalid email address";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="email" class="form-control" id="{s}" name="{s}" value="{s}"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "email",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// URL input with basic format validation
pub fn Url(comptime name: []const u8, comptime opts: struct {
    required: bool = false,
    display: ?[]const u8 = null,
    filterable: bool = false,
    position: Position = .main,
}) FieldDef {
    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            if (value.len > 0) {
                // Must start with http:// or https://
                const has_scheme = std.mem.startsWith(u8, value, "http://") or
                    std.mem.startsWith(u8, value, "https://");
                if (!has_scheme) {
                    return "URL must start with http:// or https://";
                }
                // Must have a host after the scheme
                const after_scheme = if (std.mem.startsWith(u8, value, "https://"))
                    value[8..]
                else
                    value[7..];
                if (after_scheme.len == 0) {
                    return "URL must include a host";
                }
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <input type="url" class="form-control" id="{s}" name="{s}" value="{s}"
                \\         placeholder="https://"
            , .{ ctx.name, ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name, ctx.name, ctx.value orelse "" });
            if (ctx.required) {
                try writer.writeAll(" required");
            }
            try writer.writeAll(" />\n</div>\n");
        }
    };

    return .{
        .name = name,
        .display_name = opts.display orelse humanize(name),
        .field_type_id = "url",
        .zig_type = []const u8,
        .required = opts.required,
        .storage = if (opts.filterable) .data_and_meta else .data_only,
        .meta_type = .text,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Taxonomy field - categorical data stored in entry_terms
pub fn Taxonomy(comptime taxonomy_id: []const u8, comptime opts: struct {
    required: bool = false,
    many: bool = true,
    display: ?[]const u8 = null,
    position: Position = .side,
}) FieldDef {
    // Pre-compute humanized name at comptime
    const humanized_taxonomy = comptime humanize(taxonomy_id);

    const S = struct {
        pub fn validate(value: []const u8) ?[]const u8 {
            if (opts.required and value.len == 0) {
                return "This field is required";
            }
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label" for="{s}">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <input type="checkbox" class="field-publish-check" data-field="{s}" checked />
                \\    </div>
                \\  </div>
                \\  <div data-widget="taxonomy-picker" data-taxonomy="{s}" data-many="{s}"
                \\       data-name="{s}" data-value="{s}">
                \\    <input type="hidden" name="{s}" value="{s}" />
                \\    <button type="button" class="btn btn-sm">Select {s}</button>
                \\  </div>
                \\</div>
            , .{
                ctx.name,
                ctx.name,
                ctx.display_name,
                ctx.name,
                ctx.name,
                taxonomy_id,
                if (opts.many) "true" else "false",
                ctx.name,
                ctx.value orelse "",
                ctx.name,
                ctx.value orelse "",
                humanized_taxonomy,
            });
        }
    };

    return .{
        .name = taxonomy_id,
        .display_name = opts.display orelse humanize(taxonomy_id),
        .field_type_id = "taxonomy",
        .zig_type = if (opts.many) []const []const u8 else []const u8,
        .required = opts.required,
        .storage = .taxonomy,
        .taxonomy_id = taxonomy_id,
        .position = opts.position,
        .validate = S.validate,
        .render = S.render,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "humanize converts snake_case to Title Case" {
    // humanize is comptime-only, so we test with comptime
    comptime {
        if (!std.mem.eql(u8, "Featured Image", humanize("featured_image"))) unreachable;
        if (!std.mem.eql(u8, "Title", humanize("title"))) unreachable;
        if (!std.mem.eql(u8, "Published At", humanize("published_at"))) unreachable;
    }
}

test "String field validates max_length" {
    const field = String("title", .{ .max_length = 5 });
    try std.testing.expect(field.validate("hello") == null);
    try std.testing.expect(field.validate("hello!") != null);
}

test "String field validates required" {
    const field = String("title", .{ .required = true });
    try std.testing.expect(field.validate("") != null);
    try std.testing.expect(field.validate("hello") == null);
}

test "Integer field validates range" {
    const field = Integer("count", .{ .min = 0, .max = 100 });
    try std.testing.expect(field.validate("50") == null);
    try std.testing.expect(field.validate("-1") != null);
    try std.testing.expect(field.validate("101") != null);
    try std.testing.expect(field.validate("abc") != null);
}

test "Slug field validates characters" {
    const field = Slug("slug", .{});
    try std.testing.expect(field.validate("hello-world") == null);
    try std.testing.expect(field.validate("hello_world") == null);
    try std.testing.expect(field.validate("hello world") != null);
    try std.testing.expect(field.validate("hello!") != null);
}

test "Select field validates options" {
    const field = Select("status", .{ .options = &.{ "draft", "published" } });
    try std.testing.expect(field.validate("draft") == null);
    try std.testing.expect(field.validate("published") == null);
    try std.testing.expect(field.validate("invalid") != null);
}

test "Boolean field always validates" {
    const field = Boolean("featured", .{});
    try std.testing.expect(field.validate("true") == null);
    try std.testing.expect(field.validate("false") == null);
    try std.testing.expect(field.validate("") == null);
}

test "fields default to translatable = true" {
    const s = String("title", .{});
    try std.testing.expect(s.translatable);

    const t = Text("body", .{});
    try std.testing.expect(t.translatable);

    const sel = Select("status", .{ .options = &.{"draft"} });
    try std.testing.expect(sel.translatable);
}

test "Ref fields are translatable = false" {
    const r = Ref("author", .{ .to = "author" });
    try std.testing.expect(!r.translatable);
}

test "Image fields are translatable = false" {
    const img = Image("avatar", .{});
    try std.testing.expect(!img.translatable);
}

test "RichText field validates required" {
    const rt = RichText("body", .{ .required = true });
    try std.testing.expect(rt.validate("") != null);
    try std.testing.expect(rt.validate("<p>Hello</p>") == null);
    try std.testing.expect(rt.validate("plain text") == null);
    try std.testing.expectEqualStrings("richtext", rt.field_type_id);
}

test "RichText field accepts any content when not required" {
    const rt = RichText("body", .{});
    try std.testing.expect(rt.validate("") == null);
    try std.testing.expect(rt.validate("anything") == null);
}

test "Email field validates format" {
    const e = Email("email", .{});
    try std.testing.expect(e.validate("") == null); // not required
    try std.testing.expect(e.validate("user@example.com") == null);
    try std.testing.expect(e.validate("user@localhost") != null); // no dot in domain
    try std.testing.expect(e.validate("noatsign") != null);
    try std.testing.expect(e.validate("@example.com") != null); // nothing before @
    try std.testing.expect(e.validate("user@") != null); // nothing after @
    try std.testing.expectEqualStrings("email", e.field_type_id);
}

test "Email field validates required" {
    const e = Email("email", .{ .required = true });
    try std.testing.expect(e.validate("") != null);
    try std.testing.expect(e.validate("user@example.com") == null);
}

test "Url field validates format" {
    const u = Url("website", .{});
    try std.testing.expect(u.validate("") == null); // not required
    try std.testing.expect(u.validate("https://example.com") == null);
    try std.testing.expect(u.validate("http://example.com") == null);
    try std.testing.expect(u.validate("https://x") == null); // minimal valid
    try std.testing.expect(u.validate("example.com") != null); // no scheme
    try std.testing.expect(u.validate("ftp://example.com") != null); // wrong scheme
    try std.testing.expect(u.validate("https://") != null); // no host
    try std.testing.expect(u.validate("http://") != null); // no host
    try std.testing.expectEqualStrings("url", u.field_type_id);
}

test "Url field validates required" {
    const u = Url("website", .{ .required = true });
    try std.testing.expect(u.validate("") != null);
    try std.testing.expect(u.validate("https://example.com") == null);
}
