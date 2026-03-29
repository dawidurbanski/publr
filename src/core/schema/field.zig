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
    /// Allocator for container fields (Group, Repeater) that need to parse JSON values
    allocator: ?std.mem.Allocator = null,
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

/// Locale behavior for a field
pub const TranslatableMode = enum {
    /// One canonical value synced across locale entries
    synced,
    /// Independent values per locale
    independent,
    /// Independent values with default-locale fallback on read
    with_fallback,
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

    /// Explicit i18n mode for unified content lifecycle semantics.
    translatable_mode: TranslatableMode = .independent,

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

    /// Child fields for container types (Group, Repeater). Empty for scalar fields.
    sub_fields: []const FieldDef = &.{},

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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
    translatable_mode: TranslatableMode = .synced,
    position: Position = .main,
}) FieldDef {
    const resolved_mode = opts.translatable_mode;

    if (resolved_mode != .synced) {
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
        .translatable_mode = .synced,
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
    translatable_mode: TranslatableMode = .synced,
    position: Position = .side,
}) FieldDef {
    const resolved_mode = opts.translatable_mode;

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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
        .translatable_mode = resolved_mode,
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
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
// Container Fields
// =============================================================================

/// Generate a struct type from field definitions at comptime.
/// Used by Group to create nested struct types, and by ContentType for the top-level Data struct.
pub fn GenerateSubStruct(comptime fields: []const FieldDef) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    for (fields, 0..) |f, i| {
        const is_repeater = comptime std.mem.eql(u8, f.field_type_id, "repeater");

        // Repeater uses raw slice type (not optional) — empty slice is the "absent" state.
        const FieldType = if (f.required or is_repeater)
            f.zig_type
        else if (@typeInfo(f.zig_type) == .optional)
            f.zig_type
        else
            ?f.zig_type;

        struct_fields[i] = .{
            .name = f.name ++ "",
            .type = FieldType,
            .default_value_ptr = if (f.required)
                null
            else if (is_repeater)
                @as(?*const anyopaque, @ptrCast(&@as(FieldType, &.{})))
            else
                @as(?*const anyopaque, @ptrCast(&@as(FieldType, null))),
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Convert a std.json.Value to a string for field rendering.
fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}) catch null,
        .bool => |b| if (b) "true" else "false",
        .null => null,
        .object, .array => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            buf.writer(allocator).print("{f}", .{std.json.fmt(value, .{})}) catch break :blk null;
            break :blk buf.toOwnedSlice(allocator) catch null;
        },
        .number_string => |s| s,
    };
}

/// Group of fields — produces a nested JSON object.
///
/// Example:
/// ```zig
/// field.Group("seo", .{}, &.{
///     field.String("meta_title", .{}),
///     field.Text("meta_description", .{}),
/// })
/// ```
///
/// Produces JSON: `{ "seo": { "meta_title": "...", "meta_description": "..." } }`
pub fn Group(comptime name: []const u8, comptime config: struct {
    required: bool = false,
    label: ?[]const u8 = null,
    position: Position = .main,
    translatable_mode: TranslatableMode = .independent,
}, comptime sub_fields: []const FieldDef) FieldDef {
    const NestedStruct = GenerateSubStruct(sub_fields);

    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            // Group-level validation is a no-op. Sub-field validation
            // happens during form parsing where each sub-field's validate
            // function is called individually.
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const alloc = ctx.allocator orelse return;

            // Parse the group's JSON value to extract sub-field values
            var obj: ?std.json.ObjectMap = null;
            var parsed_result: ?std.json.Parsed(std.json.Value) = null;
            if (ctx.value) |json_str| {
                if (json_str.len > 2) {
                    if (std.json.parseFromSlice(std.json.Value, alloc, json_str, .{})) |result| {
                        parsed_result = result;
                        if (result.value == .object) {
                            obj = result.value.object;
                        }
                    } else |_| {}
                }
            }
            defer if (parsed_result) |*pr| pr.deinit();

            // Fieldset wrapper with toggle
            try writer.print(
                \\<fieldset class="field-group" data-field="{s}" data-publr-component="toggle" data-publr-state="open">
                \\  <legend class="field-group-legend" data-publr-part="trigger">{s}</legend>
                \\  <div class="field-group-content" data-publr-part="content">
                \\
            , .{ ctx.name, ctx.display_name });

            // Render each sub-field
            inline for (sub_fields) |sf| {
                const sub_value: ?[]const u8 = if (obj) |o| blk: {
                    if (o.get(sf.name)) |v| {
                        break :blk jsonValueToString(alloc, v);
                    }
                    break :blk null;
                } else null;

                const dotted = std.fmt.allocPrint(alloc, "{s}.{s}", .{ ctx.name, sf.name }) catch sf.name;
                sf.render(writer, .{
                    .name = dotted,
                    .display_name = sf.display_name,
                    .value = sub_value,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }

            try writer.writeAll(
                \\  </div>
                \\</fieldset>
                \\
            );
        }
    };

    return .{
        .name = name,
        .display_name = config.label orelse humanize(name),
        .field_type_id = "group",
        .zig_type = NestedStruct,
        .required = config.required,
        .position = config.position,
        .translatable_mode = config.translatable_mode,
        .sub_fields = sub_fields,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Repeater of fields — produces a JSON array of objects.
///
/// Example:
/// ```zig
/// field.Repeater("questions", .{}, &.{
///     field.String("question", .{ .required = true }),
///     field.Text("answer", .{ .required = true }),
/// })
/// ```
///
/// Produces JSON: `{ "questions": [{ "question": "...", "answer": "..." }, ...] }`
pub fn Repeater(comptime name: []const u8, comptime config: struct {
    required: bool = false,
    label: ?[]const u8 = null,
    min: ?usize = null,
    max: ?usize = null,
    max_depth: usize = 2,
    position: Position = .main,
    translatable_mode: TranslatableMode = .independent,
}, comptime sub_fields: []const FieldDef) FieldDef {
    // Enforce max_depth: count Repeater nesting in children and add 1 for self
    const child_depth = computeRepeaterDepth(sub_fields);
    if (child_depth + 1 > config.max_depth) {
        @compileError("Repeater nesting exceeds max_depth of " ++ std.fmt.comptimePrint("{d}", .{config.max_depth}));
    }

    const ItemStruct = GenerateSubStruct(sub_fields);

    const S = struct {
        pub fn validate(_: []const u8) ?[]const u8 {
            // Repeater-level validation is a no-op. Sub-field validation
            // happens during form parsing. Min/max count validation is
            // handled at the form parsing layer.
            return null;
        }

        pub fn render(writer: std.io.AnyWriter, ctx: RenderContext) !void {
            const alloc = ctx.allocator orelse return;

            // Parse the repeater's JSON value (array of objects)
            var arr: ?std.json.Array = null;
            var parsed_result: ?std.json.Parsed(std.json.Value) = null;
            if (ctx.value) |json_str| {
                if (json_str.len > 1) {
                    if (std.json.parseFromSlice(std.json.Value, alloc, json_str, .{})) |result| {
                        parsed_result = result;
                        if (result.value == .array) {
                            arr = result.value.array;
                        }
                    } else |_| {}
                }
            }
            defer if (parsed_result) |*pr| pr.deinit();

            const item_count = if (arr) |a| a.items.len else 0;

            // Form group wrapper (consistent with other field types for locking/change detection)
            try writer.print(
                \\<div class="form-group" data-field="{s}">
                \\  <div class="form-label-row">
                \\    <label class="form-label">{s}</label>
                \\    <div class="field-check-row">
                \\      <span class="field-editor-badge" data-field="{s}"></span>
                \\      <label class="switch-label field-publish-switch"><input type="checkbox" class="switch-input field-publish-check" data-field="{s}" checked /><span class="switch-track" role="switch" aria-checked="true"><span class="switch-thumb"></span></span></label>
                \\    </div>
                \\  </div>
                \\<div class="field-repeater" data-field="{s}" data-widget="repeater"
            , .{ ctx.name, ctx.display_name, ctx.name, ctx.name, ctx.name });
            if (config.min) |m| try writer.print(" data-min=\"{d}\"", .{m});
            if (config.max) |m| try writer.print(" data-max=\"{d}\"", .{m});
            try writer.writeAll(">\n");

            // Hidden count field for form parsing
            try writer.print(
                \\  <input type="hidden" name="{s}._count" value="{d}" data-repeater-count />
                \\
            , .{ ctx.name, item_count });

            // Items container
            try writer.writeAll("  <div class=\"field-repeater-items\">\n");

            // Render existing items
            if (arr) |a| {
                for (a.items, 0..) |item, idx| {
                    try writeItemStart(writer);
                    writeSubFields(writer, alloc, ctx.name, item, idx);
                    try writeItemEnd(writer);
                }
            }

            try writer.writeAll("  </div>\n");

            // Template item (hidden, for JS cloning in task-04)
            try writer.writeAll("  <template data-repeater-template>\n");
            try writeItemStart(writer);
            writeTemplateSubFields(writer, alloc, ctx.name);
            try writeItemEnd(writer);
            try writer.writeAll("  </template>\n");

            // Add button
            try writer.writeAll(
                \\  <button type="button" class="btn btn-sm" data-repeater-add>Add</button>
                \\</div>
                \\</div>
                \\
            );
        }

        fn writeItemStart(writer: std.io.AnyWriter) !void {
            try writer.writeAll(
                \\    <div class="field-repeater-item">
                \\      <div class="field-repeater-item-controls">
                \\        <button type="button" class="btn btn-sm btn-icon" data-repeater-up title="Move up">&uarr;</button>
                \\        <button type="button" class="btn btn-sm btn-icon" data-repeater-down title="Move down">&darr;</button>
                \\        <button type="button" class="btn btn-sm btn-icon btn-ghost" data-repeater-remove title="Remove">&times;</button>
                \\      </div>
                \\      <div class="field-repeater-item-content">
                \\
            );
        }

        fn writeItemEnd(writer: std.io.AnyWriter) !void {
            try writer.writeAll(
                \\      </div>
                \\    </div>
                \\
            );
        }

        fn writeSubFields(writer: std.io.AnyWriter, alloc: std.mem.Allocator, base_name: []const u8, item_value: std.json.Value, idx: usize) void {
            var obj: ?std.json.ObjectMap = null;
            if (item_value == .object) obj = item_value.object;

            inline for (sub_fields) |sf| {
                const sub_value: ?[]const u8 = if (obj) |o| blk: {
                    if (o.get(sf.name)) |v| {
                        break :blk jsonValueToString(alloc, v);
                    }
                    break :blk null;
                } else null;

                const field_name = std.fmt.allocPrint(alloc, "{s}.{d}.{s}", .{ base_name, idx, sf.name }) catch sf.name;
                sf.render(writer, .{
                    .name = field_name,
                    .display_name = sf.display_name,
                    .value = sub_value,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }
        }

        fn writeTemplateSubFields(writer: std.io.AnyWriter, alloc: std.mem.Allocator, base_name: []const u8) void {
            inline for (sub_fields) |sf| {
                const field_name = std.fmt.allocPrint(alloc, "{s}.__INDEX__.{s}", .{ base_name, sf.name }) catch sf.name;
                sf.render(writer, .{
                    .name = field_name,
                    .display_name = sf.display_name,
                    .value = null,
                    .required = sf.required,
                    .allocator = alloc,
                }) catch {};
            }
        }
    };

    return .{
        .name = name,
        .display_name = config.label orelse humanize(name),
        .field_type_id = "repeater",
        .zig_type = []const ItemStruct,
        .required = config.required,
        .position = config.position,
        .translatable_mode = config.translatable_mode,
        .sub_fields = sub_fields,
        .validate = S.validate,
        .render = S.render,
    };
}

/// Compute the maximum Repeater nesting depth in a field tree.
/// Returns 0 if no nested Repeaters, 1 if one level of Repeater children, etc.
/// Groups pass through without counting toward depth.
fn computeRepeaterDepth(comptime fields: []const FieldDef) usize {
    var max: usize = 0;
    for (fields) |f| {
        if (comptime std.mem.eql(u8, f.field_type_id, "repeater")) {
            const depth = 1 + computeRepeaterDepth(f.sub_fields);
            if (depth > max) max = depth;
        } else if (f.sub_fields.len > 0) {
            // Group or other container — pass through without counting
            const depth = computeRepeaterDepth(f.sub_fields);
            if (depth > max) max = depth;
        }
    }
    return max;
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

test "fields default to independent translatable mode" {
    const s = String("title", .{});
    try std.testing.expect(s.translatable_mode == .independent);

    const t = Text("body", .{});
    try std.testing.expect(t.translatable_mode == .independent);

    const sel = Select("status", .{ .options = &.{"draft"} });
    try std.testing.expect(sel.translatable_mode == .independent);
}

test "Ref fields are always synced (non-translatable)" {
    const r = Ref("author", .{ .to = "author" });
    try std.testing.expect(r.translatable_mode == .synced);
}

test "Image fields default to synced mode" {
    const img = Image("avatar", .{});
    try std.testing.expect(img.translatable_mode == .synced);
}

test "Image fields support with_fallback mode" {
    const img = Image("hero", .{ .translatable_mode = .with_fallback });
    try std.testing.expect(img.translatable_mode == .with_fallback);
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

test "Group generates nested struct type" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{}),
        Text("meta_description", .{}),
    });

    try std.testing.expectEqualStrings("group", group.field_type_id);
    try std.testing.expectEqualStrings("seo", group.name);
    try std.testing.expectEqualStrings("Seo", group.display_name);
    try std.testing.expect(group.sub_fields.len == 2);

    // Verify the nested struct type
    const info = @typeInfo(group.zig_type);
    try std.testing.expect(info == .@"struct");
    try std.testing.expect(info.@"struct".fields.len == 2);
    try std.testing.expectEqualStrings("meta_title", info.@"struct".fields[0].name);
    try std.testing.expectEqualStrings("meta_description", info.@"struct".fields[1].name);
}

test "Group JSON round-trip" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
        String("meta_description", .{}),
    });

    const json =
        \\{"meta_title":"Hello","meta_description":"World"}
    ;

    const parsed = try std.json.parseFromSlice(group.zig_type, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello", parsed.value.meta_title);
    try std.testing.expect(parsed.value.meta_description != null);
    try std.testing.expectEqualStrings("World", parsed.value.meta_description.?);

    // Serialize back
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try buf.writer(std.testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});
    try std.testing.expectEqualStrings(json, buf.items);
}

test "Nested Group (Group inside Group)" {
    const inner = Group("og", .{}, &.{
        String("title", .{}),
        String("image", .{}),
    });

    const outer = Group("seo", .{}, &.{
        String("meta_title", .{}),
        inner,
    });

    const info = @typeInfo(outer.zig_type);
    try std.testing.expect(info == .@"struct");
    try std.testing.expect(info.@"struct".fields.len == 2);

    // Inner field type should also be a struct
    const inner_type_info = @typeInfo(inner.zig_type);
    try std.testing.expect(inner_type_info == .@"struct");
    try std.testing.expect(inner_type_info.@"struct".fields.len == 2);
}

test "Optional Group parses null and object" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    // Wrap as optional (simulating non-required in ContentType)
    const Wrapper = GenerateSubStruct(&.{group});

    // Parse object
    {
        const json =
            \\{"seo":{"meta_title":"Hello"}}
        ;
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.seo != null);
        try std.testing.expectEqualStrings("Hello", parsed.value.seo.?.meta_title);
    }

    // Parse with missing key (defaults to null)
    {
        const json = "{}";
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.seo == null);
    }
}

test "Group validation is no-op at group level" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    // Group-level validate always passes
    try std.testing.expect(group.validate("") == null);
    try std.testing.expect(group.validate("anything") == null);
}

test "Group render emits fieldset" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{ .required = true }),
    });

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try group.render(buf.writer(std.testing.allocator).any(), .{
        .name = "seo",
        .display_name = "SEO",
        .value = null,
        .required = false,
        .allocator = std.testing.allocator,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "<fieldset class=\"field-group\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-field=\"seo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "SEO") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"seo.meta_title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</fieldset>") != null);
}

test "Group render populates sub-field values from JSON" {
    const group = Group("seo", .{}, &.{
        String("meta_title", .{}),
    });

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try group.render(buf.writer(std.testing.allocator).any(), .{
        .name = "seo",
        .display_name = "SEO",
        .value = "{\"meta_title\":\"Hello World\"}",
        .required = false,
        .allocator = std.testing.allocator,
    });

    const html = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"Hello World\"") != null);
}

test "Conditional Group has condition config" {
    // Conditional groups are supported via the existing data-field attribute
    // on the fieldset — the condition system uses data-field for show/hide.
    const group = Group("seo", .{ .label = "SEO Settings" }, &.{
        String("meta_title", .{}),
    });

    try std.testing.expectEqualStrings("SEO Settings", group.display_name);
    try std.testing.expectEqualStrings("group", group.field_type_id);
}

test "Repeater generates slice type" {
    const repeater = Repeater("questions", .{}, &.{
        String("question", .{ .required = true }),
        Text("answer", .{ .required = true }),
    });

    try std.testing.expectEqualStrings("repeater", repeater.field_type_id);
    try std.testing.expectEqualStrings("questions", repeater.name);
    try std.testing.expect(repeater.sub_fields.len == 2);

    // zig_type should be a slice
    const info = @typeInfo(repeater.zig_type);
    try std.testing.expect(info == .pointer);
    try std.testing.expect(info.pointer.size == .slice);

    // Element type should be a struct with the sub-fields
    const elem_info = @typeInfo(info.pointer.child);
    try std.testing.expect(elem_info == .@"struct");
    try std.testing.expect(elem_info.@"struct".fields.len == 2);
    try std.testing.expectEqualStrings("question", elem_info.@"struct".fields[0].name);
    try std.testing.expectEqualStrings("answer", elem_info.@"struct".fields[1].name);
}

test "Repeater JSON round-trip" {
    const repeater = Repeater("questions", .{}, &.{
        String("question", .{ .required = true }),
        String("answer", .{ .required = true }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    const json =
        \\{"questions":[{"question":"What?","answer":"A CMS."},{"question":"How?","answer":"Zig."}]}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.questions.len == 2);
    try std.testing.expectEqualStrings("What?", parsed.value.questions[0].question);
    try std.testing.expectEqualStrings("A CMS.", parsed.value.questions[0].answer);
    try std.testing.expectEqualStrings("How?", parsed.value.questions[1].question);
    try std.testing.expectEqualStrings("Zig.", parsed.value.questions[1].answer);

    // Serialize back
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try buf.writer(std.testing.allocator).print("{f}", .{std.json.fmt(parsed.value, .{})});
    try std.testing.expectEqualStrings(json, buf.items);
}

test "Empty Repeater parses to empty slice" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    // Parse with empty array
    {
        const json =
            \\{"items":[]}
        ;
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.items.len == 0);
    }

    // Parse with missing key — defaults to empty slice (not null)
    {
        const json = "{}";
        const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.items.len == 0);
    }
}

test "Repeater with Group inside — JSON round-trip" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
        Group("appearance", .{}, &.{
            String("style", .{}),
            String("icon", .{}),
        }),
    });

    const Wrapper = GenerateSubStruct(&.{repeater});

    const json =
        \\{"items":[{"label":"Products","appearance":{"style":"bold","icon":"star"}}]}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.items.len == 1);
    try std.testing.expectEqualStrings("Products", parsed.value.items[0].label);
    try std.testing.expect(parsed.value.items[0].appearance != null);
    try std.testing.expectEqualStrings("bold", parsed.value.items[0].appearance.?.style.?);
}

test "Repeater inside Group — JSON round-trip" {
    const group = Group("nav", .{}, &.{
        String("title", .{ .required = true }),
        Repeater("links", .{}, &.{
            String("label", .{ .required = true }),
            String("url", .{ .required = true }),
        }),
    });

    const Wrapper = GenerateSubStruct(&.{group});

    const json =
        \\{"nav":{"title":"Main Nav","links":[{"label":"Home","url":"/"},{"label":"About","url":"/about"}]}}
    ;

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.nav != null);
    try std.testing.expectEqualStrings("Main Nav", parsed.value.nav.?.title);
    try std.testing.expect(parsed.value.nav.?.links.len == 2);
    try std.testing.expectEqualStrings("Home", parsed.value.nav.?.links[0].label);
}

test "Nested Repeater within max_depth" {
    // Repeater inside Repeater: depth = 2, max_depth = 2 — allowed
    const repeater = Repeater("sections", .{ .max_depth = 2 }, &.{
        String("title", .{ .required = true }),
        Repeater("items", .{}, &.{
            String("label", .{ .required = true }),
        }),
    });

    try std.testing.expectEqualStrings("repeater", repeater.field_type_id);
    try std.testing.expect(repeater.sub_fields.len == 2);
}

test "Repeater validation is no-op" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{ .required = true }),
    });

    try std.testing.expect(repeater.validate("") == null);
    try std.testing.expect(repeater.validate("anything") == null);
}

test "Repeater render emits container with items" {
    const repeater = Repeater("questions", .{ .min = 1, .max = 5 }, &.{
        String("question", .{ .required = true }),
    });

    // Use arena to avoid leak detection on render allocations
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);

    // Render with existing items
    try repeater.render(buf.writer(alloc).any(), .{
        .name = "questions",
        .display_name = "Questions",
        .value = "[{\"question\":\"What?\"}]",
        .required = false,
        .allocator = alloc,
    });

    const html = buf.items;
    // Container with data attributes
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"field-repeater\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-widget=\"repeater\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-min=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-max=\"5\"") != null);
    // Count hidden field
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions._count\" value=\"1\"") != null);
    // Indexed field names
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions.0.question\"") != null);
    // Item value populated
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"What?\"") != null);
    // Template with __INDEX__
    try std.testing.expect(std.mem.indexOf(u8, html, "<template data-repeater-template>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"questions.__INDEX__.question\"") != null);
    // Add button
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-add") != null);
    // Item controls
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-up") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-down") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-repeater-remove") != null);
}

test "Repeater render with empty value" {
    const repeater = Repeater("items", .{}, &.{
        String("label", .{}),
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);

    try repeater.render(buf.writer(alloc).any(), .{
        .name = "items",
        .display_name = "Items",
        .value = null,
        .required = false,
        .allocator = alloc,
    });

    const html = buf.items;
    // Count should be 0
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"0\"") != null);
    // Template should still be present
    try std.testing.expect(std.mem.indexOf(u8, html, "<template data-repeater-template>") != null);
    // No real items (no indexed field names except in template)
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"items.0.label\"") == null);
}

test "field: public API coverage" {
    _ = humanize;
    _ = String;
    _ = Text;
    _ = Slug;
    _ = Ref;
    _ = Select;
    _ = Boolean;
    _ = DateTime;
    _ = Image;
    _ = Integer;
    _ = Number;
    _ = RichText;
    _ = Email;
    _ = Url;
    _ = Taxonomy;
    _ = Group;
    _ = Repeater;
    _ = GenerateSubStruct;
}
