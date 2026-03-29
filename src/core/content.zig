//! CMS Facade
//!
//! Unified entry point for content management. Re-exports query, versioning,
//! and release modules so callers can use a single `cms` import.
//!
//! Example:
//! ```zig
//! const schemas = @import("schemas");
//! const cms = @import("cms");
//!
//! // Get a post by slug
//! const post = try cms.getEntry(schemas.Post, allocator, db, "hello-world");
//!
//! // List published posts
//! const posts = try cms.listEntries(schemas.Post, allocator, db, .{
//!     .status = "published",
//!     .limit = 10,
//! });
//! ```

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");
const core_init = @import("core_init");
const schemas = @import("schemas");

const Allocator = std.mem.Allocator;

// Query API (re-exported)
pub const query = @import("query");
pub const Entry = query.Entry;
pub const MetaOp = query.MetaOp;
pub const MetaValue = query.MetaValue;
pub const MetaFilter = query.MetaFilter;
pub const max_meta_filters = query.max_meta_filters;
pub const OrderDir = query.OrderDir;
pub const ListOptions = query.ListOptions;
pub const getEntry = query.getEntry;
pub const listEntries = query.listEntries;
pub const listWithMeta = query.listWithMeta;
pub const countEntries = query.countEntries;

// Version history management (re-exported)
pub const version = @import("version");
pub const Version = version.Version;
pub const FieldComparison = version.FieldComparison;
pub const listVersions = version.listVersions;
pub const getVersion = version.getVersion;
pub const restoreVersion = version.restoreVersion;
pub const formatRelativeTime = version.formatRelativeTime;
pub const compareVersionFields = version.compareVersionFields;
pub const populateFieldAuthors = version.populateFieldAuthors;
pub const restoreVersionWithData = version.restoreVersionWithData;
pub const diffVersions = version.diffVersions;
pub const jsonValueToString = version.jsonValueToString;
pub const writeEscaped = version.writeEscaped;
pub const pruneVersions = version.pruneVersions;

// Release management (re-exported)
pub const release = @import("release");
pub const ReleaseError = release.ReleaseError;
pub const PendingReleaseOption = release.PendingReleaseOption;
pub const ReleaseListItem = release.ReleaseListItem;
pub const ReleaseDetailItem = release.ReleaseDetailItem;
pub const ReleaseDetail = release.ReleaseDetail;
pub const EntryReleaseFieldInfo = release.EntryReleaseFieldInfo;
pub const getEntryVersionId = release.getEntryVersionId;
pub const getPublishedData = release.getPublishedData;
pub const discardToPublished = release.discardToPublished;
pub const mergeJsonFields = release.mergeJsonFields;
pub const publishEntry = release.publishEntry;
pub const revertRelease = release.revertRelease;
pub const reReleaseReverted = release.reReleaseReverted;
pub const scheduleRelease = release.scheduleRelease;
pub const generateReleaseId = release.generateReleaseId;
pub const createPendingRelease = release.createPendingRelease;
pub const addToRelease = release.addToRelease;
pub const removeFromRelease = release.removeFromRelease;
pub const archiveRelease = release.archiveRelease;
pub const publishBatchRelease = release.publishBatchRelease;
pub const publishBatchReleaseWithSkips = release.publishBatchReleaseWithSkips;
pub const ReleaseFieldConflict = release.ReleaseFieldConflict;
pub const detectReleaseConflicts = release.detectReleaseConflicts;
pub const listReleases = release.listReleases;
pub const getRelease = release.getRelease;
pub const listPendingReleases = release.listPendingReleases;
pub const getEntryPendingReleaseIds = release.getEntryPendingReleaseIds;
pub const getEntryPendingReleaseFields = release.getEntryPendingReleaseFields;

pub const EntryLifecycleError = error{
    EntryNotFound,
    EntryNotPublished,
};

/// Entry status values
pub const Status = enum {
    draft,
    published,
    changed,
    archived,

    pub fn toString(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |f| {
            if (std.mem.eql(u8, s, f.name)) {
                return @enumFromInt(f.value);
            }
        }
        return null;
    }
};

/// Generate a unique entry ID
pub const generateId = id_gen.generateEntryId;

/// Options for saving an entry
pub const SaveOptions = struct {
    /// Author user ID for version tracking (null for system/anonymous saves)
    author_id: ?[]const u8 = null,
    /// When true, update existing version in-place instead of creating a new one.
    /// Used by autosave to avoid polluting version history.
    autosave: bool = false,
    /// Entry status override. Takes precedence over data.status if set.
    /// Status is an intrinsic entry attribute (draft/published/changed),
    /// not a schema field.
    status: ?[]const u8 = null,
    /// Optional locale for localized content writes. Defaults to content type default locale.
    locale: ?[]const u8 = null,
};

/// Save an entry (create or update), creating a version in the history
pub fn saveEntry(
    comptime CT: type,
    allocator: Allocator,
    db: *Db,
    id: ?[]const u8,
    data: anytype,
    opts: SaveOptions,
) !Entry(CT) {
    const entry_id = id orelse try generateId(allocator);
    const typed_data: CT.Data = data;

    // Extract title from data if present
    const title: []const u8 = if (@hasField(@TypeOf(typed_data), "title")) blk: {
        const title_val = typed_data.title;
        if (@typeInfo(@TypeOf(title_val)) == .optional) {
            break :blk title_val orelse "";
        } else {
            break :blk title_val;
        }
    } else "";

    // Extract slug from data if present (coerce to optional, empty string -> null)
    const slug: ?[]const u8 = if (@hasField(@TypeOf(typed_data), "slug")) blk: {
        const s = @as(?[]const u8, typed_data.slug);
        break :blk if (s) |sv| if (sv.len == 0) @as(?[]const u8, null) else sv else null;
    } else null;

    // Extract status: opts.status takes precedence, then data.status, then "draft"
    const status: []const u8 = if (opts.status) |s| s else if (@hasField(@TypeOf(typed_data), "status")) blk: {
        const status_val = typed_data.status;
        if (@typeInfo(@TypeOf(status_val)) == .optional) {
            break :blk status_val orelse "draft";
        } else {
            break :blk status_val;
        }
    } else "draft";

    // Serialize data to JSON
    const data_json = try CT.stringifyData(allocator, typed_data);
    defer allocator.free(data_json);

    const locales = comptime localesFor(CT);
    const default_locale = comptime defaultLocaleFor(CT);
    var resolved_locale = default_locale;
    if (opts.locale) |requested| {
        for (locales) |loc| {
            if (std.mem.eql(u8, loc, requested)) {
                resolved_locale = requested;
                break;
            }
        }
    }

    const target_entry_id = try makeLocaleEntryId(allocator, entry_id, resolved_locale, default_locale);
    defer allocator.free(target_entry_id);

    // Get previous version id, data, author (for change detection + author tracking)
    var has_existing_entry = false;
    var prev_version_id: ?[]const u8 = null;
    var prev_data: ?[]const u8 = null;
    var published_vid: ?[]const u8 = null;
    var prev_author_id: ?[]const u8 = null;
    var prev_version_type: ?[]const u8 = null;
    {
        var pv_stmt = try db.prepare(
            \\SELECT ce.current_version_id, cv.data_json, ce.published_version_id, cv.author_id, cv.version_type
            \\FROM content_entries ce
            \\LEFT JOIN content_versions cv ON cv.id = ce.current_version_id
            \\WHERE ce.id = ?1
        );
        defer pv_stmt.deinit();
        try pv_stmt.bindText(1, target_entry_id);
        if (try pv_stmt.step()) {
            has_existing_entry = true;
            if (pv_stmt.columnText(0)) |v| prev_version_id = try allocator.dupe(u8, v);
            if (pv_stmt.columnText(1)) |d| prev_data = try allocator.dupe(u8, d);
            if (pv_stmt.columnText(2)) |v| published_vid = try allocator.dupe(u8, v);
            if (pv_stmt.columnText(3)) |v| prev_author_id = try allocator.dupe(u8, v);
            if (pv_stmt.columnText(4)) |v| prev_version_type = try allocator.dupe(u8, v);
        }
    }
    defer if (prev_version_id) |v| allocator.free(v);
    defer if (prev_data) |d| allocator.free(d);
    defer if (published_vid) |v| allocator.free(v);
    defer if (prev_author_id) |v| allocator.free(v);
    defer if (prev_version_type) |v| allocator.free(v);
    const is_update = has_existing_entry;

    // Skip version creation if data hasn't changed
    const data_changed = if (prev_data) |pd| !std.mem.eql(u8, pd, data_json) else true;

    // Autosave must create a new version (not update in-place) when current == published,
    // otherwise the published version's data would be corrupted.
    const is_published_version = if (prev_version_id) |pv|
        if (published_vid) |pub_v| std.mem.eql(u8, pv, pub_v) else false
    else
        false;

    const version_id = id_gen.generateVersionId();

    // Autosave can update in-place ONLY when:
    // 1. Current version != published version (preserve published snapshot)
    // 2. Same author is editing (different author = new version for attribution)
    const same_author = if (prev_author_id) |pa|
        if (opts.author_id) |oa| std.mem.eql(u8, pa, oa) else true
    else
        true;
    const prev_is_autosave = if (prev_version_type) |vt| std.mem.eql(u8, vt, "autosave") else false;
    const can_autosave_inplace = opts.autosave and !is_published_version and same_author and prev_is_autosave;
    const promote_autosave_on_save = !opts.autosave and is_update and prev_is_autosave;
    const version_created = (!is_update) or promote_autosave_on_save or (data_changed and !can_autosave_inplace);
    const current_version_id: []const u8 = if (version_created)
        &version_id
    else if (prev_version_id) |pv|
        pv
    else
        &version_id;

    try syncUnifiedLifecycle(CT, allocator, db, .{
        .entry_id = entry_id,
        .target_entry_id = target_entry_id,
        .title = title,
        .slug = slug,
        .current_version_id = current_version_id,
        .prev_version_id = prev_version_id,
        .version_type = if (!is_update) "created" else if (opts.autosave) "autosave" else "updated",
        .data_json = data_json,
        .prev_data_json = prev_data,
        .status = status,
        .is_update = is_update,
        .data_changed = data_changed,
        .version_created = version_created,
        .can_autosave_inplace = can_autosave_inplace,
        .author_id = opts.author_id,
        .requested_locale = opts.locale,
    });

    // Enforce version retention limit.
    try pruneVersions(db, target_entry_id);

    // Sync filterable fields to unified content_meta.
    try syncEntryMeta(CT, db, target_entry_id, current_version_id, typed_data);

    // Sync taxonomy relationships to unified content_term_assignments.
    try syncEntryTerms(CT, db, target_entry_id, typed_data);

    if (@hasDecl(CT, "hooks")) {
        if (CT.hooks.on_save) |hook| {
            try hook(allocator, .{
                .entry_id = entry_id,
                .content_type = CT.type_id,
                .locale = resolved_locale,
                .status = status,
                .author_id = opts.author_id,
            }, data_json);
        }
        if (std.mem.eql(u8, status, "published")) {
            if (CT.hooks.on_publish) |hook| {
                try hook(allocator, .{
                    .entry_id = entry_id,
                    .content_type = CT.type_id,
                    .locale = resolved_locale,
                    .status = status,
                    .author_id = opts.author_id,
                }, data_json);
            }
        } else if (std.mem.eql(u8, status, "archived")) {
            if (CT.hooks.on_archive) |hook| {
                try hook(allocator, .{
                    .entry_id = entry_id,
                    .content_type = CT.type_id,
                    .locale = resolved_locale,
                    .status = status,
                    .author_id = opts.author_id,
                }, data_json);
            }
        }
    }

    // Return the saved entry
    return try getEntry(CT, allocator, db, entry_id) orelse error.EntryNotFound;
}

/// Sync filterable fields to unified content_meta table.
fn syncEntryMeta(comptime CT: type, db: *Db, entry_id: []const u8, version_id: []const u8, data: anytype) !void {
    var del_stmt = try db.prepare("DELETE FROM content_meta WHERE entry_id = ?1 AND version_id = ?2");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    try del_stmt.bindText(2, version_id);
    _ = try del_stmt.step();

    const filterable = CT.getFilterableFields();
    if (filterable.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO content_meta (entry_id, version_id, field_name, value)
        \\VALUES (?1, ?2, ?3, ?4)
    );
    defer stmt.deinit();

    inline for (filterable) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);

            try stmt.bindText(1, entry_id);
            try stmt.bindText(2, version_id);
            try stmt.bindText(3, f.name);

            switch (f.meta_type) {
                .text => {
                    if (value) |v| {
                        try stmt.bindText(4, v);
                    } else {
                        try stmt.bindNull(4);
                    }
                },
                .int => {
                    if (value) |v| {
                        const buf = try std.fmt.allocPrint(db.allocator, "{d}", .{v});
                        defer db.allocator.free(buf);
                        try stmt.bindText(4, buf);
                    } else {
                        try stmt.bindNull(4);
                    }
                },
                .real => {
                    if (value) |v| {
                        const buf = try std.fmt.allocPrint(db.allocator, "{d}", .{v});
                        defer db.allocator.free(buf);
                        try stmt.bindText(4, buf);
                    } else {
                        try stmt.bindNull(4);
                    }
                },
            }

            _ = try stmt.step();
            stmt.reset();
        }
    }
}

/// Sync taxonomy fields to unified content_term_assignments table.
fn syncEntryTerms(comptime CT: type, db: *Db, entry_id: []const u8, data: anytype) !void {
    var del_stmt = try db.prepare("DELETE FROM content_term_assignments WHERE entry_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, entry_id);
    _ = try del_stmt.step();

    const taxonomies = CT.getTaxonomyFields();
    if (taxonomies.len == 0) return;

    var stmt = try db.prepare(
        \\INSERT INTO content_term_assignments (entry_id, taxonomy_id, field_name, term_anchor_id, sort_order)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.deinit();

    inline for (taxonomies) |f| {
        if (@hasField(@TypeOf(data), f.name)) {
            const value = @field(data, f.name);
            const ValueType = @TypeOf(value);

            if (ValueType == []const []const u8) {
                for (value, 0..) |term_id, idx| {
                    const taxonomy_id = f.taxonomy_id orelse continue;
                    try stmt.bindText(1, entry_id);
                    try stmt.bindText(2, taxonomy_id);
                    try stmt.bindText(3, f.name);
                    try stmt.bindText(4, term_id);
                    try stmt.bindInt(5, @intCast(idx));
                    _ = try stmt.step();
                    stmt.reset();
                }
            } else if (@typeInfo(ValueType) == .optional) {
                const ChildType = @typeInfo(ValueType).optional.child;
                if (value) |unwrapped| {
                    const taxonomy_id = f.taxonomy_id orelse continue;
                    if (ChildType == []const []const u8) {
                        for (unwrapped, 0..) |term_id, idx| {
                            try stmt.bindText(1, entry_id);
                            try stmt.bindText(2, taxonomy_id);
                            try stmt.bindText(3, f.name);
                            try stmt.bindText(4, term_id);
                            try stmt.bindInt(5, @intCast(idx));
                            _ = try stmt.step();
                            stmt.reset();
                        }
                    } else {
                        try stmt.bindText(1, entry_id);
                        try stmt.bindText(2, taxonomy_id);
                        try stmt.bindText(3, f.name);
                        try stmt.bindText(4, unwrapped);
                        try stmt.bindInt(5, 0);
                        _ = try stmt.step();
                        stmt.reset();
                    }
                }
            } else if (ValueType == []const u8) {
                const taxonomy_id = f.taxonomy_id orelse continue;
                try stmt.bindText(1, entry_id);
                try stmt.bindText(2, taxonomy_id);
                try stmt.bindText(3, f.name);
                try stmt.bindText(4, value);
                try stmt.bindInt(5, 0);
                _ = try stmt.step();
                stmt.reset();
            }
        }
    }
}

const UnifiedSyncOpts = struct {
    entry_id: []const u8,
    target_entry_id: []const u8,
    title: []const u8,
    slug: ?[]const u8,
    current_version_id: []const u8,
    prev_version_id: ?[]const u8,
    version_type: []const u8,
    data_json: []const u8,
    prev_data_json: ?[]const u8,
    status: []const u8,
    is_update: bool,
    data_changed: bool,
    version_created: bool,
    can_autosave_inplace: bool,
    author_id: ?[]const u8,
    requested_locale: ?[]const u8,
};

fn defaultLocaleFor(comptime CT: type) []const u8 {
    if (@hasDecl(CT, "available_locales") and CT.available_locales.len > 0) {
        return CT.available_locales[0];
    }
    return "en";
}

fn localesFor(comptime CT: type) []const []const u8 {
    if (@hasDecl(CT, "available_locales") and CT.available_locales.len > 0) {
        return CT.available_locales;
    }
    return &.{"en"};
}

fn lifecycleTablesAvailable(db: *Db) !bool {
    var stmt = try db.prepare(
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'table'
        \\  AND name IN ('content_anchors', 'content_entries', 'content_versions', 'entry_flow_state', 'entry_flow_history')
    );
    defer stmt.deinit();
    if (!try stmt.step()) return false;
    return stmt.columnInt(0) == 5;
}

fn makeLocaleEntryId(allocator: Allocator, anchor_id: []const u8, locale: []const u8, default_locale: []const u8) ![]u8 {
    if (std.mem.eql(u8, locale, default_locale)) {
        return try allocator.dupe(u8, anchor_id);
    }
    return try std.fmt.allocPrint(allocator, "{s}::{s}", .{ anchor_id, locale });
}

fn appendFlowHistory(
    db: *Db,
    anchor_id: []const u8,
    version_id: ?[]const u8,
    action: []const u8,
    user_id: ?[]const u8,
    from_step: ?i64,
    to_step: ?i64,
    details: ?[]const u8,
) !void {
    const history_id = id_gen.generatePrefixedId("fh_", 16);
    var stmt = try db.prepare(
        \\INSERT INTO entry_flow_history (id, anchor_id, version_id, action, user_id, from_step, to_step, details, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, &history_id);
    try stmt.bindText(2, anchor_id);
    if (version_id) |vid| try stmt.bindText(3, vid) else try stmt.bindNull(3);
    try stmt.bindText(4, action);
    if (user_id) |uid| try stmt.bindText(5, uid) else try stmt.bindNull(5);
    if (from_step) |s| try stmt.bindInt(6, s) else try stmt.bindNull(6);
    if (to_step) |s| try stmt.bindInt(7, s) else try stmt.bindNull(7);
    if (details) |d| try stmt.bindText(8, d) else try stmt.bindNull(8);
    _ = try stmt.step();
}

fn ensureFlowState(db: *Db, anchor_id: []const u8, flow_id: []const u8, author_id: ?[]const u8, version_id: []const u8) !void {
    var active_flow_id: []const u8 = flow_id;
    var current_step: i64 = 0;
    var state_exists = false;
    {
        var exists_stmt = try db.prepare("SELECT flow_id, current_step FROM entry_flow_state WHERE anchor_id = ?1");
        defer exists_stmt.deinit();
        try exists_stmt.bindText(1, anchor_id);
        if (try exists_stmt.step()) {
            state_exists = true;
            active_flow_id = exists_stmt.columnText(0) orelse flow_id;
            current_step = exists_stmt.columnInt(1);
        }
    }

    if (!state_exists) {
        var stmt = try db.prepare(
            \\INSERT OR IGNORE INTO entry_flow_state (anchor_id, flow_id, current_step, started_at, started_by)
            \\VALUES (?1, ?2, 0, unixepoch(), ?3)
        );
        defer stmt.deinit();
        try stmt.bindText(1, anchor_id);
        try stmt.bindText(2, flow_id);
        if (author_id) |aid| try stmt.bindText(3, aid) else try stmt.bindNull(3);
        _ = try stmt.step();
    }

    const details = try std.fmt.allocPrint(db.allocator, "{{\"flow_id\":\"{s}\"}}", .{active_flow_id});
    defer db.allocator.free(details);
    try appendFlowHistory(db, anchor_id, version_id, "flow_entered", author_id, null, current_step, details);
    try appendFlowHistory(db, anchor_id, version_id, "step_started", author_id, current_step, current_step, null);
}

fn completeFlowStateIfExists(db: *Db, anchor_id: []const u8, author_id: ?[]const u8, terminal_action: []const u8, version_id: []const u8) !void {
    var flow_stmt = try db.prepare("SELECT flow_id, current_step FROM entry_flow_state WHERE anchor_id = ?1");
    defer flow_stmt.deinit();
    try flow_stmt.bindText(1, anchor_id);
    var flow_id: []const u8 = "default_publish";
    var current_step: i64 = 0;
    const had_state = try flow_stmt.step();
    if (had_state) {
        flow_id = flow_stmt.columnText(0) orelse "default_publish";
        current_step = flow_stmt.columnInt(1);
    }

    const details = try std.fmt.allocPrint(db.allocator, "{{\"flow_id\":\"{s}\",\"terminal_action\":\"{s}\"}}", .{ flow_id, terminal_action });
    defer db.allocator.free(details);
    try appendFlowHistory(db, anchor_id, version_id, "flow_entered", author_id, null, current_step, details);
    try appendFlowHistory(db, anchor_id, version_id, "step_started", author_id, current_step, current_step, null);
    try appendFlowHistory(db, anchor_id, version_id, "step_completed", author_id, current_step, current_step, null);
    try appendFlowHistory(db, anchor_id, version_id, "terminal_action", author_id, current_step, null, details);
    try appendFlowHistory(db, anchor_id, version_id, "flow_completed", author_id, current_step, null, details);

    if (had_state) {
        var del_claims = try db.prepare("DELETE FROM entry_flow_claims WHERE anchor_id = ?1");
        defer del_claims.deinit();
        try del_claims.bindText(1, anchor_id);
        _ = try del_claims.step();

        var del_flow = try db.prepare("DELETE FROM entry_flow_state WHERE anchor_id = ?1");
        defer del_flow.deinit();
        try del_flow.bindText(1, anchor_id);
        _ = try del_flow.step();
    }
}

fn jsonOptionalEqual(allocator: Allocator, lhs: ?std.json.Value, rhs: ?std.json.Value) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;

    const l = std.json.Stringify.valueAlloc(allocator, lhs.?, .{}) catch return false;
    defer allocator.free(l);
    const r = std.json.Stringify.valueAlloc(allocator, rhs.?, .{}) catch return false;
    defer allocator.free(r);
    return std.mem.eql(u8, l, r);
}

fn collectChangedSyncedFields(comptime CT: type, allocator: Allocator, old_json: []const u8, new_json: []const u8) ![][]const u8 {
    const synced = CT.getSyncedFields();
    if (synced.len == 0) return allocator.alloc([]const u8, 0);

    var old_parsed_opt = std.json.parseFromSlice(std.json.Value, allocator, old_json, .{}) catch null;
    defer if (old_parsed_opt) |*p| p.deinit();
    var new_parsed_opt = std.json.parseFromSlice(std.json.Value, allocator, new_json, .{}) catch null;
    defer if (new_parsed_opt) |*p| p.deinit();

    const old_obj = if (old_parsed_opt) |p|
        if (p.value == .object) p.value.object else null
    else
        null;
    const new_obj = if (new_parsed_opt) |p|
        if (p.value == .object) p.value.object else null
    else
        null;

    var changed: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer changed.deinit(allocator);

    inline for (synced) |f| {
        const old_val = if (old_obj) |obj| obj.get(f.name) else null;
        const new_val = if (new_obj) |obj| obj.get(f.name) else null;
        if (!jsonOptionalEqual(allocator, old_val, new_val)) {
            try changed.append(allocator, try allocator.dupe(u8, f.name));
        }
    }

    return changed.toOwnedSlice(allocator);
}

fn syncUnifiedLifecycle(comptime CT: type, allocator: Allocator, db: *Db, opts: UnifiedSyncOpts) !void {
    if (!try lifecycleTablesAvailable(db)) return;

    const locales = comptime localesFor(CT);
    const default_locale = comptime defaultLocaleFor(CT);

    var resolved_locale = default_locale;
    if (opts.requested_locale) |requested| {
        for (locales) |loc| {
            if (std.mem.eql(u8, loc, requested)) {
                resolved_locale = requested;
                break;
            }
        }
    }

    {
        var stmt = try db.prepare(
            \\INSERT OR IGNORE INTO content_anchors (id, content_type, created_at, created_by)
            \\VALUES (?1, ?2, unixepoch(), ?3)
        );
        defer stmt.deinit();
        try stmt.bindText(1, opts.entry_id);
        try stmt.bindText(2, CT.type_id);
        if (opts.author_id) |aid| try stmt.bindText(3, aid) else try stmt.bindNull(3);
        _ = try stmt.step();
    }

    for (locales) |locale| {
        const locale_entry_id = try makeLocaleEntryId(allocator, opts.entry_id, locale, default_locale);
        defer allocator.free(locale_entry_id);

        var stmt = try db.prepare(
            \\INSERT OR IGNORE INTO content_entries (id, anchor_id, locale, content_type_id, data, status, archived, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, '{}', 'draft', 0, unixepoch(), unixepoch())
        );
        defer stmt.deinit();
        try stmt.bindText(1, locale_entry_id);
        try stmt.bindText(2, opts.entry_id);
        try stmt.bindText(3, locale);
        try stmt.bindText(4, CT.type_id);
        _ = try stmt.step();
    }

    if (opts.version_created) {
        var stmt = try db.prepare(
            \\INSERT OR REPLACE INTO content_versions (id, entry_id, parent_id, data_json, author_id, created_at, version_type)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch(), ?6)
        );
        defer stmt.deinit();
        try stmt.bindText(1, opts.current_version_id);
        try stmt.bindText(2, opts.target_entry_id);
        if (opts.prev_version_id) |pv| try stmt.bindText(3, pv) else try stmt.bindNull(3);
        try stmt.bindText(4, opts.data_json);
        if (opts.author_id) |aid| try stmt.bindText(5, aid) else try stmt.bindNull(5);
        try stmt.bindText(6, opts.version_type);
        _ = try stmt.step();
    } else {
        var exists_stmt = try db.prepare("SELECT 1 FROM content_versions WHERE id = ?1");
        defer exists_stmt.deinit();
        try exists_stmt.bindText(1, opts.current_version_id);
        const exists = try exists_stmt.step();

        if (!exists) {
            var insert_stmt = try db.prepare(
                \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, created_at, version_type)
                \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch(), ?6)
            );
            defer insert_stmt.deinit();
            try insert_stmt.bindText(1, opts.current_version_id);
            try insert_stmt.bindText(2, opts.target_entry_id);
            if (opts.prev_version_id) |pv| try insert_stmt.bindText(3, pv) else try insert_stmt.bindNull(3);
            try insert_stmt.bindText(4, opts.data_json);
            if (opts.author_id) |aid| try insert_stmt.bindText(5, aid) else try insert_stmt.bindNull(5);
            try insert_stmt.bindText(6, opts.version_type);
            _ = try insert_stmt.step();
        } else if (opts.data_changed and opts.can_autosave_inplace) {
            var update_stmt = try db.prepare("UPDATE content_versions SET data_json = ?1 WHERE id = ?2");
            defer update_stmt.deinit();
            try update_stmt.bindText(1, opts.data_json);
            try update_stmt.bindText(2, opts.current_version_id);
            _ = try update_stmt.step();
        }
    }

    {
        var stmt = try db.prepare(
            \\UPDATE content_entries
            \\SET content_type_id = ?2,
            \\    slug = ?3,
            \\    title = ?4,
            \\    data = ?5,
            \\    status = ?6,
            \\    current_version_id = ?7,
            \\    archived = ?8,
            \\    updated_at = unixepoch()
            \\WHERE id = ?1
        );
        defer stmt.deinit();
        try stmt.bindText(1, opts.target_entry_id);
        try stmt.bindText(2, CT.type_id);
        if (opts.slug) |s| try stmt.bindText(3, s) else try stmt.bindNull(3);
        try stmt.bindText(4, opts.title);
        try stmt.bindText(5, opts.data_json);
        try stmt.bindText(6, opts.status);
        try stmt.bindText(7, opts.current_version_id);
        try stmt.bindInt(8, if (std.mem.eql(u8, opts.status, "archived")) 1 else 0);
        _ = try stmt.step();
    }

    if (std.mem.eql(u8, opts.status, "published")) {
        var stmt = try db.prepare(
            "UPDATE content_entries SET published_version_id = ?1, published_at = unixepoch() WHERE id = ?2",
        );
        defer stmt.deinit();
        try stmt.bindText(1, opts.current_version_id);
        try stmt.bindText(2, opts.target_entry_id);
        _ = try stmt.step();
    }

    if (opts.data_changed and std.mem.eql(u8, resolved_locale, default_locale)) {
        const changed_synced = try collectChangedSyncedFields(CT, allocator, opts.prev_data_json orelse "{}", opts.data_json);
        defer {
            for (changed_synced) |field_name| allocator.free(field_name);
            allocator.free(changed_synced);
        }

        if (changed_synced.len > 0 and locales.len > 1) {
            for (locales) |locale| {
                if (std.mem.eql(u8, locale, default_locale)) continue;

                const locale_entry_id = try makeLocaleEntryId(allocator, opts.entry_id, locale, default_locale);
                defer allocator.free(locale_entry_id);

                var get_stmt = try db.prepare(
                    \\SELECT ce.current_version_id, cv.data_json
                    \\FROM content_entries ce
                    \\LEFT JOIN content_versions cv ON cv.id = ce.current_version_id
                    \\WHERE ce.id = ?1
                );
                defer get_stmt.deinit();
                try get_stmt.bindText(1, locale_entry_id);
                const existing_parent = if (try get_stmt.step()) get_stmt.columnText(0) else null;
                const existing_json = if (get_stmt.columnText(1)) |j| j else "{}";

                const merged = try mergeJsonFields(allocator, existing_json, opts.data_json, changed_synced);
                defer allocator.free(merged);

                const sync_version_id = id_gen.generateVersionId();
                {
                    var v_stmt = try db.prepare(
                        \\INSERT INTO content_versions (id, entry_id, parent_id, data_json, author_id, created_at, version_type)
                        \\VALUES (?1, ?2, ?3, ?4, NULL, unixepoch(), 'synced')
                    );
                    defer v_stmt.deinit();
                    try v_stmt.bindText(1, &sync_version_id);
                    try v_stmt.bindText(2, locale_entry_id);
                    if (existing_parent) |p| try v_stmt.bindText(3, p) else try v_stmt.bindNull(3);
                    try v_stmt.bindText(4, merged);
                    _ = try v_stmt.step();
                }

                {
                    var u_stmt = try db.prepare(
                        "UPDATE content_entries SET current_version_id = ?1, data = ?2, updated_at = unixepoch() WHERE id = ?3",
                    );
                    defer u_stmt.deinit();
                    try u_stmt.bindText(1, &sync_version_id);
                    try u_stmt.bindText(2, merged);
                    try u_stmt.bindText(3, locale_entry_id);
                    _ = try u_stmt.step();
                }
            }
        }
    }

    if (!std.mem.eql(u8, opts.status, "published") and !std.mem.eql(u8, opts.status, "archived")) {
        try ensureFlowState(db, opts.entry_id, CT.workflow orelse "default_publish", opts.author_id, opts.current_version_id);
    } else {
        try completeFlowStateIfExists(db, opts.entry_id, opts.author_id, if (std.mem.eql(u8, opts.status, "archived")) "archive" else "publish", opts.current_version_id);
    }
}

/// Delete an entry
pub fn deleteEntry(db: *Db, entry_id: []const u8) !void {
    // Unified lifecycle source of truth (cascades to locale entries, versions, flow state, release_entries).
    {
        var u_stmt = try db.prepare("DELETE FROM content_anchors WHERE id = ?1");
        defer u_stmt.deinit();
        try u_stmt.bindText(1, entry_id);
        _ = try u_stmt.step();
    }
}

/// Archive an entry by setting status and archived flag.
pub fn archiveEntry(db: *Db, entry_id: []const u8) (Db.Error || EntryLifecycleError)!void {
    var check_stmt = try db.prepare("SELECT archived FROM content_entries WHERE id = ?1");
    defer check_stmt.deinit();
    try check_stmt.bindText(1, entry_id);
    if (!try check_stmt.step()) return EntryLifecycleError.EntryNotFound;
    if (check_stmt.columnInt(0) != 0) return;

    var stmt = try db.prepare(
        \\UPDATE content_entries
        \\SET archived = 1, status = 'archived', updated_at = unixepoch()
        \\WHERE id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

/// Unpublish an entry by clearing published_version_id and resetting draft status.
pub fn unpublishEntry(db: *Db, entry_id: []const u8) (Db.Error || EntryLifecycleError)!void {
    var check_stmt = try db.prepare(
        "SELECT published_version_id FROM content_entries WHERE id = ?1",
    );
    defer check_stmt.deinit();
    try check_stmt.bindText(1, entry_id);
    if (!try check_stmt.step()) return EntryLifecycleError.EntryNotFound;
    if (check_stmt.columnText(0) == null) return EntryLifecycleError.EntryNotPublished;

    var stmt = try db.prepare(
        \\UPDATE content_entries
        \\SET published_version_id = NULL,
        \\    archived = 0,
        \\    status = 'draft',
        \\    updated_at = unixepoch()
        \\WHERE id = ?1
    );
    defer stmt.deinit();
    try stmt.bindText(1, entry_id);
    _ = try stmt.step();
}

// =============================================================================
// Tests
// =============================================================================

test "generateId produces valid entry IDs" {
    const id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "e_"));
    try std.testing.expect(id.len >= 10);
}

test "Status enum conversions" {
    try std.testing.expectEqualStrings("draft", Status.draft.toString());
    try std.testing.expectEqualStrings("published", Status.published.toString());

    try std.testing.expect(Status.fromString("draft") == .draft);
    try std.testing.expect(Status.fromString("published") == .published);
    try std.testing.expect(Status.fromString("invalid") == null);
}

test "generateVersionId produces valid IDs" {
    const id = id_gen.generateVersionId();
    try std.testing.expect(id[0] == 'v');
    try std.testing.expect(id[1] == '_');
    try std.testing.expectEqual(@as(usize, 18), id.len);
}

test "archiveEntry sets archived flag" {
    var db = try core_init.initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    const entry = try saveEntry(schemas.Post, std.testing.allocator, &db, null, schemas.Post.Data{
        .title = "Archive Me",
        .slug = "archive-me",
        .body = "Body",
    }, .{});

    try archiveEntry(&db, entry.id);
    try archiveEntry(&db, entry.id); // idempotent

    var stmt = try db.prepare("SELECT archived, status FROM content_entries WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry.id);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try std.testing.expectEqualStrings("archived", stmt.columnText(1).?);
}

test "archiveEntry on nonexistent entry returns error" {
    var db = try core_init.initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    try std.testing.expectError(EntryLifecycleError.EntryNotFound, archiveEntry(&db, "e_missing"));
}

test "unpublishEntry clears published version and resets draft status" {
    var db = try core_init.initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    const entry = try saveEntry(schemas.Post, std.testing.allocator, &db, null, schemas.Post.Data{
        .title = "Publish Me",
        .slug = "publish-me",
        .body = "Body",
    }, .{
        .status = "published",
    });

    try std.testing.expectError(EntryLifecycleError.EntryNotPublished, unpublishEntry(&db, "e_missing_draft"));
    try unpublishEntry(&db, entry.id);

    var stmt = try db.prepare("SELECT published_version_id, status, archived FROM content_entries WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, entry.id);
    try std.testing.expect(try stmt.step());
    try std.testing.expect(stmt.columnText(0) == null);
    try std.testing.expectEqualStrings("draft", stmt.columnText(1).?);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(2));
}

test "unpublishEntry on draft entry returns error" {
    var db = try core_init.initDatabase(std.testing.allocator, ":memory:");
    defer db.deinit();
    try core_init.ensureSchema(&db);
    try core_init.seed(&db);

    const entry = try saveEntry(schemas.Post, std.testing.allocator, &db, null, schemas.Post.Data{
        .title = "Draft",
        .slug = "draft",
        .body = "Body",
    }, .{
        .status = "draft",
    });

    try std.testing.expectError(EntryLifecycleError.EntryNotPublished, unpublishEntry(&db, entry.id));
}

test "content: public API coverage" {
    _ = saveEntry;
    _ = deleteEntry;
    _ = archiveEntry;
    _ = unpublishEntry;
}
