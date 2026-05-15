//! Stateless build-time helpers shared across build.zig and its sub-files.

const std = @import("std");

/// Attach a batch of named modules to a target module. Saves repetition when
/// a build target wires up many imports.
pub fn addImports(mod: *std.Build.Module, imports: []const std.Build.Module.Import) void {
    for (imports) |imp| mod.addImport(imp.name, imp.module);
}

/// Sanitize a file path into a valid Zig identifier for anonymous imports.
/// e.g. "fonts/poppins-400.woff2" → "_fonts_poppins_400_woff2"
pub fn sanitizeImportName(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const buf = allocator.alloc(u8, path.len + 1) catch @panic("OOM");
    buf[0] = '_';
    for (path, 0..) |c, i| {
        buf[i + 1] = if (std.ascii.isAlphanumeric(c)) c else '_';
    }
    return buf;
}

/// Two-pass module registry. Use `leaf(name, src)` for modules with no
/// imports, `simple(name, src, deps)` for modules whose deps are all named
/// modules in this registry, and `register(name, mod)` to add a module
/// created elsewhere (e.g., one needing addIncludePath or non-standard
/// options). Call `finalize()` after all modules are declared — it resolves
/// each pending module's named deps against the registry and wires the
/// `addImport` edges. Two-pass means dep names don't have to be declared
/// before the modules that reference them, so cycles and forward refs are
/// both fine.
pub const ModuleRegistry = struct {
    b: *std.Build,
    map: std.StringHashMap(*std.Build.Module),
    pending: std.ArrayList(Pending),

    const Pending = struct { mod: *std.Build.Module, deps: []const []const u8 };

    pub fn init(b: *std.Build) ModuleRegistry {
        return .{
            .b = b,
            .map = std.StringHashMap(*std.Build.Module).init(b.allocator),
            .pending = .empty,
        };
    }

    pub fn leaf(self: *ModuleRegistry, name: []const u8, src: []const u8) *std.Build.Module {
        const mod = self.b.createModule(.{ .root_source_file = self.b.path(src) });
        self.map.put(name, mod) catch @panic("OOM");
        return mod;
    }

    pub fn simple(self: *ModuleRegistry, name: []const u8, src: []const u8, deps: []const []const u8) *std.Build.Module {
        const mod = self.b.createModule(.{ .root_source_file = self.b.path(src) });
        self.map.put(name, mod) catch @panic("OOM");
        self.pending.append(self.b.allocator, .{ .mod = mod, .deps = deps }) catch @panic("OOM");
        return mod;
    }

    pub fn register(self: *ModuleRegistry, name: []const u8, mod: *std.Build.Module) void {
        self.map.put(name, mod) catch @panic("OOM");
    }

    pub fn get(self: *const ModuleRegistry, name: []const u8) *std.Build.Module {
        return self.map.get(name) orelse std.debug.panic("ModuleRegistry: unknown module '{s}'", .{name});
    }

    pub fn finalize(self: *ModuleRegistry) void {
        for (self.pending.items) |p| {
            for (p.deps) |dep_name| {
                p.mod.addImport(dep_name, self.get(dep_name));
            }
        }
    }

    /// Attach every named module in `names` to `mod`. Each name must be a
    /// module previously registered. Equivalent to calling
    /// `mod.addImport(name, reg.get(name))` in a loop.
    pub fn attachAll(self: *const ModuleRegistry, mod: *std.Build.Module, names: []const []const u8) void {
        for (names) |n| mod.addImport(n, self.get(n));
    }

    /// Build a `[]const Import` slice from named modules — for passing to
    /// helpers/external functions that take a list of imports.
    pub fn importsFor(self: *const ModuleRegistry, names: []const []const u8) []const std.Build.Module.Import {
        const out = self.b.allocator.alloc(std.Build.Module.Import, names.len) catch @panic("OOM");
        for (names, 0..) |n, i| out[i] = .{ .name = n, .module = self.get(n) };
        return out;
    }
};

/// Get MIME type from file path for build-time code generation.
pub fn getMimeForBuild(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".html", "text/html" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".webp", "image/webp" },
        .{ ".gif", "image/gif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".xml", "application/xml" },
        .{ ".txt", "text/plain" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}
