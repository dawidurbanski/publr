//! Pure content rules: no database, no HTTP. Data in, data out.

pub const field = @import("model/field.zig");
pub const validate = @import("model/validate.zig");
pub const status = @import("model/status.zig");
pub const convert = @import("model/convert.zig");
pub const evolution = @import("model/evolution.zig");
pub const document = @import("model/document.zig");
pub const content_type = @import("model/content_type.zig");
pub const account = @import("model/account.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
