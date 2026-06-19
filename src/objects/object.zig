const std = @import("std");
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;

pub const CompareOp = enum {
    Lt,
    Le,
    Eq,
    Ne,
    Gt,
    Ge,
};

pub const PyTypeObject = struct {
    name: []const u8,
    tp_dealloc: ?*const fn (self: *PyObject, mm: *PyMemoryManager) void = null,
    tp_repr: ?*const fn (self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_str: ?*const fn (self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_add: ?*const fn (self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_sub: ?*const fn (self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_mul: ?*const fn (self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_truediv: ?*const fn (self: *PyObject, other: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_richcompare: ?*const fn (self: *PyObject, other: *PyObject, op: CompareOp, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_hash: ?*const fn (self: *PyObject) anyerror!i64 = null,
    tp_call: ?*const fn (self: *PyObject, args: *PyObject, kwargs: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject = null,
    tp_bool: ?*const fn (self: *PyObject) bool = null,
};

pub const PyObject = extern struct {
    refcnt: usize,
    type_obj: *const PyTypeObject,

    pub fn init(type_obj: *const PyTypeObject) PyObject {
        return .{
            .refcnt = 1,
            .type_obj = type_obj,
        };
    }

    pub fn incRef(self: *PyObject) void {
        self.refcnt += 1;
    }

    pub fn decRef(self: *PyObject, mm: *PyMemoryManager) void {
        self.refcnt -= 1;
        if (self.refcnt == 0) {
            self.dealloc(mm);
        }
    }

    pub fn dealloc(self: *PyObject, mm: *PyMemoryManager) void {
        if (self.type_obj.tp_dealloc) |dealloc_fn| {
            dealloc_fn(self, mm);
        }
    }

    pub fn as(self: *PyObject, comptime T: type) *T {
        return @ptrCast(@alignCast(self));
    }
};
