const Context = @import("router").Context;
const tpl = @import("tpl");
const views = @import("views");

pub fn handleIndex(ctx: *Context) !void {
    const content = tpl.renderStatic(views.index.Index);
    if (ctx.isPartial()) {
        ctx.html(content);
    } else {
        ctx.html(wrapWithBase(content, "Publr", &.{"/theme/theme.css"}, &.{}));
    }
}

pub fn handleErrorTest(_: *Context) !void {
    return error.TestError;
}

fn wrapWithBase(content: []const u8, title: []const u8, css: []const []const u8, js: []const []const u8) []const u8 {
    return tpl.render(views.base.Base, .{.{
        .title = title,
        .content = content,
        .css = css,
        .js = js,
    }});
}
