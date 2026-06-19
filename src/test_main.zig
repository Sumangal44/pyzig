const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    
    _ = args.skip();
    
    if (args.next()) |arg| {
        std.debug.print("First arg: {s}\n", .{arg});
    }
}
