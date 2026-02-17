const std = @import("std");
const Db = @import("db").Db;
const taxonomy = @import("taxonomy");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (args.len < 2) return error.MissingTaxonomyId;
        return listTerms(allocator, db, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 3) return error.MissingTermArgs;
        return createTerm(allocator, db, opts, args[1], args[2], args[3..]);
    }
    if (std.mem.eql(u8, sub, "rename")) {
        if (args.len < 3) return error.MissingRenameArgs;
        return renameTerm(db, opts, args[1], args[2]);
    }
    if (std.mem.eql(u8, sub, "move")) {
        if (args.len < 2) return error.MissingTermId;
        return moveTerm(db, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len < 2) return error.MissingTermId;
        return deleteTerm(db, opts, args[1], args[2..]);
    }
    return error.UnknownTaxonomyCommand;
}

fn listTerms(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, taxonomy_id: []const u8) !void {
    const terms = try taxonomy.listTerms(allocator, db, taxonomy_id);
    defer {
        for (terms) |term| {
            allocator.free(term.id);
            allocator.free(term.taxonomy_id);
            allocator.free(term.slug);
            allocator.free(term.name);
            if (term.parent_id) |pid| allocator.free(pid);
            allocator.free(term.description);
        }
        allocator.free(terms);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = terms });
        return;
    }
    if (opts.format == .jsonl) {
        for (terms) |term| try fmt.printJsonLine(term);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }
    defer {
        for (rows.items) |row| allocator.free(row[4]);
    }

    for (terms) |term| {
        const cols = try allocator.alloc([]const u8, 5);
        cols[0] = term.id;
        cols[1] = term.name;
        cols[2] = term.slug;
        cols[3] = term.parent_id orelse "";
        cols[4] = try std.fmt.allocPrint(allocator, "{d}", .{term.sort_order});
        try rows.append(allocator, cols);
    }
    try fmt.printTable(&.{ "ID", "Name", "Slug", "Parent", "Sort" }, rows.items, opts.quiet, allocator);
}

fn createTerm(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, taxonomy_id: []const u8, name: []const u8, args: []const []const u8) !void {
    var parent: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--parent")) {
            i += 1;
            if (i >= args.len) return error.MissingParentId;
            parent = args[i];
        }
    }

    const term = try taxonomy.createTerm(allocator, db, taxonomy_id, name, parent);
    defer {
        allocator.free(term.id);
        allocator.free(term.taxonomy_id);
        allocator.free(term.slug);
        allocator.free(term.name);
        if (term.parent_id) |pid| allocator.free(pid);
        allocator.free(term.description);
    }

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = term });
    } else if (!opts.quiet) {
        std.debug.print("Created term {s}\n", .{term.id});
    }
}

fn renameTerm(db: *Db, opts: common.GlobalOptions, term_id: []const u8, new_name: []const u8) !void {
    try taxonomy.renameTerm(db, term_id, new_name);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .updated = true, .id = term_id } });
    } else if (!opts.quiet) {
        std.debug.print("Renamed term {s}\n", .{term_id});
    }
}

fn moveTerm(db: *Db, opts: common.GlobalOptions, term_id: []const u8, args: []const []const u8) !void {
    var parent: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--parent")) {
            i += 1;
            if (i >= args.len) return error.MissingParentId;
            parent = args[i];
        }
    }
    try taxonomy.moveTermParent(db, term_id, parent);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .moved = true, .id = term_id, .parent = parent } });
    } else if (!opts.quiet) {
        std.debug.print("Moved term {s}\n", .{term_id});
    }
}

fn deleteTerm(db: *Db, opts: common.GlobalOptions, term_id: []const u8, args: []const []const u8) !void {
    var cascade = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cascade")) cascade = true;
    }

    if (cascade) {
        try taxonomy.deleteTerm(db, term_id);
    } else {
        try taxonomy.deleteTermWithReparent(db, term_id);
    }

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .deleted = true, .id = term_id, .cascade = cascade } });
    } else if (!opts.quiet) {
        std.debug.print("Deleted term {s}\n", .{term_id});
    }
}

test "cli taxonomy: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingTaxonomyId, run(std.testing.allocator, &dummy_db, .{}, &.{"list"}));
    try std.testing.expectError(error.MissingTermArgs, run(std.testing.allocator, &dummy_db, .{}, &.{ "create", "category" }));
    try std.testing.expectError(error.UnknownTaxonomyCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli taxonomy: create list rename move delete branches" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    const parent_name = try helpers.unique("cli-tax-parent");
    defer std.testing.allocator.free(parent_name);
    const child_name = try helpers.unique("cli-tax-child");
    defer std.testing.allocator.free(child_name);

    const parent_id = try helpers.createTermViaCli(&runner, "category", parent_name, null);
    defer std.testing.allocator.free(parent_id);
    const child_id = try helpers.createTermViaCli(&runner, "category", child_name, parent_id);
    defer std.testing.allocator.free(child_id);

    var list = try runner.run(&.{ "taxonomy", "list", "category", "--format", "json" });
    defer list.deinit();
    try helpers.runner_mod.expectSuccess(list);

    var rename = try runner.run(&.{ "taxonomy", "rename", child_id, "Renamed Child", "--format", "json" });
    defer rename.deinit();
    try helpers.runner_mod.expectSuccess(rename);

    var move = try runner.run(&.{ "taxonomy", "move", child_id, "--format", "json" });
    defer move.deinit();
    try helpers.runner_mod.expectSuccess(move);

    var delete_reparent = try runner.run(&.{ "taxonomy", "delete", parent_id, "--format", "json" });
    defer delete_reparent.deinit();
    try helpers.runner_mod.expectSuccess(delete_reparent);

    const p2_name = try helpers.unique("cli-tax-cascade-parent");
    defer std.testing.allocator.free(p2_name);
    const c2_name = try helpers.unique("cli-tax-cascade-child");
    defer std.testing.allocator.free(c2_name);

    const parent2_id = try helpers.createTermViaCli(&runner, "category", p2_name, null);
    defer std.testing.allocator.free(parent2_id);
    const child2_id = try helpers.createTermViaCli(&runner, "category", c2_name, parent2_id);
    defer std.testing.allocator.free(child2_id);

    var delete_cascade = try runner.run(&.{ "taxonomy", "delete", parent2_id, "--cascade", "--format", "json" });
    defer delete_cascade.deinit();
    try helpers.runner_mod.expectSuccess(delete_cascade);
}

test "cli taxonomy: public API coverage" {
    _ = run;
}
