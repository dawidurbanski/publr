const std = @import("std");
const admin = @import("../admin.zig");
const html_escape = @import("../../lib/html.zig").escape;
const auth = @import("../../lib/auth.zig");

const Response = admin.Response;
const Error = admin.Error;
const Session = admin.Session;
const Status = admin.Status;

/// A plain HTML page: no stylesheet, no script, default browser rendering.
pub const Page = struct {
    out: std.Io.Writer.Allocating,

    pub fn begin(arena: std.mem.Allocator, title: []const u8, session: ?*const Session) Error!Page {
        std.debug.assert(title.len > 0);
        std.debug.assert(admin.page_bytes_max > 0);

        var page: Page = .{ .out = .init(arena) };
        const writer = page.sink();

        writer.writeAll("<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>") catch {
            return error.OutOfMemory;
        };
        try page.text(title);
        writer.writeAll("</title></head><body>\n") catch return error.OutOfMemory;

        if (session) |current| {
            try page.nav(current);
        }

        writer.writeAll("<h1>") catch return error.OutOfMemory;
        try page.text(title);
        writer.writeAll("</h1>\n") catch return error.OutOfMemory;

        return page;
    }

    fn nav(page: *Page, session: *const Session) Error!void {
        std.debug.assert(session.signed_in());
        std.debug.assert(page.out.written().len > 0);

        const writer = page.sink();

        writer.writeAll("<p><a href=\"/admin/types\">Content types</a> | " ++
            "<a href=\"/admin/content\">Content</a> | ") catch return error.OutOfMemory;
        writer.writeAll("<form method=\"post\" action=\"/admin/logout\" " ++
            "style=\"display:inline\">") catch return error.OutOfMemory;
        try page.csrf(session);
        writer.writeAll("<button>Log out</button></form></p>\n<hr>\n") catch {
            return error.OutOfMemory;
        };
    }

    pub fn csrf(page: *Page, session: *const Session) Error!void {
        std.debug.assert(session.signed_in());
        std.debug.assert(page.out.written().len > 0);

        page.sink().print("<input type=\"hidden\" name=\"csrf\" value=\"{s}\">", .{
            session.csrf_token(),
        }) catch return error.OutOfMemory;
    }

    pub fn sink(page: *Page) *std.Io.Writer {
        std.debug.assert(page.out.written().len <= admin.page_bytes_max);
        std.debug.assert(admin.page_bytes_max > 0);

        return &page.out.writer;
    }

    pub fn raw(page: *Page, html: []const u8) Error!void {
        std.debug.assert(page.out.written().len <= admin.page_bytes_max);
        std.debug.assert(html.len <= admin.page_bytes_max);

        page.sink().writeAll(html) catch return error.OutOfMemory;
    }

    /// Escaped text.
    pub fn text(page: *Page, value: []const u8) Error!void {
        std.debug.assert(page.out.written().len <= admin.page_bytes_max);
        std.debug.assert(value.len <= admin.page_bytes_max);

        try html_escape(page.sink(), value);
    }

    pub fn print(page: *Page, comptime template: []const u8, args: anytype) Error!void {
        std.debug.assert(template.len > 0);
        std.debug.assert(page.out.written().len <= admin.page_bytes_max);

        page.sink().print(template, args) catch return error.OutOfMemory;
    }

    pub fn send(page: *Page, response: *Response, status: Status) Error!void {
        std.debug.assert(page.out.written().len > 0);
        std.debug.assert(response.body.len == 0);

        page.sink().writeAll("</body></html>\n") catch return error.OutOfMemory;

        try response.html(status, page.out.written());
    }
};
