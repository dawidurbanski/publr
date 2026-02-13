//! Term/taxonomy management for media folders and tags.
//!
//! Extracted from media.zig. Provides CRUD operations for terms
//! (folders, tags) and media-term relationship management.

const std = @import("std");
const db_mod = @import("db");
const Db = db_mod.Db;
const id_gen = @import("id_gen");

const Allocator = std.mem.Allocator;

pub const TermRecord = struct {
    id: []const u8,
    taxonomy_id: []const u8,
    slug: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
    description: []const u8,
    sort_order: i64,
};

/// Taxonomy IDs
pub const tax_media_folders = "tax_media_folders";
pub const tax_media_tags = "tax_media_tags";

/// Generate a unique term ID with t_ prefix
pub const generateTermId = id_gen.generateTermId;

/// Create a term (folder or tag)
pub fn createTerm(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
) !TermRecord {
    const id = try generateTermId(allocator);
    const slug = try slugify(allocator, name);
    defer allocator.free(slug);

    var stmt = try db.prepare(
        \\INSERT INTO terms (id, taxonomy_id, slug, name, parent_id, description, sort_order)
        \\VALUES (?1, ?2, ?3, ?4, ?5, '', 0)
    );
    defer stmt.deinit();

    try stmt.bindText(1, id);
    try stmt.bindText(2, taxonomy_id);
    try stmt.bindText(3, slug);
    try stmt.bindText(4, name);
    if (parent_id) |pid| try stmt.bindText(5, pid) else try stmt.bindNull(5);

    _ = try stmt.step();

    return .{
        .id = id,
        .taxonomy_id = try allocator.dupe(u8, taxonomy_id),
        .slug = try allocator.dupe(u8, slug),
        .name = try allocator.dupe(u8, name),
        .parent_id = if (parent_id) |pid| try allocator.dupe(u8, pid) else null,
        .description = try allocator.dupe(u8, ""),
        .sort_order = 0,
    };
}

/// List terms for a taxonomy, ordered by sort_order then name
pub fn listTerms(
    allocator: Allocator,
    db: *Db,
    taxonomy_id: []const u8,
) ![]TermRecord {
    var stmt = try db.prepare(
        "SELECT id, taxonomy_id, slug, name, parent_id, description, sort_order FROM terms WHERE taxonomy_id = ?1 ORDER BY sort_order, name",
    );
    defer stmt.deinit();

    try stmt.bindText(1, taxonomy_id);

    var items: std.ArrayListUnmanaged(TermRecord) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .taxonomy_id = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .slug = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
            .name = try allocator.dupe(u8, stmt.columnText(3) orelse ""),
            .parent_id = if (stmt.columnText(4)) |p| try allocator.dupe(u8, p) else null,
            .description = try allocator.dupe(u8, stmt.columnText(5) orelse ""),
            .sort_order = stmt.columnInt(6),
        });
    }

    return items.toOwnedSlice(allocator);
}

/// Rename a term
pub fn renameTerm(db: *Db, term_id: []const u8, new_name: []const u8) !void {
    var stmt = try db.prepare("UPDATE terms SET name = ?2 WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    try stmt.bindText(2, new_name);
    _ = try stmt.step();
}

/// Delete a term (cascades to media_terms associations)
pub fn deleteTerm(db: *Db, term_id: []const u8) !void {
    // First, unparent any children
    var unparent = try db.prepare("UPDATE terms SET parent_id = NULL WHERE parent_id = ?1");
    defer unparent.deinit();
    try unparent.bindText(1, term_id);
    _ = try unparent.step();

    var stmt = try db.prepare("DELETE FROM terms WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    _ = try stmt.step();
}

/// Move a term to a new parent (or root if new_parent_id is null)
pub fn moveTermParent(db: *Db, term_id: []const u8, new_parent_id: ?[]const u8) !void {
    var stmt = try db.prepare("UPDATE terms SET parent_id = ?2 WHERE id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    if (new_parent_id) |pid| try stmt.bindText(2, pid) else try stmt.bindNull(2);
    _ = try stmt.step();
}

/// Delete a term with filesystem-like reparenting:
/// - Children inherit the deleted folder's parent
/// - Files move to the parent folder (or become uncategorized if root)
pub fn deleteTermWithReparent(db: *Db, term_id: []const u8) !void {
    // 1. Get this term's parent_id
    var get_parent = try db.prepare("SELECT parent_id FROM terms WHERE id = ?1");
    defer get_parent.deinit();
    try get_parent.bindText(1, term_id);
    if (!try get_parent.step()) return; // term doesn't exist
    const has_parent = !get_parent.columnIsNull(0);
    const parent_id_raw = get_parent.columnText(0);

    // 2. Children inherit this term's parent
    {
        var stmt = try db.prepare("UPDATE terms SET parent_id = ?2 WHERE parent_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        if (has_parent) {
            try stmt.bindText(2, parent_id_raw.?);
        } else {
            try stmt.bindNull(2);
        }
        _ = try stmt.step();
    }

    // 3. Files move to parent folder (if parent exists)
    if (has_parent) {
        var stmt = try db.prepare("UPDATE media_terms SET term_id = ?2 WHERE term_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        try stmt.bindText(2, parent_id_raw.?);
        _ = try stmt.step();
    }
    // If no parent, CASCADE will clean up media_terms when term is deleted

    // 4. Delete the term
    {
        var stmt = try db.prepare("DELETE FROM terms WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, term_id);
        _ = try stmt.step();
    }
}

/// Check if a term exists in the terms table
pub fn termExists(db: *Db, term_id: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM terms WHERE id = ?1 LIMIT 1") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, term_id) catch return false;
    return stmt.step() catch false;
}

/// Get a folder ID plus all its descendant folder IDs using a recursive CTE.
/// Returns the folder itself + all children, grandchildren, etc.
pub fn getDescendantFolderIds(
    allocator: Allocator,
    db: *Db,
    folder_id: []const u8,
) ![]const []const u8 {
    var stmt = try db.prepare(
        \\WITH RECURSIVE folder_tree(id) AS (
        \\  SELECT id FROM terms WHERE id = ?1
        \\  UNION ALL
        \\  SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id
        \\)
        \\SELECT id FROM folder_tree
    );
    defer stmt.deinit();
    try stmt.bindText(1, folder_id);

    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }

    return items.toOwnedSlice(allocator);
}

// =========================================================================
// Media-Term Relationships
// =========================================================================

/// Sync taxonomy fields to media_terms table
pub fn syncMediaTerms(db: *Db, media_id: []const u8, term_ids: []const []const u8) !void {
    // Delete existing terms for this media
    var del_stmt = try db.prepare("DELETE FROM media_terms WHERE media_id = ?1");
    defer del_stmt.deinit();
    try del_stmt.bindText(1, media_id);
    _ = try del_stmt.step();

    if (term_ids.len == 0) return;

    // Insert new term relationships
    var stmt = try db.prepare(
        "INSERT INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer stmt.deinit();

    for (term_ids) |term_id| {
        try stmt.bindText(1, media_id);
        try stmt.bindText(2, term_id);
        _ = try stmt.step();
        stmt.reset();
    }
}

/// Add a single term to a media item (INSERT OR IGNORE -- safe if already exists)
pub fn addTermToMedia(db: *Db, media_id: []const u8, term_id: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT OR IGNORE INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, term_id);
    _ = try stmt.step();
}

/// Remove a single term from a media item
pub fn removeTermFromMedia(db: *Db, media_id: []const u8, term_id: []const u8) !void {
    var stmt = try db.prepare(
        "DELETE FROM media_terms WHERE media_id = ?1 AND term_id = ?2",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, term_id);
    _ = try stmt.step();
}

/// Replace a media item's folder assignment. Removes existing folder terms
/// (terms in the media_folders taxonomy) and assigns the new folder.
pub fn replaceMediaFolder(db: *Db, media_id: []const u8, new_folder_id: []const u8) !void {
    // Delete existing folder associations for this media
    var del_stmt = try db.prepare(
        \\DELETE FROM media_terms WHERE media_id = ?1 AND term_id IN (
        \\  SELECT id FROM terms WHERE taxonomy_id = ?2
        \\)
    );
    defer del_stmt.deinit();
    try del_stmt.bindText(1, media_id);
    try del_stmt.bindText(2, tax_media_folders);
    _ = try del_stmt.step();

    // Insert new folder association
    var ins_stmt = try db.prepare(
        "INSERT OR IGNORE INTO media_terms (media_id, term_id) VALUES (?1, ?2)",
    );
    defer ins_stmt.deinit();
    try ins_stmt.bindText(1, media_id);
    try ins_stmt.bindText(2, new_folder_id);
    _ = try ins_stmt.step();
}

/// Get term IDs assigned to a media item, optionally filtered by taxonomy
pub fn getMediaTermIds(
    allocator: Allocator,
    db: *Db,
    media_id: []const u8,
    taxonomy_id: ?[]const u8,
) ![][]const u8 {
    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    if (taxonomy_id) |tax_id| {
        var stmt = try db.prepare(
            "SELECT mt.term_id FROM media_terms mt JOIN terms t ON t.id = mt.term_id WHERE mt.media_id = ?1 AND t.taxonomy_id = ?2",
        );
        defer stmt.deinit();
        try stmt.bindText(1, media_id);
        try stmt.bindText(2, tax_id);

        while (try stmt.step()) {
            try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
        }
    } else {
        var stmt = try db.prepare("SELECT term_id FROM media_terms WHERE media_id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, media_id);

        while (try stmt.step()) {
            try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Get term names assigned to a media item for a taxonomy (for display)
pub fn getMediaTermNames(
    allocator: Allocator,
    db: *Db,
    media_id: []const u8,
    taxonomy_id: []const u8,
) ![][]const u8 {
    var stmt = try db.prepare(
        "SELECT t.name FROM media_terms mt JOIN terms t ON t.id = mt.term_id WHERE mt.media_id = ?1 AND t.taxonomy_id = ?2 ORDER BY t.name",
    );
    defer stmt.deinit();
    try stmt.bindText(1, media_id);
    try stmt.bindText(2, taxonomy_id);

    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer items.deinit(allocator);

    while (try stmt.step()) {
        try items.append(allocator, try allocator.dupe(u8, stmt.columnText(0) orelse ""));
    }

    return items.toOwnedSlice(allocator);
}

/// Count media in a specific term
pub fn countMediaInTerm(db: *Db, term_id: []const u8) !u32 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM media_terms WHERE term_id = ?1");
    defer stmt.deinit();
    try stmt.bindText(1, term_id);
    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Count media in a folder and all its descendant folders using a recursive CTE.
pub fn countMediaInFolderRecursive(db: *Db, folder_id: []const u8) !u32 {
    var stmt = try db.prepare(
        \\WITH RECURSIVE folder_tree(id) AS (
        \\  SELECT id FROM terms WHERE id = ?1
        \\  UNION ALL
        \\  SELECT t.id FROM terms t JOIN folder_tree ft ON t.parent_id = ft.id
        \\)
        \\SELECT COUNT(*) FROM media_terms WHERE term_id IN (SELECT id FROM folder_tree)
    );
    defer stmt.deinit();
    try stmt.bindText(1, folder_id);
    _ = try stmt.step();
    return @intCast(stmt.columnInt(0));
}

/// Simple slugify: lowercase, replace non-alphanumeric with hyphens
pub fn slugify(allocator: Allocator, name: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, name.len);
    var len: usize = 0;
    var prev_hyphen = false;

    for (name) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (std.ascii.isAlphanumeric(lower)) {
            buf[len] = lower;
            len += 1;
            prev_hyphen = false;
        } else if (!prev_hyphen and len > 0) {
            buf[len] = '-';
            len += 1;
            prev_hyphen = true;
        }
    }

    if (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) {
        allocator.free(buf);
        return try allocator.dupe(u8, "term");
    }

    return try allocator.realloc(buf, len);
}

// =============================================================================
// Tests
// =============================================================================

const schema_sql = @embedFile("tools/schema.sql");

fn initTestDb() !Db {
    var db = try Db.init(std.testing.allocator, ":memory:");
    try db.exec(schema_sql);
    return db;
}

test "slugify: basic name" {
    const slug = try slugify(std.testing.allocator, "My Folder");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("my-folder", slug);
}

test "slugify: special chars" {
    const slug = try slugify(std.testing.allocator, "Photo & Videos (2026)");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("photo-videos-2026", slug);
}

test "createTerm and listTerms" {
    var db = try initTestDb();
    defer db.deinit();

    const term = try createTerm(std.testing.allocator, &db, tax_media_folders, "Photos", null);
    defer std.testing.allocator.free(term.id);
    defer std.testing.allocator.free(term.taxonomy_id);
    defer std.testing.allocator.free(term.slug);
    defer std.testing.allocator.free(term.name);
    defer std.testing.allocator.free(term.description);

    try std.testing.expectEqualStrings("Photos", term.name);
    try std.testing.expectEqualStrings("photos", term.slug);

    const terms = try listTerms(std.testing.allocator, &db, tax_media_folders);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    try std.testing.expectEqual(@as(usize, 1), terms.len);
    try std.testing.expectEqualStrings("Photos", terms[0].name);
}

test "renameTerm" {
    var db = try initTestDb();
    defer db.deinit();

    const term = try createTerm(std.testing.allocator, &db, tax_media_tags, "Old Name", null);
    defer std.testing.allocator.free(term.id);
    defer std.testing.allocator.free(term.taxonomy_id);
    defer std.testing.allocator.free(term.slug);
    defer std.testing.allocator.free(term.name);
    defer std.testing.allocator.free(term.description);

    try renameTerm(&db, term.id, "New Name");

    const terms = try listTerms(std.testing.allocator, &db, tax_media_tags);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    try std.testing.expectEqualStrings("New Name", terms[0].name);
}

test "deleteTerm removes term and unparents children" {
    var db = try initTestDb();
    defer db.deinit();

    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    try deleteTerm(&db, parent.id);

    const terms = try listTerms(std.testing.allocator, &db, tax_media_folders);
    defer {
        for (terms) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.taxonomy_id);
            std.testing.allocator.free(t.slug);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.description);
            if (t.parent_id) |p| std.testing.allocator.free(p);
        }
        std.testing.allocator.free(terms);
    }

    // Only child remains with null parent
    try std.testing.expectEqual(@as(usize, 1), terms.len);
    try std.testing.expect(terms[0].parent_id == null);
}

test "getDescendantFolderIds returns folder and all descendants" {
    var db = try initTestDb();
    defer db.deinit();

    const parent = try createTerm(std.testing.allocator, &db, tax_media_folders, "Parent", null);
    defer std.testing.allocator.free(parent.id);
    defer std.testing.allocator.free(parent.taxonomy_id);
    defer std.testing.allocator.free(parent.slug);
    defer std.testing.allocator.free(parent.name);
    defer std.testing.allocator.free(parent.description);

    const child = try createTerm(std.testing.allocator, &db, tax_media_folders, "Child", parent.id);
    defer std.testing.allocator.free(child.id);
    defer std.testing.allocator.free(child.taxonomy_id);
    defer std.testing.allocator.free(child.slug);
    defer std.testing.allocator.free(child.name);
    defer std.testing.allocator.free(child.description);
    defer if (child.parent_id) |p| std.testing.allocator.free(p);

    const grandchild = try createTerm(std.testing.allocator, &db, tax_media_folders, "Grandchild", child.id);
    defer std.testing.allocator.free(grandchild.id);
    defer std.testing.allocator.free(grandchild.taxonomy_id);
    defer std.testing.allocator.free(grandchild.slug);
    defer std.testing.allocator.free(grandchild.name);
    defer std.testing.allocator.free(grandchild.description);
    defer if (grandchild.parent_id) |p| std.testing.allocator.free(p);

    // From parent: should get parent + child + grandchild
    const ids = try getDescendantFolderIds(std.testing.allocator, &db, parent.id);
    defer {
        for (ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 3), ids.len);

    // From child: should get child + grandchild
    const child_ids = try getDescendantFolderIds(std.testing.allocator, &db, child.id);
    defer {
        for (child_ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(child_ids);
    }
    try std.testing.expectEqual(@as(usize, 2), child_ids.len);

    // From grandchild: just itself
    const gc_ids = try getDescendantFolderIds(std.testing.allocator, &db, grandchild.id);
    defer {
        for (gc_ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(gc_ids);
    }
    try std.testing.expectEqual(@as(usize, 1), gc_ids.len);
}
