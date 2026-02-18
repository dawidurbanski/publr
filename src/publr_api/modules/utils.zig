//! Plugin Utilities API
//!
//! Consolidates utility functions from plugin_utils, url, mime, and gravatar
//! into a single namespace. Provides a bound API for request-scoped operations
//! and static re-exports for pure functions.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! // Bound API (request-scoped)
//! const u = publr.utils(ctx);
//! u.redirect("/admin/media");
//! const folder = u.queryParam("folder");
//!
//! // Static functions
//! const size_str = try publr.Utils.formatSize(allocator, file_size);
//! const mime = publr.Utils.fromPath("photo.jpg");
//! ```

const std = @import("std");
const Context = @import("middleware").Context;
const utils = @import("plugin_utils");
const url = @import("url");
const mime = @import("mime");
const gravatar = @import("gravatar");
const version = @import("version");

const Allocator = std.mem.Allocator;

// =========================================================================
// Bound API (request-scoped convenience)
// =========================================================================

pub fn init(ctx: *Context) UtilsApi {
    return .{ .ctx = ctx };
}

pub const UtilsApi = struct {
    ctx: *Context,

    /// Send a 303 See Other redirect.
    pub fn redirect(self: @This(), location: []const u8) void {
        utils.redirect(self.ctx, location);
    }

    /// Parse a single query parameter value by name.
    pub fn queryParam(self: @This(), name: []const u8) ?[]const u8 {
        return utils.queryParam(self.ctx.query, name);
    }

    /// Parse an integer query parameter by name.
    pub fn queryInt(self: @This(), name: []const u8, comptime T: type) ?T {
        return utils.queryInt(self.ctx.query, name, T);
    }

    /// Parse all values for a query parameter key.
    pub fn queryParamAll(self: @This(), name: []const u8) []const []const u8 {
        return utils.queryParamAll(self.ctx.allocator, self.ctx.query, name);
    }
};

// =========================================================================
// Formatting
// =========================================================================

pub const formatSize = utils.formatSize;
pub const monthName = utils.monthName;
pub const buildPageUrl = utils.buildPageUrl;
pub const writeJsonEscaped = utils.writeJsonEscaped;
pub const writeEscaped = version.writeEscaped;

// =========================================================================
// Static Functions (direct use without bound context)
// =========================================================================

pub const redirect = utils.redirect;
pub const queryParam = utils.queryParam;
pub const queryParamAll = utils.queryParamAll;
pub const queryInt = utils.queryInt;

// =========================================================================
// URL Encoding/Decoding
// =========================================================================

pub const formDecode = url.formDecode;
pub const pathDecode = url.pathDecode;

// =========================================================================
// MIME Type Detection
// =========================================================================

pub const fromPath = mime.fromPath;
pub const fromExtension = mime.fromExtension;

// =========================================================================
// Gravatar
// =========================================================================

pub const GravatarUrl = gravatar.GravatarUrl;
pub const gravatarUrl = gravatar.url;
pub const gravatarUrlDefault = gravatar.urlDefault;
