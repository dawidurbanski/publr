const std = @import("std");
const Db = @import("db").Db;
const auth_mod = @import("auth");
const common = @import("cli_common");
const fmt = @import("cli_format");

pub fn run(allocator: std.mem.Allocator, db: *Db, opts: common.GlobalOptions, args: []const []const u8) !void {
    var auth = auth_mod.Auth.init(allocator, db);
    const sub = args[0];

    if (std.mem.eql(u8, sub, "list")) return listUsers(allocator, &auth, opts);
    if (std.mem.eql(u8, sub, "create")) return createUser(allocator, &auth, opts, args[1..]);
    if (std.mem.eql(u8, sub, "get")) {
        if (args.len < 2) return error.MissingUserIdentifier;
        return getUser(allocator, &auth, opts, args[1]);
    }
    if (std.mem.eql(u8, sub, "update")) {
        if (args.len < 2) return error.MissingUserId;
        return updateUser(allocator, &auth, opts, args[1], args[2..]);
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (args.len < 2) return error.MissingUserId;
        return deleteUser(allocator, &auth, opts, args[1], args[2..]);
    }
    return error.UnknownUserCommand;
}

fn listUsers(allocator: std.mem.Allocator, auth: *auth_mod.Auth, opts: common.GlobalOptions) !void {
    const users = try auth.listUsers();
    defer {
        for (users) |*user| auth.freeUser(user);
        allocator.free(users);
    }

    if (opts.format == .json) {
        try fmt.printJson(.{ .data = users });
        return;
    }
    if (opts.format == .jsonl) {
        for (users) |user| try fmt.printJsonLine(user);
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .{};
    defer rows.deinit(allocator);
    defer {
        for (rows.items) |row| allocator.free(row);
    }

    for (users) |user| {
        const cols = try allocator.alloc([]const u8, 4);
        cols[0] = user.id;
        cols[1] = user.email;
        cols[2] = user.display_name;
        cols[3] = try std.fmt.allocPrint(allocator, "{d}", .{user.created_at});
        try rows.append(allocator, cols);
    }
    defer {
        for (rows.items) |row| allocator.free(row[3]);
    }

    try fmt.printTable(&.{ "ID", "Email", "Display Name", "Created At" }, rows.items, opts.quiet, allocator);
}

fn createUser(allocator: std.mem.Allocator, auth: *auth_mod.Auth, opts: common.GlobalOptions, args: []const []const u8) !void {
    var email: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--email")) {
            i += 1;
            if (i >= args.len) return error.MissingEmail;
            email = args[i];
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingName;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i >= args.len) return error.MissingPassword;
            password = args[i];
        }
    }

    if (email == null) return error.MissingEmail;
    if (name == null) return error.MissingName;
    if (password == null) return error.MissingPassword;

    const id = try auth.createUser(email.?, name.?, password.?);
    defer allocator.free(id);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .id = id, .email = email.? } });
    } else if (!opts.quiet) {
        std.debug.print("Created user {s} ({s})\n", .{ id, email.? });
    }
}

fn getUser(allocator: std.mem.Allocator, auth: *auth_mod.Auth, opts: common.GlobalOptions, id_or_email: []const u8) !void {
    const user_opt = if (std.mem.indexOfScalar(u8, id_or_email, '@') != null)
        try auth.getUserByEmail(id_or_email)
    else
        try auth.getUserById(id_or_email);

    var user = user_opt orelse return error.UserNotFound;
    defer auth.freeUser(&user);

    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = user });
        return;
    }

    var rows = [_]fmt.KeyValueRow{
        .{ .key = "id", .value = user.id },
        .{ .key = "email", .value = user.email },
        .{ .key = "display_name", .value = user.display_name },
        .{ .key = "email_verified", .value = if (user.email_verified) "true" else "false" },
    };
    try fmt.printKeyValueRows(&rows, opts.quiet, allocator);
}

fn updateUser(_: std.mem.Allocator, auth: *auth_mod.Auth, opts: common.GlobalOptions, user_id: []const u8, args: []const []const u8) !void {
    var current = (try auth.getUserById(user_id)) orelse return error.UserNotFound;
    defer auth.freeUser(&current);

    var email: []const u8 = current.email;
    var name: []const u8 = current.display_name;
    var password: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--email")) {
            i += 1;
            if (i >= args.len) return error.MissingEmail;
            email = args[i];
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingName;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i >= args.len) return error.MissingPassword;
            password = args[i];
        }
    }

    try auth.updateUser(user_id, email, name, password);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .id = user_id, .email = email, .display_name = name } });
    } else if (!opts.quiet) {
        std.debug.print("Updated user {s}\n", .{user_id});
    }
}

fn deleteUser(_: std.mem.Allocator, auth: *auth_mod.Auth, opts: common.GlobalOptions, user_id: []const u8, args: []const []const u8) !void {
    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) force = true;
    }

    const confirmed = try common.promptConfirm("Delete user?", force);
    if (!confirmed) return;

    try auth.deleteUser(user_id);
    if (opts.format == .json or opts.format == .jsonl) {
        try fmt.printJson(.{ .data = .{ .deleted = true, .id = user_id } });
    } else if (!opts.quiet) {
        std.debug.print("Deleted user {s}\n", .{user_id});
    }
}

test "cli user: argument validation branches" {
    var dummy_db: Db = undefined;
    try std.testing.expectError(error.MissingUserIdentifier, run(std.testing.allocator, &dummy_db, .{}, &.{"get"}));
    try std.testing.expectError(error.MissingUserId, run(std.testing.allocator, &dummy_db, .{}, &.{"delete"}));
    try std.testing.expectError(error.UnknownUserCommand, run(std.testing.allocator, &dummy_db, .{}, &.{"unknown"}));
}

test "cli user: create list get update delete via CLI binary" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const helpers = @import("cli_test_helpers");

    var runner = try helpers.runner_mod.CliTestRunner.init(std.testing.allocator);
    defer runner.deinit();
    try helpers.initDb(&runner);

    const email = try std.fmt.allocPrint(std.testing.allocator, "cli-user-{d}@test.local", .{std.time.nanoTimestamp()});
    defer std.testing.allocator.free(email);

    const user_id = try helpers.createUserViaCli(&runner, email, "CLI User");
    defer std.testing.allocator.free(user_id);

    var list = try runner.run(&.{ "user", "list", "--format", "json" });
    defer list.deinit();
    try helpers.runner_mod.expectSuccess(list);
    try helpers.runner_mod.expectStdoutContains(list, user_id);

    var get = try runner.run(&.{ "user", "get", user_id, "--format", "json" });
    defer get.deinit();
    try helpers.runner_mod.expectSuccess(get);

    var update = try runner.run(&.{ "user", "update", user_id, "--email", "cli-user-updated@test.local", "--format", "json" });
    defer update.deinit();
    try helpers.runner_mod.expectSuccess(update);

    var delete = try runner.run(&.{ "user", "delete", user_id, "--force", "--format", "json" });
    defer delete.deinit();
    try helpers.runner_mod.expectSuccess(delete);
}

test "cli user: public API coverage" {
    _ = run;
}
