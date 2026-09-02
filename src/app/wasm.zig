const std = @import("std");
const publr = @import("publr");

const db = publr.db;
const routes = publr.routes;
const auth = publr.auth;
const http = publr.http;

const heap_bytes: u32 = 16 << 20;
const arena_bytes: u32 = 4 << 20;
const request_bytes_max: u32 = 8 << 20;

const State = struct {
    gpa: std.mem.Allocator,
    heap: []align(8) u8,
    runtime: db.Runtime,
    connection: db.Db,
    auth: auth.State,
    site: routes.Site,
    app: http.App,
    io_backend: std.Io.Threaded,
    arena_buffer: []u8,
    response: []u8,
};

// A wasm module is one instance behind a C ABI; the exports below are its only record points.
var state: ?*State = null;

const RequestJson = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",

    const Header = struct { name: []const u8, value: []const u8 };
};

const ResponseJson = struct {
    status: u16,
    headers: []const RequestJson.Header,
    body: []const u8,
};

export fn publr_init() i32 {
    if (state != null) {
        return 0;
    }

    const gpa = std.heap.wasm_allocator;
    const instance = gpa.create(State) catch return 1;

    instance.gpa = gpa;
    instance.heap = gpa.alignedAlloc(u8, .@"8", heap_bytes) catch return 2;
    instance.runtime = db.Runtime.init(.{ .heap = instance.heap }) catch return 3;
    instance.connection = db.open(&instance.runtime, ":memory:") catch return 4;
    db.schema.apply(&instance.connection) catch return 4;
    publr.registry.SDK.apply_schemas(&instance.connection) catch return 4;
    instance.io_backend = std.Io.Threaded.init(gpa, .{});
    instance.auth.init(gpa, instance.io_backend.io(), .{}) catch return 6;
    instance.site = .{
        .connection = &instance.connection,
        .auth = &instance.auth,
        .io = instance.io_backend.io(),
    };
    instance.app = http.App.offline(.{});
    instance.app.user_data = &instance.site;
    instance.arena_buffer = gpa.alloc(u8, arena_bytes) catch return 5;
    instance.response = &.{};

    routes.register(instance.app.router());
    apply_declared_types(instance) catch return 7;

    std.debug.assert(instance.app.routes.routes_len > 0);
    std.debug.assert(instance.runtime.open_count == 1);

    state = instance;

    return 0;
}

export fn publr_alloc(len: u32) ?[*]u8 {
    const instance = state orelse return null;

    if (len == 0 or len > request_bytes_max) {
        return null;
    }

    const bytes = instance.gpa.alloc(u8, len) catch return null;

    std.debug.assert(bytes.len == len);

    return bytes.ptr;
}

export fn publr_free(ptr: [*]u8, len: u32) void {
    const instance = state orelse return;
    std.debug.assert(len > 0);
    std.debug.assert(len <= request_bytes_max);

    instance.gpa.free(ptr[0..len]);
}

export fn publr_request(ptr: [*]const u8, len: u32) i32 {
    const instance = state orelse return 1;

    if (len == 0 or len > request_bytes_max) {
        return 2;
    }

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    const arena = arena_state.allocator();

    const json_in = ptr[0..len];
    const parsed = std.json.parseFromSliceLeaky(RequestJson, arena, json_in, .{}) catch return 3;
    const head = build_request(parsed) catch return 4;

    var request: http.Request = .{ .inner = &head, .body = parsed.body };
    var response = instance.app.handle(arena, &request);

    response.set_header("X-Publr-Runtime", "wasm") catch return 5;

    const envelope: ResponseJson = .{
        .status = response.status.code(),
        .headers = @ptrCast(response.headers[0..response.headers_len]),
        .body = response.body,
    };
    const json = std.json.Stringify.valueAlloc(instance.gpa, envelope, .{}) catch return 6;

    if (instance.response.len > 0) {
        instance.gpa.free(instance.response);
    }

    instance.response = json;

    std.debug.assert(instance.response.len > 0);
    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

export fn publr_response_ptr() [*]const u8 {
    const instance = state orelse return @ptrFromInt(8);
    return instance.response.ptr;
}

export fn publr_response_len() u32 {
    const instance = state orelse return 0;
    return @intCast(instance.response.len);
}

export fn publr_export() i32 {
    const instance = state orelse return 1;

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    const bytes = instance.connection.serialize(arena_state.allocator()) catch return 2;
    const copy = instance.gpa.dupe(u8, bytes) catch return 3;

    if (instance.response.len > 0) {
        instance.gpa.free(instance.response);
    }

    instance.response = copy;

    std.debug.assert(instance.response.len > 0);
    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

export fn publr_import(ptr: [*]const u8, len: u32) i32 {
    const instance = state orelse return 1;

    if (len == 0 or len > request_bytes_max) {
        return 2;
    }

    instance.connection.deserialize(ptr[0..len]) catch return 3;
    db.schema.apply(&instance.connection) catch return 4;
    publr.registry.SDK.apply_schemas(&instance.connection) catch return 4;
    apply_declared_types(instance) catch return 7;

    std.debug.assert(instance.connection.transaction_depth == 0);

    return 0;
}

fn apply_declared_types(instance: *State) !void {
    std.debug.assert(instance.connection.transaction_depth == 0);
    std.debug.assert(instance.arena_buffer.len == arena_bytes);

    var arena_state = std.heap.FixedBufferAllocator.init(instance.arena_buffer);
    var ctx = publr.sdk.Ctx.init(.{
        .caller = .system,
        .db = &instance.connection,
        .io = instance.io_backend.io(),
        .arena = arena_state.allocator(),
        .auth = &instance.auth,
        .now_ms = publr.sdk.context.wall_clock_ms(instance.io_backend.io()),
    });

    try publr.plugin.types.apply_all(&ctx);
}

fn build_request(parsed: RequestJson) !http.Head {
    std.debug.assert(parsed.method.len > 0);
    std.debug.assert(parsed.path.len > 0);

    var request: http.Head = .{
        .method = parse_method(parsed.method) orelse return error.UnknownMethod,
        .path = parsed.path,
        .query = parsed.query,
        .version = .http_1_1,
        .headers = undefined,
        .headers_len = 0,
        .content_length = parsed.body.len,
        .keep_alive = true,
        .head_len = 0,
    };

    for (parsed.headers) |header| {
        if (request.headers_len == request.headers.len) {
            break;
        }
        request.headers[request.headers_len] = .{ .name = header.name, .value = header.value };
        request.headers_len += 1;
    }

    return request;
}

fn parse_method(text: []const u8) ?http.Method {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= 16);

    inline for (@typeInfo(http.Method).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, text)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}
