const std = @import("std");
const testing = std.testing;
const PyObject = @import("../objects/object.zig").PyObject;

pub const PyMemoryManager = struct {
    allocator: std.mem.Allocator,
    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    object_count: usize = 0,

    int_free_list: ?*anyopaque = null,
    float_free_list: ?*anyopaque = null,
    complex_free_list: ?*anyopaque = null,
    interned_strings: std.StringHashMap(*PyObject),

    pub fn init(allocator: std.mem.Allocator) PyMemoryManager {
        return .{
            .allocator = allocator,
            .interned_strings = std.StringHashMap(*PyObject).init(allocator),
        };
    }

    pub fn deinit(self: *PyMemoryManager) void {
        const primitives = @import("../objects/primitives.zig");
        
        var int_node = self.int_free_list;
        while (int_node) |node| {
            const next = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const ptr = @as(*primitives.PyIntObject, @ptrCast(@alignCast(node)));
            self.allocator.destroy(ptr);
            self.allocated_bytes -= @sizeOf(primitives.PyIntObject);
            int_node = next;
        }
        self.int_free_list = null;

        var float_node = self.float_free_list;
        while (float_node) |node| {
            const next = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const ptr = @as(*primitives.PyFloatObject, @ptrCast(@alignCast(node)));
            self.allocator.destroy(ptr);
            self.allocated_bytes -= @sizeOf(primitives.PyFloatObject);
            float_node = next;
        }
        self.float_free_list = null;

        var complex_node = self.complex_free_list;
        while (complex_node) |node| {
            const next = @as(*?*anyopaque, @ptrCast(@alignCast(node))).*;
            const ptr = @as(*primitives.PyComplexObject, @ptrCast(@alignCast(node)));
            self.allocator.destroy(ptr);
            self.allocated_bytes -= @sizeOf(primitives.PyComplexObject);
            complex_node = next;
        }
        self.complex_free_list = null;
        var it = self.interned_strings.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr.*.as(primitives.PyStringObject);
            const obj_len = obj.len;
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(@constCast(obj.ptr[0..obj_len]));
            self.allocator.destroy(obj);
            self.allocated_bytes -= @sizeOf(primitives.PyStringObject) + obj_len;
            self.object_count -= 2;
        }
        self.interned_strings.deinit();
    }

    pub fn internString(self: *PyMemoryManager, val: []const u8) !*PyObject {
        const primitives = @import("../objects/primitives.zig");
        if (self.interned_strings.get(val)) |existing| {
            return existing;
        }
        const copy = try self.allocator.alloc(u8, val.len);
        @memcpy(copy, val);
        const obj = try self.allocator.create(primitives.PyStringObject);
        obj.* = .{
            .base = .{
                .refcnt = 999999,
                .type_obj = &primitives.PyString_Type,
            },
            .ptr = copy.ptr,
            .len = copy.len,
            .hash = -1,
        };
        self.allocated_bytes += @sizeOf(primitives.PyStringObject) + val.len;
        self.object_count += 2;
        const key_copy = try self.allocator.dupe(u8, val);
        try self.interned_strings.put(key_copy, &obj.base);
        return &obj.base;
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
    defer mm.deinit();

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
