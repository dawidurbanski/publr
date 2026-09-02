const std = @import("std");
const import = @import("vendor/import.zig");
const cache_check = @import("vendor/cache_check.zig");

const args_max: u32 = 64;

pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var storage: [args_max][]const u8 = undefined;
    var count: u32 = 0;

    _ = iterator.next();

    while (iterator.next()) |arg| : (count += 1) {
        if (count == args_max) {
            return error.TooManyArguments;
        }

        storage[count] = arg;
    }

    std.debug.assert(count <= args_max);

    if (count == 0) {
        return usage();
    }

    const command = storage[0];
    const rest = storage[1..count];

    std.debug.assert(rest.len < count);

    if (std.mem.eql(u8, command, "import")) {
        return import.run(init, rest);
    }

    if (std.mem.eql(u8, command, "cache-check")) {
        return cache_check.run(init, rest);
    }

    return usage();
}

fn usage() u8 {
    const text = "vendor: usage: vendor import <archive> <target> <name> <version> <upstream> " ++
        "<keep...> | vendor cache-check <zig> <build-root>\n";

    std.debug.assert(args_max > 0);
    std.debug.assert(text.len > 0);
    std.debug.print(text, .{});

    return 2;
}

test {
    std.testing.refAllDecls(@This());
    _ = import;
    _ = cache_check;
}
