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

fn toFloatVal(obj: *PyObject) anyerror!f64 {
    const primitives_mod = @import("../objects/primitives.zig");
    if (std.mem.eql(u8, obj.type_obj.name, "float")) {
        return obj.as(primitives_mod.PyFloatObject).value;
    } else if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        return @floatFromInt(obj.as(primitives_mod.PyIntObject).value);
    } else if (std.mem.eql(u8, obj.type_obj.name, "bool")) {
        return if (obj == primitives_mod.PyTrue) 1.0 else 0.0;
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(primitives_mod.PyStringObject).value();
        return std.fmt.parseFloat(f64, s) catch return error.ValueError;
    }
    return error.TypeError;
}

// complex([real[, imag]])
pub fn builtinComplex(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const primitives_mod = @import("../objects/primitives.zig");
    if (args.len == 0) {
        return try primitives_mod.PyComplexObject.create(0.0, 0.0, vm.mm);
    } else if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg.type_obj.name, "complex")) {
            arg.incRef();
            return arg;
        }
        const real_val = try toFloatVal(arg);
        return try primitives_mod.PyComplexObject.create(real_val, 0.0, vm.mm);
    } else if (args.len == 2) {
        const real_val = try toFloatVal(args[0]);
        const imag_val = try toFloatVal(args[1]);
        return try primitives_mod.PyComplexObject.create(real_val, imag_val, vm.mm);
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
fn iterateIterable(
    iterable: *PyObject,
    mm: *PyMemoryManager,
    context: *anyopaque,
    callback: *const fn (ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void,
) anyerror!void {
    const name = iterable.type_obj.name;
    if (std.mem.eql(u8, name, "list")) {
        const lst = iterable.as(PyListObject);
        if (lst.size > 0) {
            for (lst.items.?[0..lst.size]) |item| {
                try callback(context, item, mm);
            }
        }
    } else if (std.mem.eql(u8, name, "tuple")) {
        const tup = iterable.as(PyTupleObject);
        for (tup.items()) |item| {
            try callback(context, item, mm);
        }
    } else if (std.mem.eql(u8, name, "dict")) {
        const dict = iterable.as(PyDictObject);
        for (0..dict.indices_size) |i| {
            const entry_idx = dict.indices[i];
            if (entry_idx < 0) continue;
            const entry = &dict.entries[@intCast(entry_idx)];
            try callback(context, entry.key.?, mm);
        }
    } else if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "frozenset")) {
        const set_obj = iterable.as(collections.PySetObject);
        for (0..set_obj.indices_size) |i| {
            const entry_idx = set_obj.indices[i];
            if (entry_idx < 0) continue;
            const entry = &set_obj.entries[@intCast(entry_idx)];
            try callback(context, entry.key.?, mm);
        }
    } else if (std.mem.eql(u8, name, "str")) {
        const str_val = iterable.as(PyStringObject).value();
        for (str_val) |c| {
            const char_str = try PyStringObject.create(&[_]u8{c}, mm);
            errdefer char_str.decRef(mm);
            try callback(context, char_str, mm);
            char_str.decRef(mm);
        }
    } else if (std.mem.eql(u8, name, "bytes")) {
        const bytes_val = iterable.as(primitives.PyBytesObject).value();
        for (bytes_val) |b| {
            const int_obj = try PyIntObject.create(b, mm);
            errdefer int_obj.decRef(mm);
            try callback(context, int_obj, mm);
            int_obj.decRef(mm);
        }
    } else if (std.mem.eql(u8, name, "bytearray")) {
        const ba_val = iterable.as(primitives.PyByteArrayObject).value();
        for (ba_val) |b| {
            const int_obj = try PyIntObject.create(b, mm);
            errdefer int_obj.decRef(mm);
            try callback(context, int_obj, mm);
            int_obj.decRef(mm);
        }
    } else {
        return error.TypeError;
    }
}

fn listAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const lst: *PyListObject = @alignCast(@ptrCast(ctx));
    try lst.append(item, mm);
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
    const lst = try PyListObject.create(0, vm.mm);
    errdefer lst.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, lst, listAppendCallback);
    return &lst.base;
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
    const temp_lst = try PyListObject.create(0, vm.mm);
    defer temp_lst.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, temp_lst, listAppendCallback);
    
    const tup = try PyTupleObject.create(temp_lst.size, vm.mm);
    const slice = tup.items();
    for (temp_lst.items.?[0..temp_lst.size], 0..) |item, i| {
        item.incRef();
        PyNone.decRef(vm.mm);
        slice[i] = item;
    }
    return &tup.base;
}

fn setAddCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const set_obj: *collections.PySetObject = @alignCast(@ptrCast(ctx));
    try set_obj.add(item, mm);
}

// set(iterable) -> set
pub fn builtinSet(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const set_obj = try collections.PySetObject.create(vm.mm);
        return &set_obj.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const set_obj = try collections.PySetObject.create(vm.mm);
    errdefer set_obj.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, set_obj, setAddCallback);
    return &set_obj.base;
}

// frozenset(iterable) -> frozenset
pub fn builtinFrozenSet(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const set_obj = try collections.PySetObject.createFrozen(vm.mm);
        return &set_obj.base;
    }
    if (args.len != 1) return error.TypeError;
    const obj = args[0];
    const set_obj = try collections.PySetObject.createFrozen(vm.mm);
    errdefer set_obj.base.decRef(vm.mm);
    try iterateIterable(obj, vm.mm, set_obj, setAddCallback);
    return &set_obj.base;
}

fn bytesAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const list_bytes: *std.ArrayList(u8) = @alignCast(@ptrCast(ctx));
    if (!std.mem.eql(u8, item.type_obj.name, "int")) {
        return error.TypeError;
    }
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) {
        return error.ValueError;
    }
    try list_bytes.append(mm.allocator, @intCast(val));
}

// bytes() -> bytes
pub fn builtinBytes(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        return try primitives.PyBytesObject.create("", vm.mm);
    }
    if (args.len > 1) return error.TypeError;
    const obj = args[0];
    
    if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        const len_val = obj.as(PyIntObject).value;
        if (len_val < 0) return error.ValueError;
        const ulen: usize = @intCast(len_val);
        const buf = try vm.mm.allocator.alloc(u8, ulen);
        defer vm.mm.allocator.free(buf);
        @memset(buf, 0);
        return try primitives.PyBytesObject.create(buf, vm.mm);
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(PyStringObject).value();
        return try primitives.PyBytesObject.create(s, vm.mm);
    } else {
        var list_bytes = std.ArrayList(u8).empty;
        defer list_bytes.deinit(vm.mm.allocator);
        try iterateIterable(obj, vm.mm, &list_bytes, bytesAppendCallback);
        return try primitives.PyBytesObject.create(list_bytes.items, vm.mm);
    }
}

fn bytearrayAppendCallback(ctx: *anyopaque, item: *PyObject, mm: *PyMemoryManager) anyerror!void {
    const ba: *primitives.PyByteArrayObject = @alignCast(@ptrCast(ctx));
    if (!std.mem.eql(u8, item.type_obj.name, "int")) {
        return error.TypeError;
    }
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) {
        return error.ValueError;
    }
    try ba.append(@intCast(val), mm);
}

// bytearray() -> bytearray
pub fn builtinByteArray(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const ba = try primitives.PyByteArrayObject.create(0, vm.mm);
        return &ba.base;
    }
    if (args.len > 1) return error.TypeError;
    const obj = args[0];
    
    if (std.mem.eql(u8, obj.type_obj.name, "int")) {
        const len_val = obj.as(PyIntObject).value;
        if (len_val < 0) return error.ValueError;
        const ulen: usize = @intCast(len_val);
        const ba = try primitives.PyByteArrayObject.create(ulen, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        if (ulen > 0) {
            @memset(ba.items.?[0..ulen], 0);
            ba.size = ulen;
        }
        return &ba.base;
    } else if (std.mem.eql(u8, obj.type_obj.name, "str")) {
        const s = obj.as(PyStringObject).value();
        const ba = try primitives.PyByteArrayObject.create(s.len, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        if (s.len > 0) {
            @memcpy(ba.items.?[0..s.len], s);
            ba.size = s.len;
        }
        return &ba.base;
    } else {
        const ba = try primitives.PyByteArrayObject.create(0, vm.mm);
        errdefer ba.base.decRef(vm.mm);
        try iterateIterable(obj, vm.mm, ba, bytearrayAppendCallback);
        return &ba.base;
    }
}

// dict() -> empty dict
pub fn builtinDict(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = args;
    const d = try PyDictObject.create(vm.mm);
    return &d.base;
}


// input([prompt]) -> str
pub fn builtinInput(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len > 1) return error.TypeError;

    if (args.len == 1) {
        const prompt_obj = args[0];
        var str_obj: *PyObject = undefined;
        if (prompt_obj.type_obj.tp_str) |str_fn| {
            str_obj = try str_fn(prompt_obj, vm.mm);
        } else if (prompt_obj.type_obj.tp_repr) |repr_fn| {
            str_obj = try repr_fn(prompt_obj, vm.mm);
        } else {
            str_obj = try PyStringObject.create(prompt_obj.type_obj.name, vm.mm);
        }
        defer str_obj.decRef(vm.mm);
        try vm.stdout_writer.print("{s}", .{str_obj.as(PyStringObject).value()});
    }

    var line_writer = std.Io.Writer.Allocating.init(vm.allocator);
    defer line_writer.deinit();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), vm.io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    _ = stdin_reader.streamDelimiter(&line_writer.writer, '\n') catch |err| {
        if (err == error.EndOfStream) {
            // EOF
        } else return err;
    };

    const line = line_writer.written();
    const line_trimmed = std.mem.trim(u8, line, " \r\n");
    return try PyStringObject.create(line_trimmed, vm.mm);
}

fn isSubclass(a: *PyObject, b: *PyObject) bool {
    if (a == b) return true;
    if (std.mem.eql(u8, a.type_obj.name, "class_type")) {
        const cls_a = a.as(@import("../objects/class.zig").PyClassObject);
        if (cls_a.base_class) |base| {
            return isSubclass(base, b);
        }
    }
    return false;
}

fn checkIsinstance(obj: *PyObject, classinfo: *PyObject, vm: *anyopaque) anyerror!bool {
    const VM = @import("../vm/vm.zig").VM;
    const vm_ptr: *VM = @ptrCast(@alignCast(vm));
    if (std.mem.eql(u8, classinfo.type_obj.name, "tuple")) {
        const tup = classinfo.as(PyTupleObject);
        for (tup.items()) |item| {
            if (try checkIsinstance(obj, item, vm_ptr)) return true;
        }
        return false;
    }
    
    if (std.mem.eql(u8, classinfo.type_obj.name, "class_type")) {
        if (std.mem.eql(u8, obj.type_obj.name, "object")) {
            const inst = obj.as(@import("../objects/class.zig").PyInstanceObject);
            return isSubclass(&inst.class_obj.base, classinfo);
        }
        return false;
    } else if (std.mem.eql(u8, classinfo.type_obj.name, "type")) {
        const wrapper = classinfo.as(PyTypeWrapper);
        if (std.mem.eql(u8, wrapper.type_ptr.name, "object")) {
            return std.mem.eql(u8, obj.type_obj.name, "object");
        }
        if (std.mem.eql(u8, wrapper.type_ptr.name, "int") and std.mem.eql(u8, obj.type_obj.name, "bool")) {
            return true;
        }
        return std.mem.eql(u8, obj.type_obj.name, wrapper.type_ptr.name);
    } else if (std.mem.eql(u8, classinfo.type_obj.name, "builtin_function")) {
        const func = classinfo.as(PyBuiltinFunctionObject);
        if (std.mem.eql(u8, func.name, "int") and std.mem.eql(u8, obj.type_obj.name, "bool")) {
            return true;
        }
        return std.mem.eql(u8, func.name, obj.type_obj.name);
    } else {
        return error.TypeError;
    }
}

pub fn builtinIsinstance(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    if (args.len != 2) return error.TypeError;
    const obj = args[0];
    const classinfo = args[1];
    const result = try checkIsinstance(obj, classinfo, vm_opaque);
    const res = if (result) PyTrue else PyFalse;
    res.incRef();
    return res;
}

pub fn builtinHasattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    if (!std.mem.eql(u8, args[1].type_obj.name, "str")) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    
    const attr = vm.loadAttribute(obj, name) catch |err| {
        if (err == error.AttributeError or err == error.TypeError) {
            PyFalse.incRef();
            return PyFalse;
        }
        return err;
    };
    attr.decRef(vm.mm);
    PyTrue.incRef();
    return PyTrue;
}

pub fn builtinGetattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    if (!std.mem.eql(u8, args[1].type_obj.name, "str")) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    
    const attr = vm.loadAttribute(obj, name) catch |err| {
        if (err == error.AttributeError and args.len == 3) {
            args[2].incRef();
            return args[2];
        }
        return err;
    };
    return attr;
}

pub fn builtinSetattr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 3) return error.TypeError;
    if (!std.mem.eql(u8, args[1].type_obj.name, "str")) return error.TypeError;
    
    const obj = args[0];
    const name = args[1].as(PyStringObject).value();
    const val = args[2];
    
    try vm.storeAttribute(obj, name, val);
    PyNone.incRef();
    return PyNone;
}

pub fn builtinRepr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj.tp_repr) |repr_fn| {
        return try repr_fn(obj, vm.mm);
    } else if (obj.type_obj.tp_str) |str_fn| {
        return try str_fn(obj, vm.mm);
    }
    return try PyStringObject.create(obj.type_obj.name, vm.mm);
}

pub fn builtinId(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    return try PyIntObject.create(@intCast(@intFromPtr(args[0])), vm.mm);
}

pub fn builtinChr(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    if (val < 0 or val > 1114111) return error.ValueError;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(val), &buf) catch return error.ValueError;
    return try PyStringObject.create(buf[0..len], vm.mm);
}

pub fn builtinOrd(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (!std.mem.eql(u8, args[0].type_obj.name, "str")) return error.TypeError;
    const s = args[0].as(PyStringObject).value();
    if (s.len == 0) return error.TypeError;
    const cp = std.unicode.utf8Decode(s) catch return error.ValueError;
    const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch return error.ValueError;
    if (s.len != cp_len) return error.TypeError;
    return try PyIntObject.create(@intCast(cp), vm.mm);
}

pub fn builtinHex(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0x{x}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

pub fn builtinOct(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0o{o}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

pub fn builtinBin(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    if (!std.mem.eql(u8, args[0].type_obj.name, "int")) return error.TypeError;
    const val = args[0].as(PyIntObject).value;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0b{b}", .{val}) catch return error.ValueError;
    return try PyStringObject.create(s, vm.mm);
}

fn iterableToList(iterable: *PyObject, mm: *PyMemoryManager) anyerror!*PyListObject {
    const name = iterable.type_obj.name;
    if (std.mem.eql(u8, name, "list")) {
        const list = iterable.as(PyListObject);
        list.base.incRef();
        return list;
    } else if (std.mem.eql(u8, name, "tuple")) {
        const tup = iterable.as(PyTupleObject);
        const list = try PyListObject.create(tup.size, mm);
        const tup_items = tup.items();
        for (tup_items[0..tup.size], 0..) |item, i| {
            item.incRef();
            list.items.?[i] = item;
        }
        list.size = tup.size;
        return list;
    } else if (std.mem.eql(u8, name, "str")) {
        const str_val = iterable.as(PyStringObject).value();
        const list = try PyListObject.create(str_val.len, mm);
        for (str_val, 0..) |ch, i| {
            const ch_str = try PyStringObject.create(str_val[i..i+1], mm);
            _ = ch;
            list.items.?[i] = ch_str;
        }
        list.size = str_val.len;
        return list;
    } else if (std.mem.eql(u8, name, "dict")) {
        const dict = iterable.as(PyDictObject);
        const list = try PyListObject.create(dict.active_count, mm);
        var list_idx: usize = 0;
        for (0..dict.entries_size) |i| {
            if (dict.entries[i].key) |key| {
                key.incRef();
                list.items.?[list_idx] = key;
                list_idx += 1;
            }
        }
        list.size = list_idx;
        return list;
    } else {
        return error.TypeError;
    }
}

pub fn builtinEnumerate(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const iterable = args[0];
    var start: i64 = 0;
    if (args.len == 2) {
        if (!std.mem.eql(u8, args[1].type_obj.name, "int")) return error.TypeError;
        start = args[1].as(PyIntObject).value;
    }
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(list.size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const idx = try PyIntObject.create(start + @as(i64, @intCast(i)), vm.mm);
        defer idx.decRef(vm.mm);
        
        const item = list.items.?[i];
        
        const tuple = try PyTupleObject.create(2, vm.mm);
        const tup_items = tuple.items();
        
        tup_items[0].decRef(vm.mm);
        idx.incRef();
        tup_items[0] = idx;
        
        tup_items[1].decRef(vm.mm);
        item.incRef();
        tup_items[1] = item;
        
        try result_list.append(&tuple.base, vm.mm);
        tuple.base.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinZip(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len == 0) {
        const lst = try PyListObject.create(0, vm.mm);
        return &lst.base;
    }
    
    var lists = try vm.allocator.alloc(*PyListObject, args.len);
    defer vm.allocator.free(lists);
    for (args, 0..) |arg, i| {
        lists[i] = try iterableToList(arg, vm.mm);
    }
    defer {
        for (lists) |list| {
            list.base.decRef(vm.mm);
        }
    }
    
    var min_size: usize = lists[0].size;
    for (lists[1..]) |list| {
        if (list.size < min_size) min_size = list.size;
    }
    
    const result_list = try PyListObject.create(min_size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..min_size) |i| {
        const tuple = try PyTupleObject.create(args.len, vm.mm);
        const tup_items = tuple.items();
        for (lists, 0..) |list, j| {
            tup_items[j].decRef(vm.mm);
            const item = list.items.?[i];
            item.incRef();
            tup_items[j] = item;
        }
        try result_list.append(&tuple.base, vm.mm);
        tuple.base.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinMap(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    
    const callable = args[0];
    const iterable = args[1];
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(list.size, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const item = list.items.?[i];
        
        var call_args = [_]*PyObject{item};
        const res = try vm.callCallable(callable, &call_args);
        
        try result_list.append(res, vm.mm);
        res.decRef(vm.mm);
    }
    return &result_list.base;
}

pub fn builtinFilter(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    
    const callable = args[0];
    const iterable = args[1];
    
    const list = try iterableToList(iterable, vm.mm);
    defer list.base.decRef(vm.mm);
    
    const result_list = try PyListObject.create(0, vm.mm);
    errdefer result_list.base.decRef(vm.mm);
    
    for (0..list.size) |i| {
        const item = list.items.?[i];
        var is_ok = false;
        
        if (callable == PyNone) {
            is_ok = @import("../vm/vm.zig").isTrue(item);
        } else {
            var call_args = [_]*PyObject{item};
            const res = try vm.callCallable(callable, &call_args);
            is_ok = @import("../vm/vm.zig").isTrue(res);
            res.decRef(vm.mm);
        }
        
        if (is_ok) {
            try result_list.append(item, vm.mm);
        }
    }
    return &result_list.base;
}

pub fn builtinSorted(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const iterable = args[0];
    const orig_list = try iterableToList(iterable, vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    const list = try PyListObject.create(orig_list.size, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        item.incRef();
        try list.append(item, vm.mm);
        item.decRef(vm.mm);
    }
    
    if (list.size > 1) {
        var i: usize = 0;
        while (i < list.size - 1) : (i += 1) {
            var j: usize = 0;
            while (j < list.size - i - 1) : (j += 1) {
                const a = list.items.?[j];
                const b = list.items.?[j + 1];
                if (a.type_obj.tp_richcompare) |cmp| {
                    const gt = try cmp(a, b, .Gt, vm.mm);
                    const is_gt = gt == PyTrue;
                    gt.decRef(vm.mm);
                    if (is_gt) {
                        list.items.?[j] = b;
                        list.items.?[j + 1] = a;
                    }
                }
            }
        }
    }
    return &list.base;
}

pub fn builtinReversed(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const iterable = args[0];
    const orig_list = try iterableToList(iterable, vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    const list = try PyListObject.create(orig_list.size, vm.mm);
    errdefer list.base.decRef(vm.mm);
    
    var i = orig_list.size;
    while (i > 0) {
        i -= 1;
        const item = orig_list.items.?[i];
        try list.append(item, vm.mm);
    }
    return &list.base;
}

pub fn builtinAny(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const orig_list = try iterableToList(args[0], vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        if (@import("../vm/vm.zig").isTrue(item)) {
            PyTrue.incRef();
            return PyTrue;
        }
    }
    PyFalse.incRef();
    return PyFalse;
}

pub fn builtinAll(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const orig_list = try iterableToList(args[0], vm.mm);
    defer orig_list.base.decRef(vm.mm);
    
    for (0..orig_list.size) |i| {
        const item = orig_list.items.?[i];
        if (!@import("../vm/vm.zig").isTrue(item)) {
            PyFalse.incRef();
            return PyFalse;
        }
    }
    PyTrue.incRef();
    return PyTrue;
}

pub fn builtinPow(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    
    const a = args[0];
    const b = args[1];
    
    if (args.len == 2) {
        if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
            const base_val = a.as(primitives.PyIntObject).value;
            const exp_val = b.as(primitives.PyIntObject).value;
            var result: i64 = 1;
            var i_exp: i64 = 0;
            while (i_exp < exp_val) : (i_exp += 1) {
                result = result * base_val;
            }
            return try PyIntObject.create(result, vm.mm);
        } else {
            const fa = if (std.mem.eql(u8, a.type_obj.name, "float"))
                a.as(primitives.PyFloatObject).value
            else if (std.mem.eql(u8, a.type_obj.name, "int"))
                @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value))
            else
                return error.TypeError;
            const fb = if (std.mem.eql(u8, b.type_obj.name, "float"))
                b.as(primitives.PyFloatObject).value
            else if (std.mem.eql(u8, b.type_obj.name, "int"))
                @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value))
            else
                return error.TypeError;
            return try primitives.PyFloatObject.create(std.math.pow(f64, fa, fb), vm.mm);
        }
    } else {
        if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int") and std.mem.eql(u8, args[2].type_obj.name, "int")) {
            const base_val = a.as(primitives.PyIntObject).value;
            const exp_val = b.as(primitives.PyIntObject).value;
            const mod_val = args[2].as(primitives.PyIntObject).value;
            if (mod_val == 0) return error.ZeroDivisionError;
            
            var res: i64 = 1;
            var base = @rem(base_val, mod_val);
            var exp = exp_val;
            while (exp > 0) {
                if (@rem(exp, 2) == 1) {
                    res = @rem(res * base, mod_val);
                }
                exp = @divFloor(exp, 2);
                base = @rem(base * base, mod_val);
            }
            return try PyIntObject.create(res, vm.mm);
        }
        return error.TypeError;
    }
}

pub fn builtinRound(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const num = args[0];
    var ndigits: i64 = 0;
    if (args.len == 2) {
        if (!std.mem.eql(u8, args[1].type_obj.name, "int")) return error.TypeError;
        ndigits = args[1].as(PyIntObject).value;
    }
    
    const val = if (std.mem.eql(u8, num.type_obj.name, "float"))
        num.as(primitives.PyFloatObject).value
    else if (std.mem.eql(u8, num.type_obj.name, "int"))
        @as(f64, @floatFromInt(num.as(PyIntObject).value))
    else
        return error.TypeError;
        
    if (args.len == 1) {
        return try PyIntObject.create(@intFromFloat(std.math.round(val)), vm.mm);
    } else {
        const factor = std.math.pow(f64, 10.0, @floatFromInt(ndigits));
        return try primitives.PyFloatObject.create(std.math.round(val * factor) / factor, vm.mm);
    }
}

pub fn builtinHash(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    
    const obj = args[0];
    if (obj.type_obj.tp_hash) |hash_fn| {
        const h = try hash_fn(obj);
        return try PyIntObject.create(h, vm.mm);
    } else {
        const h: i64 = @intCast(@intFromPtr(obj));
        return try PyIntObject.create(h, vm.mm);
    }
}

pub fn setAddMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "set")) return error.TypeError;
    try self_obj.as(collections.PySetObject).add(key, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn setRemoveMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "set")) return error.TypeError;
    const removed = try self_obj.as(collections.PySetObject).remove(key, vm.mm);
    if (!removed) return error.KeyError;
    PyNone.incRef();
    return PyNone;
}

pub fn setDiscardMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "set")) return error.TypeError;
    _ = try self_obj.as(collections.PySetObject).remove(key, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listAppendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    try self_obj.as(collections.PyListObject).append(item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listInsertMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 3) return error.TypeError;
    const self_obj = args[0];
    const index = args[1];
    const item = args[2];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    if (!std.mem.eql(u8, index.type_obj.name, "int")) return error.TypeError;
    try self_obj.as(collections.PyListObject).insert(index.as(PyIntObject).value, item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listPopMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    const self = self_obj.as(collections.PyListObject);
    if (self.size == 0) return error.IndexError;
    const index: ?i64 = if (args.len == 2) blk: {
        if (!std.mem.eql(u8, args[1].type_obj.name, "int")) return error.TypeError;
        break :blk args[1].as(PyIntObject).value;
    } else null;
    return self.pop(index);
}

pub fn listRemoveMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    try self_obj.as(collections.PyListObject).remove(item, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listIndexMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    const idx = try self_obj.as(collections.PyListObject).index(item, vm.mm);
    return try PyIntObject.create(idx, vm.mm);
}

pub fn listCountMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    const cnt = try self_obj.as(collections.PyListObject).count(item, vm.mm);
    return try PyIntObject.create(cnt, vm.mm);
}

pub fn listReverseMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    self_obj.as(collections.PyListObject).reverse();
    PyNone.incRef();
    return PyNone;
}

pub fn listSortMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    try self_obj.as(collections.PyListObject).sort(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listExtendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const iterable = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    try self_obj.as(collections.PyListObject).extend(iterable, vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn listClearMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "list")) return error.TypeError;
    self_obj.as(collections.PyListObject).clear(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn dictKeysMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).keys(vm.mm);
    return &result.base;
}

pub fn dictValuesMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).values(vm.mm);
    return &result.base;
}

pub fn dictItemsMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).items(vm.mm);
    return &result.base;
}

pub fn dictGetMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    if (self_obj.as(collections.PyDictObject).get(key, vm.mm)) |val| {
        val.incRef();
        return val;
    }
    if (args.len == 3) {
        args[2].incRef();
        return args[2];
    }
    PyNone.incRef();
    return PyNone;
}

pub fn dictPopMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self_obj = args[0];
    const key = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    const result = self_obj.as(collections.PyDictObject).dictPop(key, vm.mm) catch |err| {
        if (err == error.KeyError and args.len == 3) {
            args[2].incRef();
            return args[2];
        }
        return err;
    };
    return result;
}

pub fn dictUpdateMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const other = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    if (!std.mem.eql(u8, other.type_obj.name, "dict")) return error.TypeError;
    try self_obj.as(collections.PyDictObject).update(other.as(collections.PyDictObject), vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn dictClearMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    self_obj.as(collections.PyDictObject).clear(vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn dictCopyMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "dict")) return error.TypeError;
    const result = try self_obj.as(collections.PyDictObject).copy(vm.mm);
    return &result.base;
}

pub fn stringSplitMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    const result = try PyListObject.create(0, vm.mm);
    if (args.len == 2) {
        const sep_obj = args[1];
        if (!std.mem.eql(u8, sep_obj.type_obj.name, "str")) return error.TypeError;
        const sep_str = sep_obj.as(PyStringObject).value();
        if (sep_str.len == 0) return error.ValueError;
        var start: usize = 0;
        while (std.mem.indexOf(u8, s[start..], sep_str)) |pos| {
            const part = s[start..][0..pos];
            const str_obj = try PyStringObject.create(part, vm.mm);
            try result.append(str_obj, vm.mm);
            str_obj.decRef(vm.mm);
            start += pos + sep_str.len;
        }
        const last = s[start..];
        const str_obj = try PyStringObject.create(last, vm.mm);
        try result.append(str_obj, vm.mm);
        str_obj.decRef(vm.mm);
    } else {
        var start: usize = 0;
        while (start < s.len and std.ascii.isWhitespace(s[start])) {
            start += 1;
        }
        while (start < s.len) {
            var end = start;
            while (end < s.len and !std.ascii.isWhitespace(s[end])) {
                end += 1;
            }
            const part = s[start..end];
            const str_obj = try PyStringObject.create(part, vm.mm);
            try result.append(str_obj, vm.mm);
            str_obj.decRef(vm.mm);
            start = end;
            while (start < s.len and std.ascii.isWhitespace(s[start])) {
                start += 1;
            }
        }
    }
    return &result.base;
}

pub fn stringJoinMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const iterable = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    if (!std.mem.eql(u8, iterable.type_obj.name, "list")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const sep = self.value();
    const lst = iterable.as(PyListObject);

    const items = if (lst.items) |it| it[0..lst.size] else &[_]*PyObject{};
    var total_len: usize = 0;
    for (items, 0..) |item, i| {
        if (!std.mem.eql(u8, item.type_obj.name, "str")) return error.TypeError;
        total_len += item.as(PyStringObject).len;
        if (i < items.len - 1) total_len += sep.len;
    }

    const buf = try vm.mm.allocBytes(total_len);
    var offset: usize = 0;
    for (items, 0..) |item, i| {
        const part = item.as(PyStringObject).value();
        @memcpy(buf[offset..][0..part.len], part);
        offset += part.len;
        if (i < items.len - 1) {
            @memcpy(buf[offset..][0..sep.len], sep);
            offset += sep.len;
        }
    }
    return try PyStringObject.create(buf, vm.mm);
}

pub fn stringReplaceMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 3 or args.len > 4) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const old_obj = args[1];
    const new_obj = args[2];
    if (!std.mem.eql(u8, old_obj.type_obj.name, "str")) return error.TypeError;
    if (!std.mem.eql(u8, new_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();
    const old_str = old_obj.as(PyStringObject).value();
    const new_str = new_obj.as(PyStringObject).value();
    const count: usize = if (args.len == 4) blk: {
        if (!std.mem.eql(u8, args[3].type_obj.name, "int")) return error.TypeError;
        const c = args[3].as(PyIntObject).value;
        break :blk if (c < 0) std.math.maxInt(usize) else @intCast(c);
    } else std.math.maxInt(usize);

    if (old_str.len == 0) return error.ValueError;

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;

    var remaining = count;
    var start: usize = 0;
    while (remaining > 0) {
        if (std.mem.indexOf(u8, s[start..], old_str)) |pos| {
            try writer.writeAll(s[start..][0..pos]);
            try writer.writeAll(new_str);
            start += pos + old_str.len;
            remaining -= 1;
        } else {
            break;
        }
    }
    try writer.writeAll(s[start..]);
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringStripMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    if (args.len == 2) {
        const chars_obj = args[1];
        if (!std.mem.eql(u8, chars_obj.type_obj.name, "str")) return error.TypeError;
        const chars = chars_obj.as(PyStringObject).value();
        const trimmed = std.mem.trim(u8, s, chars);
        return try PyStringObject.create(trimmed, vm.mm);
    } else {
        var start: usize = 0;
        while (start < s.len and std.ascii.isWhitespace(s[start])) {
            start += 1;
        }
        if (start == s.len) return try PyStringObject.create("", vm.mm);
        var end = s.len - 1;
        while (end > start and std.ascii.isWhitespace(s[end])) {
            end -= 1;
        }
        return try PyStringObject.create(s[start..end + 1], vm.mm);
    }
}

pub fn stringLowerMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    for (s) |c| {
        try writer.writeByte(std.ascii.toLower(c));
    }
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringUpperMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 1) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const s = self.value();

    var alloc_writer = std.Io.Writer.Allocating.init(vm.mm.allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;
    for (s) |c| {
        try writer.writeByte(std.ascii.toUpper(c));
    }
    return try PyStringObject.create(alloc_writer.written(), vm.mm);
}

pub fn stringStartsWithMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const prefix_obj = args[1];
    if (!std.mem.eql(u8, prefix_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const prefix = prefix_obj.as(PyStringObject).value();
    const s = self.value();
    if (prefix.len > s.len) return PyFalse;
    return if (std.mem.eql(u8, s[0..prefix.len], prefix)) PyTrue else PyFalse;
}

pub fn stringEndsWithMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm;
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "str")) return error.TypeError;
    const suffix_obj = args[1];
    if (!std.mem.eql(u8, suffix_obj.type_obj.name, "str")) return error.TypeError;
    const self = self_obj.as(PyStringObject);
    const suffix = suffix_obj.as(PyStringObject).value();
    const s = self.value();
    if (suffix.len > s.len) return PyFalse;
    return if (std.mem.eql(u8, s[s.len - suffix.len ..], suffix)) PyTrue else PyFalse;
}

pub fn bytearrayAppendMethod(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len != 2) return error.TypeError;
    const self_obj = args[0];
    const item = args[1];
    if (!std.mem.eql(u8, self_obj.type_obj.name, "bytearray")) return error.TypeError;
    if (!std.mem.eql(u8, item.type_obj.name, "int")) return error.TypeError;
    const val = item.as(PyIntObject).value;
    if (val < 0 or val > 255) return error.ValueError;
    try self_obj.as(primitives.PyByteArrayObject).append(@intCast(val), vm.mm);
    PyNone.incRef();
    return PyNone;
}

pub fn builtinNext(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
    const VM = @import("../vm/vm.zig").VM;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (args.len < 1 or args.len > 2) return error.TypeError;
    
    const iterable = args[0];
    const default_val = if (args.len == 2) args[1] else null;
    
    if (std.mem.eql(u8, iterable.type_obj.name, "generator")) {
        const gen = iterable.as(@import("../objects/function.zig").PyGeneratorObject);
        if (gen.is_closed) {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        }
        
        const prev_frame_count = vm.frame_count;
        
        vm.frames[vm.frame_count] = gen.frame;
        vm.frame_count += 1;
        
        try vm.runLoop(prev_frame_count);
        
        if (gen.is_closed) {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        }
        
        const caller_frame = &vm.frames[vm.frame_count - 1];
        return caller_frame.pop();
    } else if (std.mem.eql(u8, iterable.type_obj.name, "object")) {
        // User-defined iterator — call __next__
        const next_method = vm.loadAttribute(iterable, "__next__") catch {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        };
        defer next_method.decRef(vm.mm);
        
        const prev_frame_count = vm.frame_count;
        try vm.callObject(next_method, &.{}, null);
        if (vm.frame_count > prev_frame_count) {
            vm.suppress_exception_handling = true;
            defer vm.suppress_exception_handling = false;
            vm.runLoop(prev_frame_count) catch |err| {
                if (err == error.PythonException) {
                    if (default_val) |dv| {
                        dv.incRef();
                        return dv;
                    }
                    return error.StopIteration;
                }
                return err;
            };
        }
        
        const result = vm.last_result orelse {
            if (default_val) |dv| {
                dv.incRef();
                return dv;
            }
            return error.StopIteration;
        };
        vm.last_result = null;
        return result;
    } else {
        return error.TypeError;
    }
}


