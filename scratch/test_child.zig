const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var io = try std.Io.init(allocator);
    defer io.deinit();

    const argv = [_][]const u8{ "/bin/sh", "-c", "echo hello from child" };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
    });
    const term = try child.wait(io);
    const exit_code = switch (term) {
        .exited => |code| code,
        else => 255,
    };
    std.debug.print("Exit code: {d}\n", .{exit_code});
}
