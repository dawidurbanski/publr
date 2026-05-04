const std = @import("std");
const router_mod = @import("router");
const Context = router_mod.Context;
const NextFn = router_mod.NextFn;
const publr_config = @import("publr_config");

/// Live reload script using Server-Sent Events.
/// Single persistent connection — no polling noise in network tab.
/// Shows a floating indicator during rebuilds, auto-refreshes when server restarts.
const live_reload_script =
    \\<script>
    \\(function(){
    \\  var ind;
    \\  function show(){
    \\    if(ind) return;
    \\    ind=document.createElement('div');
    \\    ind.textContent='Rebuilding\u2026';
    \\    ind.style.cssText='position:fixed;bottom:16px;left:50%;transform:translateX(-50%);z-index:99999;'
    \\      +'padding:6px 14px;background:rgba(0,0,0,.82);color:#fff;'
    \\      +'border-radius:99px;font:500 13px/1 system-ui,sans-serif;'
    \\      +'pointer-events:none;animation:__dr .8s ease-in-out infinite alternate';
    \\    var s=document.createElement('style');
    \\    s.textContent='@keyframes __dr{from{opacity:1}to{opacity:.5}}';
    \\    document.head.appendChild(s);
    \\    document.body.appendChild(ind);
    \\  }
    \\  var es=new EventSource('/__dev/events');
    \\  es.addEventListener('rebuilding',show);
    \\  es.addEventListener('css-reload',function(){
    \\    document.querySelectorAll('link[rel="stylesheet"]').forEach(function(l){
    \\      var h=l.href.replace(/(\?|&)_t=\d+/,'');
    \\      l.href=h+(h.indexOf('?')>-1?'&':'?')+'_t='+Date.now();
    \\    });
    \\  });
    \\  window.addEventListener('beforeunload',function(){es.close()});
    \\  es.onerror=function(){
    \\    es.close(); show();
    \\    var d=200;
    \\    (function poll(){
    \\      fetch('/__dev/ready').then(function(r){
    \\        if(r.ok)location.reload();
    \\        else{d=Math.min(d*1.5,2000);setTimeout(poll,d)}
    \\      }).catch(function(){d=Math.min(d*1.5,2000);setTimeout(poll,d)});
    \\    })();
    \\  };
    \\})();
    \\</script>
;

/// Track mtimes separately: source changes trigger rebuild indicator, assets swap in-place
var latest_src_mtime: i128 = 0;
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

/// SSE endpoint — holds connection open, sends events on file changes
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
        latest_src_mtime = getLatestSourceMtime();
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

        const current_src_mtime = getLatestSourceMtime();
        const current_asset_mtime = getLatestAssetMtime();
        const current_input_mtime = getLatestInputMtime();

        if (current_src_mtime != latest_src_mtime) {
            latest_src_mtime = current_src_mtime;
            latest_asset_mtime = current_asset_mtime;
            latest_input_mtime = current_input_mtime;
            _ = stream.write("event: rebuilding\ndata: changed\n\n") catch return;
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

/// Get the latest mtime from source files (.zig/.zsx in src/, plus
/// .zon/.publr/.zsx in themes/). Mirrors the watchexec watchers in main.zig
/// so the SSE `rebuilding` event fires the moment a trigger file changes —
/// not at the end when the server binary is swapped in.
fn getLatestSourceMtime() i128 {
    var max_mtime: i128 = 0;

    // src/ — .zig and .zsx, skipping the generated tree
    if (std.fs.cwd().openDir("src", .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var walker = dir.walk(std.heap.page_allocator) catch return max_mtime;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.path, "gen/")) continue;
            if (std.mem.endsWith(u8, entry.basename, ".zig") or
                std.mem.endsWith(u8, entry.basename, ".zsx"))
            {
                const stat = entry.dir.statFile(entry.basename) catch continue;
                max_mtime = @max(max_mtime, stat.mtime);
            }
        }
    } else |_| {}

    // themes/ — .zon (theme.zon, publr.zon), .publr (templates), .zsx
    // (theme components). Match the watchexec theme-watcher's ignore set:
    // skip per-theme public/ and src/ subtrees.
    if (std.fs.cwd().openDir("themes", .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var walker = dir.walk(std.heap.page_allocator) catch return max_mtime;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            // Mirror the `-i themes/*/public/**` and `-i themes/*/src/**`
            // ignore patterns from the theme watcher in main.zig.
            if (std.mem.indexOf(u8, entry.path, "/public/") != null) continue;
            if (std.mem.indexOf(u8, entry.path, "/src/") != null) continue;
            const is_trigger = std.mem.endsWith(u8, entry.basename, ".zon") or
                std.mem.endsWith(u8, entry.basename, ".publr") or
                std.mem.endsWith(u8, entry.basename, ".zsx");
            if (!is_trigger) continue;
            const stat = entry.dir.statFile(entry.basename) catch continue;
            max_mtime = @max(max_mtime, stat.mtime);
        }
    } else |_| {}

    return max_mtime;
}

/// Get the latest mtime from static assets (output CSS, JS, images)
fn getLatestAssetMtime() i128 {
    var max_mtime: i128 = 0;
    max_mtime = @max(max_mtime, getFileMtime("static/admin.css"));
    const theme_css_path = if (@hasField(@TypeOf(publr_config), "theme"))
        "themes/" ++ publr_config.theme ++ "/public/theme.css"
    else
        "themes/default/static/theme.css";
    max_mtime = @max(max_mtime, getFileMtime(theme_css_path));
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
