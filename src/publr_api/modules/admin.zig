//! Admin Page Registration API
//!
//! Re-exports the admin page registration system for plugins.
//! Plugins use this to register admin pages with navigation items and routes.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! pub const page = publr.admin.registerPage(.{
//!     .id = "my_plugin",
//!     .title = "My Plugin",
//!     .path = "/my-plugin",
//!     .icon = icons.my_icon,
//!     .position = 70,
//!     .setup = setup,
//! });
//! ```

const admin = @import("admin_api");

pub const Page = admin.Page;
pub const PageApp = admin.PageApp;
pub const RouteRegistrar = admin.RouteRegistrar;
pub const Handler = admin.Handler;
pub const registerPage = admin.registerPage;
pub const resolvePagePath = admin.resolvePagePath;
