const std = @import("std");
const Context = @import("router.zig").Context;
const NextFn = @import("router.zig").NextFn;
const publr_config = @import("publr_config");

/// Live reload script using Server-Sent Events.
/// Single persistent connection — no polling noise in network tab.
const live_reload_script =
    \\<script>
    \\(function(){
    \\  var es = new EventSource('/__dev/events');
    \\  es.addEventListener('reload', function(){
    \\    es.close();
    \\    location.reload();
    \\  });
    \\  es.addEventListener('css-reload', function(){
    \\    document.querySelectorAll('link[rel="stylesheet"]').forEach(function(link){
    \\      var href = link.href.replace(/(\?|&)_t=\d+/, '');
    \\      link.href = href + (href.indexOf('?') > -1 ? '&' : '?') + '_t=' + Date.now();
    \\    });
    \\  });
    \\  window.addEventListener('beforeunload', function(){ es.close(); });
    \\  es.onerror = function(){
    \\    es.close();
    \\    var d = 200;
    \\    var check = function(){
    \\      fetch('/__dev/ready').then(function(r){
    \\        if(r.ok) location.reload();
    \\        else { d = Math.min(d * 1.5, 2000); setTimeout(check, d); }
    \\      }).catch(function(){ d = Math.min(d * 1.5, 2000); setTimeout(check, d); });
    \\    };
    \\    setTimeout(check, 300);
    \\  };
    \\})();
    \\</script>
;

/// Track mtimes separately: templates trigger full reload, assets swap in-place
var latest_tpl_mtime: i128 = 0;
var latest_asset_mtime: i128 = 0;
var latest_input_mtime: i128 = 0;
var mtime_initialized: bool = false;

/// Dev middleware that:
/// 1. Adds Cache-Control: no-store to prevent browser caching
/// 2. Injects live reload script into HTML responses
pub fn devMiddleware(ctx: *Context, next: NextFn) !void {
    try next(ctx);

    // Add no-cache header
    ctx.response.setHeader("Cache-Control", "no-store");

    // Inject live reload script into HTML responses
    if (std.mem.eql(u8, ctx.response.content_type, "text/html")) {
        injectLiveReload(ctx);
    }
}

fn injectLiveReload(ctx: *Context) void {
    const body = ctx.response.body;

    // Find </body> tag to inject before it
    if (std.mem.lastIndexOf(u8, body, "</body>")) |pos| {
        // Use static buffer for modified body
        var buf: [65536]u8 = undefined;
        const new_len = pos + live_reload_script.len + (body.len - pos);

        if (new_len <= buf.len) {
            @memcpy(buf[0..pos], body[0..pos]);
            @memcpy(buf[pos..][0..live_reload_script.len], live_reload_script);
            @memcpy(buf[pos + live_reload_script.len ..][0 .. body.len - pos], body[pos..]);

            ctx.response.body = buf[0..new_len];
        }
    }
}

/// Simple ready-check endpoint for reconnect after server restart
pub fn readyHandler(ctx: *Context) !void {
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("ok");
}

/// SSE endpoint — holds connection open, sends "reload" event on file changes
pub fn eventsHandler(ctx: *Context) !void {
    const stream = ctx.stream orelse return;

    // Send SSE headers directly
    const header = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";
    _ = stream.write(header) catch return;
    ctx.response.headers_sent = true;

    // Initialize mtimes on first connection
    if (!mtime_initialized) {
        latest_tpl_mtime = getLatestTemplateMtime();
        latest_asset_mtime = getLatestAssetMtime();
        latest_input_mtime = getLatestInputMtime();
        mtime_initialized = true;
    }

    // Poll fd to detect client disconnect (peer close → POLLHUP/POLLIN)
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    // Keep connection open, check for changes every 200ms
    while (true) {
        // Use poll instead of sleep — detects closed connections immediately
        const poll_result = std.posix.poll(&poll_fds, 200) catch return;
        if (poll_result > 0) {
            // Client sent data or disconnected — either way, we're done
            return;
        }

        const current_tpl_mtime = getLatestTemplateMtime();
        const current_asset_mtime = getLatestAssetMtime();
        const current_input_mtime = getLatestInputMtime();

        if (current_tpl_mtime != latest_tpl_mtime) {
            latest_tpl_mtime = current_tpl_mtime;
            latest_asset_mtime = current_asset_mtime;
            latest_input_mtime = current_input_mtime;
            _ = stream.write("event: reload\ndata: changed\n\n") catch return;
        } else if (current_input_mtime != latest_input_mtime) {
            // Source file changed (e.g. input.css) — run build command then check output
            latest_input_mtime = current_input_mtime;
            runWatcherCommands();
            latest_asset_mtime = getLatestAssetMtime();
            _ = stream.write("event: css-reload\ndata: changed\n\n") catch return;
        } else if (current_asset_mtime != latest_asset_mtime) {
            latest_asset_mtime = current_asset_mtime;
            _ = stream.write("event: css-reload\ndata: changed\n\n") catch return;
        }
    }
}

/// Get the latest mtime from ZSX template files
fn getLatestTemplateMtime() i128 {
    return getDirLatestMtime("src/views");
}

/// Get the latest mtime from static assets (output CSS, JS, images)
fn getLatestAssetMtime() i128 {
    var max_mtime: i128 = 0;
    max_mtime = @max(max_mtime, getFileMtime("static/admin.css"));
    max_mtime = @max(max_mtime, getFileMtime("themes/demo/static/theme.css"));
    return max_mtime;
}

/// Get the latest mtime from watcher input files (e.g. input.css)
fn getLatestInputMtime() i128 {
    var max_mtime: i128 = 0;
    if (@hasField(@TypeOf(publr_config), "dev")) {
        if (@hasField(@TypeOf(publr_config.dev), "watchers")) {
            inline for (publr_config.dev.watchers) |watcher| {
                if (@hasField(@TypeOf(watcher), "input")) {
                    max_mtime = @max(max_mtime, getFileMtime(watcher.input));
                }
            }
        }
    }
    return max_mtime;
}

/// Run all watcher commands from publr.zon (e.g. Tailwind rebuild)
fn runWatcherCommands() void {
    if (!@hasField(@TypeOf(publr_config), "dev")) return;
    if (!@hasField(@TypeOf(publr_config.dev), "watchers")) return;

    inline for (publr_config.dev.watchers) |watcher| {
        if (@hasField(@TypeOf(watcher), "input")) {
            const cmd = watcher.cmd;
            const argv: [cmd.len][]const u8 = cmd;
            var child = std.process.Child.init(&argv, std.heap.page_allocator);
            _ = child.spawnAndWait() catch |err| {
                std.debug.print("Watcher command failed: {}\n", .{err});
                return;
            };
        }
    }
}

fn getFileMtime(path: []const u8) i128 {
    const stat = std.fs.cwd().statFile(path) catch return 0;
    return stat.mtime;
}

fn getDirLatestMtime(path: []const u8) i128 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var max_mtime: i128 = 0;
    var walker = dir.walk(std.heap.page_allocator) catch return 0;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zsx")) {
            const stat = entry.dir.statFile(entry.basename) catch continue;
            max_mtime = @max(max_mtime, stat.mtime);
        }
    }

    return max_mtime;
}
