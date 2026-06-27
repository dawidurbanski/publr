const std = @import("std");
const router_mod = @import("router");
const Context = router_mod.Context;
const NextFn = router_mod.NextFn;

/// HMR live-reload client — ported from
/// `demos/zsx-hmr-runtime-jit-poc/src/client.js`. Subscribes to
/// `/__hmr/ws` (served by `hmr_ws.handleHmrWs`) and consumes:
///   * `{name, html}`                — fast-path innerHTML swap.
///   * `{control: "rebuild", names}` — queue refetches, show pill.
///   * `{control: "ready"}`          — process queued refetches.
///   * `{control: "reload"}`         — full page reload.
///   * `{control: "css"}`            — bump `?_t=` on every
///                                     `<link rel="stylesheet">`
///                                     (CMS divergence from the POC,
///                                     which swaps a `<style>` block).
/// Falls back to `/__dev/ready` polling after a WS disconnect so a
/// restart that drops the WS triggers a reload.
const live_reload_script =
    \\<script>
    \\(function(){
    \\  var pending_refetch = [];
    \\  var in_flight = new Set();
    \\  function ensurePillStyles(){
    \\    if(document.querySelector('[data-hmr-style]')) return;
    \\    var s=document.createElement('style');
    \\    s.dataset.hmrStyle='';
    \\    s.textContent='@keyframes hmr-spin{to{transform:rotate(360deg)}}';
    \\    document.head.appendChild(s);
    \\  }
    \\  function showPill(label){
    \\    ensurePillStyles();
    \\    var pill=document.querySelector('[data-hmr-pill]');
    \\    if(!pill){
    \\      pill=document.createElement('div');
    \\      pill.dataset.hmrPill='';
    \\      pill.style.cssText='position:fixed;bottom:16px;right:16px;background:#ffd400;color:#000;padding:8px 14px 8px 12px;border-radius:999px;font:600 13px/1 -apple-system,system-ui,sans-serif;display:flex;align-items:center;gap:8px;z-index:100000;box-shadow:0 4px 12px rgba(0,0,0,0.2)';
    \\      document.body.appendChild(pill);
    \\    }
    \\    pill.innerHTML='<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="animation:hmr-spin 800ms linear infinite"><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v6h-6"/></svg>'+label;
    \\  }
    \\  function hidePill(){
    \\    var pill=document.querySelector('[data-hmr-pill]');
    \\    if(pill) pill.remove();
    \\  }
    \\  function showOverlay(name){
    \\    var node=document.querySelector('[data-component="'+name+'"]');
    \\    if(!node) return;
    \\    var ov=document.querySelector('[data-hmr-overlay="'+name+'"]');
    \\    var rect=node.getBoundingClientRect();
    \\    if(!ov){
    \\      ov=document.createElement('div');
    \\      ov.dataset.hmrOverlay=name;
    \\      ov.style.cssText='position:fixed;background:#ffd400;pointer-events:none;z-index:99999';
    \\      document.body.appendChild(ov);
    \\    }
    \\    ov.style.top=rect.top+'px';
    \\    ov.style.left=rect.left+'px';
    \\    ov.style.width=rect.width+'px';
    \\    ov.style.height=rect.height+'px';
    \\    ov.style.opacity='0.2';
    \\  }
    \\  function hideOverlay(name){
    \\    var ov=document.querySelector('[data-hmr-overlay="'+name+'"]');
    \\    if(ov) ov.remove();
    \\  }
    \\  function clearInFlight(name){
    \\    in_flight.delete(name);
    \\    if(in_flight.size===0) hidePill();
    \\  }
    \\  function reinit(node){
    \\    // 1) Re-wire interact-runtime components (data-publr-component /
    \\    //    data-widget). init() is idempotent (guards via _publrInit), so
    \\    //    it only touches the freshly swapped-in nodes.
    \\    try{ if(window.__publrReinit) window.__publrReinit(); }
    \\    catch(e){ console.warn('[hmr] reinit failed',e); }
    \\    // 2) Re-execute INLINE <script> blocks inside the swapped subtree.
    \\    //    Scripts inserted via innerHTML never run, so any component that
    \\    //    wires itself with an inline IIFE (e.g. the admin sidebar toggle)
    \\    //    would otherwise lose its handlers. We skip scripts with `src`:
    \\    //    module scripts are already loaded (re-adding is a no-op) and
    \\    //    external scripts would re-bind document-level listeners.
    \\    try{
    \\      if(node) node.querySelectorAll('script:not([src])').forEach(function(old){
    \\        var s=document.createElement('script');
    \\        if(old.type) s.type=old.type;
    \\        s.textContent=old.textContent;
    \\        old.parentNode.replaceChild(s, old);
    \\      });
    \\    }catch(e){ console.warn('[hmr] inline-script re-exec failed',e); }
    \\  }
    \\  function bumpStylesheets(){
    \\    document.querySelectorAll('link[rel="stylesheet"]').forEach(function(l){
    \\      var h=l.href.replace(/(\?|&)_t=\d+/,'');
    \\      l.href=h+(h.indexOf('?')>-1?'&':'?')+'_t='+Date.now();
    \\    });
    \\  }
    \\  function refetch(name){
    \\    fetch('/__hmr/render?name='+encodeURIComponent(name)).then(function(r){
    \\      if(!r.ok){
    \\        console.warn('[hmr] refetch',name,'->',r.status);
    \\        if(r.status===503){ location.reload(); return; }
    \\        hideOverlay(name); clearInFlight(name); return;
    \\      }
    \\      return r.text().then(function(html){
    \\        var node=document.querySelector('[data-component="'+name+'"]');
    \\        if(node){ node.innerHTML=html; reinit(node); }
    \\        else console.warn('[hmr] no DOM target for',name);
    \\        hideOverlay(name); clearInFlight(name);
    \\        console.log('[hmr] post-rebuild swap',name);
    \\      });
    \\    }).catch(function(e){
    \\      console.warn('[hmr] refetch failed for',name,e);
    \\      hideOverlay(name); clearInFlight(name);
    \\    });
    \\  }
    \\  function processPending(reason){
    \\    if(pending_refetch.length===0) return;
    \\    var names=pending_refetch; pending_refetch=[];
    \\    console.log('[hmr] '+reason+', refetching:',names.join(', '));
    \\    names.forEach(refetch);
    \\  }
    \\  function pollReady(){
    \\    var d=200;
    \\    (function poll(){
    \\      fetch('/__dev/ready').then(function(r){
    \\        if(r.ok){ if(pending_refetch.length>0) processPending('server ready (post-restart)'); else location.reload(); }
    \\        else{ d=Math.min(d*1.5,2000); setTimeout(poll,d); }
    \\      }).catch(function(){ d=Math.min(d*1.5,2000); setTimeout(poll,d); });
    \\    })();
    \\  }
    \\  function connect(){
    \\    var proto=location.protocol==='https:'?'wss:':'ws:';
    \\    var ws=new WebSocket(proto+'//'+location.host+'/__hmr/ws');
    \\    ws.addEventListener('open',function(){
    \\      console.log('[hmr] ws open');
    \\      hidePill();
    \\      processPending('ws reopened');
    \\    });
    \\    ws.addEventListener('message',function(ev){
    \\      var payload;
    \\      try{ payload=JSON.parse(ev.data); }catch(e){ console.warn('[hmr] bad payload',ev.data); return; }
    \\      if(payload.control==='reload'){ console.log('[hmr] full reload requested'); location.reload(); return; }
    \\      if(payload.control==='rebuild'){
    \\        var names=Array.isArray(payload.names)?payload.names:[];
    \\        pending_refetch=names.slice();
    \\        names.forEach(function(n){ in_flight.add(n); });
    \\        names.forEach(showOverlay);
    \\        showPill('Rebuilding');
    \\        console.log('[hmr] rebuilding:',names.join(', '));
    \\        return;
    \\      }
    \\      if(payload.control==='ready'){ processPending('server ready (no disconnect)'); return; }
    \\      if(payload.control==='css'){
    \\        bumpStylesheets();
    \\        in_flight.add('__css__');
    \\        showPill('Styles');
    \\        setTimeout(function(){ clearInFlight('__css__'); },300);
    \\        return;
    \\      }
    \\      var name=payload.name;
    \\      if(!name) return;
    \\      in_flight.add(name);
    \\      showPill('Hot swap');
    \\      showOverlay(name);
    \\      var nodes=document.querySelectorAll('[data-component="'+name+'"]');
    \\      if(!nodes.length){ console.warn('[hmr] no DOM target for',name); hideOverlay(name); clearInFlight(name); return; }
    \\      var after=payload.html;
    \\      nodes.forEach(function(n){ n.innerHTML=after; reinit(n); });
    \\      hideOverlay(name); clearInFlight(name);
    \\      console.log('[hmr] swapped '+name);
    \\    });
    \\    ws.addEventListener('close',function(){
    \\      console.warn('[hmr] ws closed, reconnecting in 200ms');
    \\      showPill('Rebuilding');
    \\      setTimeout(connect,200);
    \\      pollReady();
    \\    });
    \\    ws.addEventListener('error',function(){ console.warn('[hmr] ws error'); });
    \\  }
    \\  connect();
    \\  console.log('[hmr] client ready');
    \\})();
    \\</script>
;

/// Dev middleware that:
/// 1. Adds Cache-Control: no-store to prevent browser caching
/// 2. Injects live reload script into HTML responses
pub fn devMiddleware(ctx: *Context, next: NextFn) !void {
    try next(ctx);

    // Add no-cache header
    ctx.response.setHeader("Cache-Control", "no-store");

    // Inject live reload script into HTML responses. Skip silently on
    // allocation failure — losing live reload is preferable to crashing
    // the response.
    if (std.mem.eql(u8, ctx.response.content_type, "text/html")) {
        injectLiveReload(ctx) catch |err| {
            std.log.warn("[dev] live-reload inject failed: {s}", .{@errorName(err)});
        };
    }
}

fn injectLiveReload(ctx: *Context) !void {
    const body = ctx.response.body;

    // Need a `</body>` to splice before. Without one we can't inject,
    // which means no HMR client on that page — every admin route should
    // render through a layout that closes its body tag.
    const pos = std.mem.lastIndexOf(u8, body, "</body>") orelse return;

    // Allocate on the request arena so the buffer lives as long as the
    // response. Earlier versions used a 65 536-byte stack-local array
    // which both (a) silently dropped the script on pages over ~64 KB
    // (admin dashboard easily exceeds that with rendered data + the WS
    // client script) and (b) handed a dangling stack pointer back as
    // `ctx.response.body`. No cap, no UAF.
    const new_len = body.len + live_reload_script.len;
    const buf = try ctx.allocator.alloc(u8, new_len);

    @memcpy(buf[0..pos], body[0..pos]);
    @memcpy(buf[pos..][0..live_reload_script.len], live_reload_script);
    @memcpy(buf[pos + live_reload_script.len ..][0 .. body.len - pos], body[pos..]);

    ctx.response.body = buf;
}

/// Simple ready-check endpoint for reconnect after server restart.
/// The injected live-reload client polls this after a WS disconnect to
/// detect when the new binary's HTTP server is up; once it succeeds and
/// there are queued refetches from a prior `{control:"rebuild"}`, the
/// client drives `/__hmr/render` calls; otherwise it falls back to a
/// full page reload.
pub fn readyHandler(ctx: *Context) !void {
    ctx.response.setContentType("text/plain");
    ctx.response.setBody("ok");
}
