const std = @import("std");
const testing = std.testing;

pub const PyMemoryManager = struct {
    allocator: std.mem.Allocator,
    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    object_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PyMemoryManager {
        return .{
            .allocator = allocator,
        };
    }

    pub fn alloc(self: *PyMemoryManager, comptime T: type) !*T {
        const ptr = try self.allocator.create(T);
        self.allocated_bytes += @sizeOf(T);
        if (self.allocated_bytes > self.peak_allocated_bytes) {
            self.peak_allocated_bytes = self.allocated_bytes;
        }
        self.object_count += 1;
        return ptr;
    }

    pub fn free(self: *PyMemoryManager, comptime T: type, ptr: *T) void {
        self.allocator.destroy(ptr);
        self.allocated_bytes -= @sizeOf(T);
        self.object_count -= 1;
    }

    pub fn allocBytes(self: *PyMemoryManager, size: usize) ![]u8 {
        const slice = try self.allocator.alloc(u8, size);
        self.allocated_bytes += size;
        if (self.allocated_bytes > self.peak_allocated_bytes) {
            self.peak_allocated_bytes = self.allocated_bytes;
        }
        self.object_count += 1;
        return slice;
    }

    pub fn freeBytes(self: *PyMemoryManager, slice: []u8) void {
        const size = slice.len;
        self.allocator.free(slice);
        self.allocated_bytes -= size;
        self.object_count -= 1;
    }
};

test "memory manager basics" {
    const allocator = testing.allocator;

    var mm = PyMemoryManager.init(allocator);

    const MyStruct = struct {
        x: i32,
        y: f64,
    };

    const ptr = try mm.alloc(MyStruct);
    ptr.x = 42;
    ptr.y = 3.14;

    try testing.expectEqual(@sizeOf(MyStruct), mm.allocated_bytes);
    try testing.expectEqual(1, mm.object_count);

    mm.free(MyStruct, ptr);
    try testing.expectEqual(0, mm.allocated_bytes);
    try testing.expectEqual(0, mm.object_count);
}
