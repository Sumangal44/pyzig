const std = @import("std");
const PyObject = @import("../objects/object.zig").PyObject;
const PyTypeObject = @import("../objects/object.zig").PyTypeObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyDictObject = @import("../objects/collections.zig").PyDictObject;
const PyStringObject = @import("../objects/primitives.zig").PyStringObject;
const PyIntObject = @import("../objects/primitives.zig").PyIntObject;
const PyFloatObject = @import("../objects/primitives.zig").PyFloatObject;
const PyBuiltinFunctionObject = @import("../objects/function.zig").PyBuiltinFunctionObject;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Parser = @import("../parser/parser.zig").Parser;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;
const PyInt_Type = @import("../objects/primitives.zig").PyInt_Type;
const PyFloat_Type = @import("../objects/primitives.zig").PyFloat_Type;
const PyTrue = @import("../objects/primitives.zig").PyTrue;
const PyFalse = @import("../objects/primitives.zig").PyFalse;

pub const PyModuleObject = struct {
    base: PyObject,
    name: *PyObject, // PyStringObject
    dict: *PyObject, // PyDictObject
    globals: *std.StringHashMap(*PyObject),
    
    pub fn create(name: *PyObject, dict: *PyObject, globals: *std.StringHashMap(*PyObject), mm: *PyMemoryManager) !*PyModuleObject {
        const obj = try mm.alloc(PyModuleObject);
        obj.* = .{
            .base = PyObject.init(&PyModule_Type),
            .name = name,
            .dict = dict,
            .globals = globals,
        };
        name.incRef();
        dict.incRef();
        return obj;
    }
};

pub const PyModule_Type = PyTypeObject{
    .name = "module",
    .tp_dealloc = module_dealloc,
    .tp_repr = module_repr,
    .tp_str = module_repr,
};

fn module_dealloc(self: *PyObject, mm: *PyMemoryManager) void {
    const obj = self.as(PyModuleObject);
    obj.name.decRef(mm);
    obj.dict.decRef(mm);
    
    // Clean up heap-allocated globals map and its entries
    var it = obj.globals.iterator();
    while (it.next()) |entry| {
        obj.globals.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.decRef(mm);
    }
    const allocator = obj.globals.allocator;
    obj.globals.deinit();
    allocator.destroy(obj.globals);
    
    mm.free(PyModuleObject, obj);
}

fn module_repr(self: *PyObject, mm: *PyMemoryManager) anyerror!*PyObject {
    const obj = self.as(PyModuleObject);
    var buf: [128]u8 = undefined;
    const repr_str = std.fmt.bufPrint(&buf, "<module '{s}'>", .{obj.name.as(PyStringObject).value()}) catch "<module>";
    return try PyStringObject.create(repr_str, mm);
}

pub var sys_modules: ?std.StringHashMap(*PyObject) = null;

pub fn initImportSystem(allocator: std.mem.Allocator) void {
    if (sys_modules == null) {
        sys_modules = std.StringHashMap(*PyObject).init(allocator);
    }
}

pub fn deinitImportSystem(mm: *PyMemoryManager) void {
    if (sys_modules) |*modules| {
        var it = modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.decRef(mm);
            modules.allocator.free(entry.key_ptr.*);
        }
        modules.deinit();
        sys_modules = null;
    }
}

pub fn importModule(name: []const u8, vm: *VM) anyerror!*PyObject {
    initImportSystem(vm.allocator);
    
    if (sys_modules.?.get(name)) |cached| {
        cached.incRef();
        return cached;
    }
    
    // Allocate globals map on the heap
    const heap_globals = try vm.allocator.create(std.StringHashMap(*PyObject));
    heap_globals.* = std.StringHashMap(*PyObject).init(vm.allocator);
    errdefer {
        var it = heap_globals.iterator();
        while (it.next()) |entry| {
            vm.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(vm.mm);
        }
        heap_globals.deinit();
        vm.allocator.destroy(heap_globals);
    }
    
    var compiled_success = false;
    
    if (std.mem.eql(u8, name, "keyword")) {
        const keyword_src =
            \\kwlist = ['False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield']
            \\softkwlist = ['_', 'case', 'match', 'type']
            \\
            \\def iskeyword(s):
            \\    return s in kwlist
            \\
            \\def issoftkeyword(s):
            \\    return s in softkwlist
            \\
        ;
        
        var lexer = Lexer.init(keyword_src);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "math")) {
        // Register math constants
        const constant_names = &.{ "pi", "e", "tau" };
        const constant_values = [_]f64{ std.math.pi, std.math.e, std.math.tau };
        inline for (constant_names, &constant_values) |cname, cval| {
            const val_obj = try PyFloatObject.create(cval, vm.mm);
            const name_c = try vm.allocator.dupe(u8, cname);
            try heap_globals.put(name_c, val_obj);
        }
        
        // Register inf/nan
        {
            const inf_obj = try PyFloatObject.create(std.math.inf(f64), vm.mm);
            const inf_c = try vm.allocator.dupe(u8, "inf");
            try heap_globals.put(inf_c, inf_obj);
        }
        {
            const nan_obj = try PyFloatObject.create(std.math.nan(f64), vm.mm);
            const nan_c = try vm.allocator.dupe(u8, "nan");
            try heap_globals.put(nan_c, nan_obj);
        }
        
        // Register native math functions
        inline for (&.{ "sqrt", "sin", "cos", "tan", "log", "log10", "log2", "floor", "ceil", "radians", "degrees", "exp" }) |fn_name| {
            const T = struct {
                fn mathFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    const val: f64 = if (num.type_obj == &PyFloat_Type) num.as(PyFloatObject).value
                        else if (num.type_obj == &PyInt_Type) @floatFromInt(num.as(PyIntObject).value)
                        else return error.TypeError;
                    const op = comptime fn_name;
                    const res = if (comptime std.mem.eql(u8, op, "sqrt")) std.math.sqrt(val)
                        else if (comptime std.mem.eql(u8, op, "sin")) std.math.sin(val)
                        else if (comptime std.mem.eql(u8, op, "cos")) std.math.cos(val)
                        else if (comptime std.mem.eql(u8, op, "tan")) std.math.tan(val)
                        else if (comptime std.mem.eql(u8, op, "log")) std.math.log(f64, std.math.e, val)
                        else if (comptime std.mem.eql(u8, op, "log10")) std.math.log10(val)
                        else if (comptime std.mem.eql(u8, op, "log2")) std.math.log2(val)
                        else if (comptime std.mem.eql(u8, op, "floor")) @floor(val)
                        else if (comptime std.mem.eql(u8, op, "ceil")) @ceil(val)
                        else if (comptime std.mem.eql(u8, op, "radians")) val * std.math.pi / 180.0
                        else if (comptime std.mem.eql(u8, op, "degrees")) val * 180.0 / std.math.pi
                        else if (comptime std.mem.eql(u8, op, "exp")) std.math.exp(val)
                        else val;
                    return try PyFloatObject.create(res, vm2.mm);
                }
            };
            const builtin_func = try PyBuiltinFunctionObject.create(fn_name, T.mathFn, vm.mm);
            const name_c = try vm.allocator.dupe(u8, fn_name);
            try heap_globals.put(name_c, &builtin_func.base);
        }
        
        // Register isfinite, isinf, isnan as native functions
        {
            const T = struct {
                fn isfiniteFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == &PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isFinite(val)) PyTrue else PyFalse;
                    } else if (num.type_obj == &PyInt_Type) {
                        return PyTrue;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isfinite", T.isfiniteFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isfinite");
            try heap_globals.put(c, &func.base);
        }
        {
            const T = struct {
                fn isinfFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == &PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isInf(val)) PyTrue else PyFalse;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isinf", T.isinfFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isinf");
            try heap_globals.put(c, &func.base);
        }
        {
            const T = struct {
                fn isnanFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const num = args[0];
                    if (num.type_obj == &PyFloat_Type) {
                        const val = num.as(PyFloatObject).value;
                        return if (std.math.isNan(val)) PyTrue else PyFalse;
                    }
                    return PyFalse;
                }
            };
            const func = try PyBuiltinFunctionObject.create("isnan", T.isnanFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "isnan");
            try heap_globals.put(c, &func.base);
        }
        
        compiled_success = true;
    } else if (std.mem.eql(u8, name, "random")) {
        // Register random.random()
        {
            const T = struct {
                fn randomFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 0) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const val = prng.random().float(f64);
                    return try PyFloatObject.create(val, vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("random", T.randomFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "random");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.randint(a, b)
        {
            const T = struct {
                fn randintFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 2) return error.TypeError;
                    if (args[0].type_obj != &PyInt_Type or args[1].type_obj != &PyInt_Type) return error.TypeError;
                    const a = args[0].as(PyIntObject).value;
                    const b = args[1].as(PyIntObject).value;
                    if (a > b) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const range = b - a + 1;
                    const val = a + @as(i64, @intCast(prng.random().uintLessThan(u64, @as(u64, @intCast(range)))));
                    return try PyIntObject.create(val, vm2.mm);
                }
            };
            const func = try PyBuiltinFunctionObject.create("randint", T.randintFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "randint");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.choice(seq)
        {
            const T = struct {
                fn choiceFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    const VM2 = @import("../vm/vm.zig").VM;
                    const vm2: *VM2 = @ptrCast(@alignCast(vm_opaque));
                    if (args.len != 1) return error.TypeError;
                    const seq = args[0];
                    const type_name = seq.type_obj.name;
                    var len: usize = 0;
                    if (std.mem.eql(u8, type_name, "list")) {
                        len = seq.as(@import("../objects/collections.zig").PyListObject).size;
                    } else if (std.mem.eql(u8, type_name, "tuple")) {
                        len = seq.as(@import("../objects/collections.zig").PyTupleObject).size;
                    } else if (std.mem.eql(u8, type_name, "str")) {
                        len = seq.as(@import("../objects/primitives.zig").PyStringObject).len;
                    } else {
                        return error.TypeError;
                    }
                    if (len == 0) return error.TypeError;
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const idx = prng.random().uintLessThan(u64, @as(u64, @intCast(len)));
                    const collections = @import("../objects/collections.zig");
                    const primitives = @import("../objects/primitives.zig");
                    if (std.mem.eql(u8, type_name, "list")) {
                        const item = seq.as(collections.PyListObject).items.?[idx];
                        item.incRef();
                        return item;
                    } else if (std.mem.eql(u8, type_name, "tuple")) {
                        const item = seq.as(collections.PyTupleObject).items()[idx];
                        item.incRef();
                        return item;
                    } else {
                        const str_val = seq.as(primitives.PyStringObject).value();
                        const ch = try primitives.PyStringObject.create(str_val[idx..idx+1], vm2.mm);
                        return ch;
                    }
                }
            };
            const func = try PyBuiltinFunctionObject.create("choice", T.choiceFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "choice");
            try heap_globals.put(c, &func.base);
        }
        
        // Register random.shuffle(x)
        {
            const T = struct {
                fn shuffleFn(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
                    _ = vm_opaque;
                    if (args.len != 1) return error.TypeError;
                    const seq = args[0];
                    if (seq.type_obj != &(@import("../objects/collections.zig").PyList_Type)) return error.TypeError;
                    const list = seq.as(@import("../objects/collections.zig").PyListObject);
                    const PyNone = @import("../objects/primitives.zig").PyNone;
                    if (list.size <= 1) { PyNone.incRef(); return PyNone; }
                    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@intFromPtr(args.ptr))));
                    const rng = prng.random();
                    var i: usize = list.size;
                    while (i > 1) {
                        i -= 1;
                        const j = rng.uintLessThan(u64, @as(u64, @intCast(i + 1)));
                        const tmp = list.items.?[i];
                        list.items.?[i] = list.items.?[j];
                        list.items.?[j] = tmp;
                    }
                    PyNone.incRef();
                    return PyNone;
                }
            };
            const func = try PyBuiltinFunctionObject.create("shuffle", T.shuffleFn, vm.mm);
            const c = try vm.allocator.dupe(u8, "shuffle");
            try heap_globals.put(c, &func.base);
        }
        
        compiled_success = true;
    } else {
        var file_name_buf: [128]u8 = undefined;
        const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.py", .{name}) catch return error.ImportError;
        
        const cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(vm.io, file_name, .{ .mode = .read_only }) catch {
            std.debug.print("ImportError: Module '{s}' not found\n", .{name});
            return error.ImportError;
        };
        defer file.close(vm.io);
        
        var buf: [1024]u8 = undefined;
        var file_reader = file.reader(vm.io, &buf);
        const reader = &file_reader.interface;
        const content = try reader.allocRemaining(vm.allocator, .unlimited);
        defer vm.allocator.free(content);
        
        var lexer = Lexer.init(content);
        var arena = std.heap.ArenaAllocator.init(vm.allocator);
        defer arena.deinit();
        
        var parser = Parser.init(&lexer, arena.allocator());
        const module_ast = parser.parseModule() catch return error.SyntaxError;
        
        var compiler = Compiler.init(arena.allocator(), vm.mm);
        defer compiler.deinit();
        
        var code = try compiler.compile(&module_ast);
        defer code.deinit(arena.allocator(), vm.mm);
        
        const result = try vm.run(&code, heap_globals);
        result.decRef(vm.mm);
        compiled_success = true;
    }
    
    if (!compiled_success) return error.ImportError;
    
    const dict = try PyDictObject.create(vm.mm);
    defer dict.base.decRef(vm.mm);
    
    var it = heap_globals.iterator();
    while (it.next()) |entry| {
        const key_str = try PyStringObject.create(entry.key_ptr.*, vm.mm);
        defer key_str.decRef(vm.mm);
        try dict.setItem(key_str, entry.value_ptr.*, vm.mm);
    }
    
    const name_str = try PyStringObject.create(name, vm.mm);
    defer name_str.decRef(vm.mm);
    const module_obj = try PyModuleObject.create(name_str, &dict.base, heap_globals, vm.mm);
    
    const name_copy = try vm.allocator.dupe(u8, name);
    module_obj.base.incRef();
    try sys_modules.?.put(name_copy, &module_obj.base);
    
    return &module_obj.base;
}
