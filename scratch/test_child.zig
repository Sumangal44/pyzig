const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const argv = [_][]const u8{ "/bin/sh", "-c", "echo hello from child" };
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
    });
    const term = try child.wait(init.io);
    const exit_code = switch (term) {
        .exited => |code| code,
        else => 255,
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("Exit code: {d}\n", .{exit_code});
    try stdout_file_writer.flush();
}
