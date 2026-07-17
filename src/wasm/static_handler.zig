//! Minimal /static/* handler for the WASM dev shell.
//!
//! The native build serves embedded CSS/JS through src/http_handlers/static_files.zig,
//! but that handler imports publr_ui + theme_static which aren't wired into the
//! WASM target. This trimmed-down handler covers just the CSS files the WASM
//! browser shell needs at boot — tokens.css and publr.css (preflight + JIT).

const std = @import("std");
const mw = @import("middleware");

const TokensCss = @embedFile("static_tokens_css");
const PreflightCss = @embedFile("static_preflight_css");
const JitCss = @embedFile("static_jit_css");
// Match prod composition from src/http_handlers/static_files.zig:
const PublrCss = PreflightCss ++ "\n" ++ JitCss;

pub fn handleStatic(ctx: *mw.Context) !void {
    const file = ctx.wildcard orelse {
        ctx.response.setStatus("404 Not Found");
        ctx.response.setContentType("text/plain");
        ctx.response.setBody("Not Found");
        return;
    };

    if (std.mem.eql(u8, file, "styles/tokens.css")) {
        ctx.response.setContentType("text/css");
        ctx.response.setBody(TokensCss);
        return;
    }

    if (std.mem.eql(u8, file, "styles/publr.css")) {
        ctx.response.setContentType("text/css");
        ctx.response.setBody(PublrCss);
        return;
    }

    ctx.response.setStatus("404 Not Found");
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("Not Found");
}
