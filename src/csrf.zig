const std = @import("std");
const mw = @import("middleware");
const auth_middleware = @import("auth_middleware");

const Context = mw.Context;
const NextFn = mw.NextFn;

pub const CSRF_COOKIE = "publr_csrf";
pub const CSRF_FIELD = "_csrf";

threadlocal var token_buf: [64]u8 = undefined;

pub fn csrfMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    if (!isStateChanging(ctx.method)) {
        return next(ctx);
    }

    if (!validateCsrf(ctx)) {
        ctx.response.setStatus("403 Forbidden");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Invalid CSRF token");
        return;
    }

    return next(ctx);
}

pub fn ensureToken(ctx: *Context) []const u8 {
    if (auth_middleware.parseCookie(ctx, CSRF_COOKIE)) |token| {
        return token;
    }

    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const token = hexEncodeLower(&random_bytes, &token_buf);

    setCsrfCookie(ctx, token);
    return token;
}

fn validateCsrf(ctx: *Context) bool {
    const cookie_token = auth_middleware.parseCookie(ctx, CSRF_COOKIE) orelse return false;
    const form_token = ctx.formValue(CSRF_FIELD) orelse
        ctx.getRequestHeader("X-CSRF-Token") orelse
        multipartFormValue(ctx, CSRF_FIELD) orelse
        return false;
    return std.mem.eql(u8, cookie_token, form_token);
}

/// Extract a form field value from a multipart/form-data body.
/// Only used as fallback when URL-encoded parsing fails.
fn multipartFormValue(ctx: *Context, name: []const u8) ?[]const u8 {
    const content_type = ctx.getRequestHeader("Content-Type") orelse return null;
    const boundary_marker = "boundary=";
    const boundary_idx = std.mem.indexOf(u8, content_type, boundary_marker) orelse return null;
    const boundary = content_type[boundary_idx + boundary_marker.len ..];
    if (boundary.len == 0) return null;

    const body_content = ctx.body orelse return null;

    // Build the needle: Content-Disposition: form-data; name="<name>"
    const needle = std.fmt.allocPrint(ctx.allocator, "name=\"{s}\"", .{name}) catch return null;
    defer ctx.allocator.free(needle);

    // Build delimiter for boundary
    const delim = std.fmt.allocPrint(ctx.allocator, "\r\n--{s}", .{boundary}) catch return null;
    defer ctx.allocator.free(delim);

    // Find the part containing this field name
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, body_content, search_pos, needle)) |name_pos| {
        // Find the blank line after headers (\r\n\r\n)
        const after_name = body_content[name_pos..];
        const header_end = std.mem.indexOf(u8, after_name, "\r\n\r\n") orelse {
            search_pos = name_pos + needle.len;
            continue;
        };

        // Check this is NOT a file field (no filename= before the header end)
        const header_section = after_name[0..header_end];
        if (std.mem.indexOf(u8, header_section, "filename=") != null) {
            search_pos = name_pos + needle.len;
            continue;
        }

        const value_start = name_pos + header_end + 4;
        const remaining = body_content[value_start..];

        // Value ends at next boundary
        const value_end = std.mem.indexOf(u8, remaining, delim) orelse remaining.len;
        return remaining[0..value_end];
    }

    return null;
}

fn isStateChanging(method: mw.Method) bool {
    return switch (method) {
        .GET => false,
        .POST, .PUT, .DELETE => true,
    };
}

fn setCsrfCookie(ctx: *Context, token: []const u8) void {
    var cookie_buf: [256]u8 = undefined;
    const cookie = std.fmt.bufPrint(
        &cookie_buf,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
        .{
            CSRF_COOKIE,
            token,
            @as(u64, 7 * 24 * 60 * 60), // 7 days
        },
    ) catch return;

    ctx.response.setHeaderOwned("Set-Cookie", cookie);
}

fn hexEncodeLower(input: []const u8, out: []u8) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var o: usize = 0;
    while (i < input.len and o + 1 < out.len) : (i += 1) {
        const b = input[i];
        out[o] = hex[@intCast((b >> 4) & 0x0f)];
        out[o + 1] = hex[@intCast(b & 0x0f)];
        o += 2;
    }
    return out[0..o];
}
