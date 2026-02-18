//! Template Rendering API
//!
//! Re-exports template rendering functions for plugins.
//! Uses a thread-local arena — rendered slices are valid until end of request.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! const content = publr.template.renderStatic(views.admin.my_page.MyPage);
//! const html = publr.template.render(views.admin.my_page.Detail, .{.{ .id = id }});
//! ```

const tpl = @import("tpl");

pub const render = tpl.render;
pub const renderStatic = tpl.renderStatic;
pub const renderFnToSlice = tpl.renderFnToSlice;
