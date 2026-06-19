const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const primitives = @import("../objects/primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyIntObject = primitives.PyIntObject;
const PyStringObject = primitives.PyStringObject;
const PyBuiltinFunctionObject = @import("../objects/function.zig").PyBuiltinFunctionObject;
const collections = @import("../objects/collections.zig");
const PyListObject = collections.PyListObject;
const PyTupleObject = collections.PyTupleObject;
const PyDictObject = collections.PyDictObject;

pub const PyTypeWrapper = extern struct {
    base: PyObject,
    type_ptr: *const PyTypeObject,
    
    pub fn create(type_ptr: *const PyTypeObject, mm: *PyMemoryManager) !*PyTypeWrapper {
        const obj = try mm.alloc(PyTypeWrapper);
        obj.* = .{
            .base = PyObject.init(&PyTypeWrapper_Type),
            .type_ptr = type_ptr,
        };
        return obj;
    }
};

pub const PyTypeWrapper_Type = PyTypeObject{
    .name = "type",
    .tp_dealloc = type_wrapper_dealloc,
    .tp_repr = type_wrapper_repr,
    .tp_str = type_wrapper_repr,
};

fn type_wrapper_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyTypeWrapper);
    mm.free(PyTypeWrapper, obj);
}

fn type_wrapper_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyTypeWrapper);
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "<class '{s}'>", .{obj.type_ptr.name}) catch "<class>";
    return try PyStringObject.create(name, mm);
}

// len(x)
pub fn builtinLen(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    var size: usize = 0;
    if (std.mem.eql(u8, obj.type_obj.name, "list")) {
        size = obj.as(PyListObject).size;
    } else if (std.mem.eql(u8, obj.type_obj.name, "tuple")) {
        size = obj.as(PyTupleObject).size;
    } else if (std.mem.eql(u8, obj.type_obj.name, "dict")) {
        size = obj.as(PyDictObject).active_count;
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        size = obj.as(PyStringObject).len;
    } else {
        return error.TypeError;
    }
    return try PyIntObject.create(@intCast(size), vm.mm);
}

// type(x)
pub fn builtinType(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (std.mem.eql(u8, obj.type_obj.name, "object")) {
        const inst = obj.as(@import("../objects/class.zig").PyInstanceObject);
        inst.class_obj.base.incRef();
        return &inst.class_obj.base;
    }
    const wrapper = try PyTypeWrapper.create(obj.type_obj, vm.mm);
    return &wrapper.base;
}

// range(stop) or range(start, stop)
pub fn builtinRange(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    var start: i64 = 0;
    var stop: i64 = 0;
    if (args.len == 1) {
        if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
        stop = args[0].as(PyIntObject).value;
    } else {
        if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
        if (!std.mem.eql(u8, args[1].type_obj.name, "int")) return error.TypeError;
        start = args[0].as(PyIntObject).value;
        stop = args[1].as(PyIntObject).value;
    }
    
    const count: usize = if (stop > start) @intCast(stop - start) else 0;
    const list = try PyListObject.create(count, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    var val = start;
    while (val < stop) : (val += 1) {
        const int_obj = try PyIntObject.create(val, vm.mm);
        try list.append(int_obj, vm.mm);
        int_obj.decRef(vm.mm);
    }
    return &list.base;
}

// str(x)
pub fn builtinStr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj.tp_str) |str_fn| {
        return try str_fn(obj, vm.mm);
    } else if (obj.type_obj.tp_repr) |repr_fn| {
        return try repr_fn(obj, vm.mm);
    }
    return try PyStringObject.create(obj.type_obj.name, vm.mm);
}

// print(*args) — writes to VM's stdout writer
pub fn builtinPrint(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    
    for (args, 0..) |obj, i| {
        if (i > 0) try vm.stdout_writer.print(" ", .{});
        var str_obj: *PyObject = undefined;
        if (obj.type_obj.tp_str) |str_fn| {
            str_obj = try str_fn(obj, vm.mm);
        } else if (obj.type_obj.tp_repr) |repr_fn| {
            str_obj = try repr_fn(obj, vm.mm);
        } else {
            str_obj = try PyStringObject.create(obj.type_obj.name, vm.mm);
        }
        defer str_obj.decRef(vm.mm);
        try vm.stdout_writer.print("{s}", .{str_obj.as(PyStringObject).value()});
    }
    try vm.stdout_writer.print("\n", .{});
    
    PyNone.incRef();
    return PyNone;
}

// int(x)
pub fn builtinInt(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        obj.incRef();
        return obj;
    } else if (std.mem.eql(u8, obj.type_obj.name, "float")) {
        const val: i64 = @intFromFloat(obj.as(@import("../objects/primitives.zig").PyFloatObject).value);
        return try PyIntObject.create(val, vm.mm);
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(PyStringObject).value();
        const val = std.fmt.parseInt(i64, s, 10) catch return error.ValueError;
        return try PyIntObject.create(val, vm.mm);
    } else if (std.mem.eql(u8, obj.type_obj.name, "bool")) {
        const bval = obj == PyTrue;
        return try PyIntObject.create(if (bval) 1 else 0, vm.mm);
    }
    return error.TypeError;
}

// float(x)
pub fn builtinFloat(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const primitives_mod = @import("../objects/primitives.zig");
    if (std.mem.eql(u8, obj.type_obj.name, "float")) {
        obj.incRef();
        return obj;
    } else if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        const val: f64 = @floatFromInt(obj.as(PyIntObject).value);
        return try primitives_mod.PyFloatObject.create(val, vm.mm);
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(PyStringObject).value();
        const val = std.fmt.parseFloat(f64, s) catch return error.ValueError;
        return try primitives_mod.PyFloatObject.create(val, vm.mm);
    }
    return error.TypeError;
}

// bool(x)
pub fn builtinBool(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    _ = vm_opaque;
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    // Simple truthiness
    if (obj == PyTrue or obj == PyFalse) {
        obj.incRef();
        return obj;
    }
    if (obj == PyNone) {
        PyFalse.incRef();
        return PyFalse;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        const v = obj.as(PyIntObject).value;
        const res = if (v != 0) PyTrue else PyFalse;
        res.incRef();
        return res;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(PyStringObject).value();
        const res = if (s.len > 0) PyTrue else PyFalse;
        res.incRef();
        return res;
    }
    PyTrue.incRef();
    return PyTrue;
}

// abs(x)
pub fn builtinAbs(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        const v = obj.as(PyIntObject).value;
        return try PyIntObject.create(if (v < 0) -v else v, vm.mm);
    }
    const primitives_mod = @import("../objects/primitives.zig");
    if (std.mem.eql(u8, obj.type_obj.name, "float")) {
        const v = obj.as(primitives_mod.PyFloatObject).value;
        return try primitives_mod.PyFloatObject.create(if (v < 0) -v else v, vm.mm);
    }
    return error.TypeError;
}

// max(*args) or max(iterable)
pub fn builtinMax(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) return error.TypeError;
    // If single list argument, treat elements as args
    if (args.len == 1 and std.mem.eql(u8, args[0].type_obj.name, "list")) {
        const lst = args[0].as(PyListObject);
        if (lst.size == 0) return error.ValueError;
        var best = lst.items.?[0];
        for (lst.items.?[1..lst.size]) |item| {
            if (item.type_obj.tp_richcompare) |cmp| {
                const gt = try cmp(item, best, .Gt, vm.mm);
                const is_gt = gt == PyTrue;
                gt.decRef(vm.mm);
                if (is_gt) best = item;
            }
        }
        best.incRef();
        return best;
    }
    var best = args[0];
    for (args[1..]) |item| {
        if (item.type_obj.tp_richcompare) |cmp| {
            const gt = try cmp(item, best, .Gt, vm.mm);
            const is_gt = gt == PyTrue;
            gt.decRef(vm.mm);
            if (is_gt) best = item;
        }
    }
    best.incRef();
    return best;
}

// min(*args) or min(iterable)
pub fn builtinMin(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) return error.TypeError;
    if (args.len == 1 and std.mem.eql(u8, args[0].type_obj.name, "list")) {
        const lst = args[0].as(PyListObject);
        if (lst.size == 0) return error.ValueError;
        var best = lst.items.?[0];
        for (lst.items.?[1..lst.size]) |item| {
            if (item.type_obj.tp_richcompare) |cmp| {
                const lt = try cmp(item, best, .Lt, vm.mm);
                const is_lt = lt == PyTrue;
                lt.decRef(vm.mm);
                if (is_lt) best = item;
            }
        }
        best.incRef();
        return best;
    }
    var best = args[0];
    for (args[1..]) |item| {
        if (item.type_obj.tp_richcompare) |cmp| {
            const lt = try cmp(item, best, .Lt, vm.mm);
            const is_lt = lt == PyTrue;
            lt.decRef(vm.mm);
            if (is_lt) best = item;
        }
    }
    best.incRef();
    return best;
}

// sum(iterable)
pub fn builtinSum(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1) return error.TypeError;
    const iterable = args[0];
    if (!std.mem.eql(u8, iterable.type_obj.name, "list")) return error.TypeError;
    const lst = iterable.as(PyListObject);
    var total: i64 = 0;
    if (args.len >= 2 and std.mem.eql(u8, args[1].type_obj.name, "int")) {
        total = args[1].as(PyIntObject).value;
    }
    for (lst.items.?[0..lst.size]) |item| {
        if (!std.mem.eql(u8, item.type_obj.name, "int")) return error.TypeError;
        total += item.as(PyIntObject).value;
    }
    return try PyIntObject.create(total, vm.mm);
}

// list(iterable) -> list
pub fn builtinList(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const lst = try PyListObject.create(0, vm.mm);
        return &lst.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (std.mem.eql(u8, obj.type_obj.name, "list")) {
        obj.incRef();
        return obj;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "tuple")) {
        const tup = obj.as(PyTupleObject);
        const lst = try PyListObject.create(tup.size, vm.mm);
        const tup_items = tup.items();
        for (tup_items[0..tup.size], 0..) |item, i| {
            item.incRef();
            lst.items.?[i] = item;
        }
        lst.size = tup.size;
        return &lst.base;
    }
    return error.TypeError;
}

// tuple(iterable) -> tuple
pub fn builtinTuple(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const tup = try PyTupleObject.create(0, vm.mm);
        return &tup.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    if (std.mem.eql(u8, obj.type_obj.name, "tuple")) {
        obj.incRef();
        return obj;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "list")) {
        const lst = obj.as(PyListObject);
        const tup = try PyTupleObject.create(lst.size, vm.mm);
        const tup_items = tup.items();
        for (lst.items.?[0..lst.size], 0..) |item, i| {
            item.incRef();
            PyNone.decRef(vm.mm);
            tup_items[i] = item;
        }
        return &tup.base;
    }
    return error.TypeError;
}

// dict() -> empty dict
pub fn builtinDict(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = args;
    const d = try PyDictObject.create(vm.mm);
    return &d.base;
}

