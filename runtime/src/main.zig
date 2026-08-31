const std = @import("std");
const seam = @import("seam.zig");

pub fn main() !void {
    var allocator_state = std.heap.DebugAllocator(.{}){};
    defer _ = allocator_state.deinit();
    const allocator = allocator_state.allocator();

    std.debug.print(
        "dsh-zig-runtime 0.1.0 (runtime core skeleton)\n" ++
            "  seam: HostModuleLoader is the ONLY plugin import seam.\n" ++
            "  nodes: quickjs-ng engine lands in M-2; this stub type-checks without it.\n",
        .{});
    _ = allocator;
}

test {
    _ = seam;
}
