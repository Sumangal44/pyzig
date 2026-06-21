const std = @import("std");
const testing = std.testing;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const PyObject = @import("../objects/object.zig").PyObject;
const CompareOp = @import("../objects/object.zig").CompareOp;
const primitives = @import("../objects/primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyStringObject = primitives.PyStringObject;
const PyString_Type = primitives.PyString_Type;
const bytecode = @import("../bytecode/bytecode.zig");
const Opcode = bytecode.Opcode;
const Instruction = bytecode.Instruction;
const PyCodeObject = bytecode.PyCodeObject;
const PyCodeObjectWrapper = bytecode.PyCodeObjectWrapper;

const collections = @import("../objects/collections.zig");
const PyTupleObject = collections.PyTupleObject;
const PyTuple_Type = collections.PyTuple_Type;
const PyListObject = collections.PyListObject;
const PyList_Type = collections.PyList_Type;
const PyDictObject = collections.PyDictObject;
const PyDict_Type = collections.PyDict_Type;

const function_mod = @import("../objects/function.zig");
const PyFunctionObject = function_mod.PyFunctionObject;
const PyFunction_Type = function_mod.PyFunction_Type;
const PyBuiltinFunctionObject = function_mod.PyBuiltinFunctionObject;

const class_mod = @import("../objects/class.zig");
const PyClassObject = class_mod.PyClassObject;
const PyInstanceObject = class_mod.PyInstanceObject;
const PyMethodObject = class_mod.PyMethodObject;
const exception_mod = @import("../objects/exception.zig");
const PyExceptionObject = exception_mod.PyExceptionObject;
const cell_mod = @import("../objects/cell.zig");
const PyCellObject = cell_mod.PyCellObject;

pub const BlockType = enum {
    Finally,
    Except,
};

pub const Block = struct {
    type: BlockType,
    handler: usize,
    stack_level: usize,
};

pub const StackHelper = struct {
    pub inline fn push(f: *PyFrameObject, stack_top: *usize, obj: *PyObject) void {
        f.stack[stack_top.*] = obj;
        stack_top.* += 1;
    }
    pub inline fn pop(f: *PyFrameObject, stack_top: *usize) *PyObject {
        stack_top.* -= 1;
        return f.stack[stack_top.*];
    }
};

pub const PyFrameObject = struct {
    code: *PyCodeObject,
    ip: usize = 0,
    stack: [256]*PyObject = undefined,
    stack_top: usize = 0,
    locals: std.StringHashMap(*PyObject),
    globals: *std.StringHashMap(*PyObject),
    is_module: bool,
    fastlocals: []?*PyObject = &[_]?*PyObject{},
    
    // Exception blocks and class/method fields
    block_stack: [16]Block = undefined,
    block_stack_top: usize = 0,
    is_class_body: bool = false,
    class_name: ?*PyObject = null,
    class_base: ?*PyObject = null,
    init_instance: ?*PyObject = null,
    func: ?*PyFunctionObject = null,
    active_exception: ?*PyObject = null,

    pub fn init(allocator: std.mem.Allocator, code: *PyCodeObject, globals: *std.StringHashMap(*PyObject), is_module: bool) PyFrameObject {
        var fastlocals: []?*PyObject = &[_]?*PyObject{};
        if (code.varnames.len > 0) {
            fastlocals = allocator.alloc(?*PyObject, code.varnames.len) catch @panic("OOM");
            @memset(fastlocals, null);
        }
        return .{
            .code = code,
            .locals = std.StringHashMap(*PyObject).init(allocator),
            .globals = globals,
            .is_module = is_module,
            .fastlocals = fastlocals,
        };
    }

    pub fn deinit(self: *PyFrameObject, mm: *PyMemoryManager, allocator: std.mem.Allocator) void {
        var it = self.locals.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(mm);
        }
        self.locals.deinit();
        for (self.fastlocals) |opt_val| {
            if (opt_val) |val| val.decRef(mm);
        }
        if (self.fastlocals.len > 0) {
            allocator.free(self.fastlocals);
        }
        while (self.stack_top > 0) {
            self.stack_top -= 1;
            self.stack[self.stack_top].decRef(mm);
        }
        if (self.class_name) |cn| cn.decRef(mm);
        if (self.class_base) |cb| cb.decRef(mm);
        if (self.init_instance) |ii| ii.decRef(mm);
        if (self.func) |fu| fu.base.decRef(mm);
        if (self.active_exception) |ae| ae.decRef(mm);
    }

    pub inline fn push(self: *PyFrameObject, obj: *PyObject) void {
        if (std.debug.runtime_safety) {
            if (self.stack_top >= 256) {
                @panic("Stack overflow");
            }
        }
        self.stack[self.stack_top] = obj;
        self.stack_top += 1;
    }

    pub inline fn pop(self: *PyFrameObject) *PyObject {
        if (std.debug.runtime_safety) {
            if (self.stack_top == 0) {
                @panic("Stack underflow");
            }
        }
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }
};

pub fn isTrue(obj: *PyObject) bool {
    if (obj == PyTrue) return true;
    if (obj == PyFalse or obj == PyNone) return false;
    const name = obj.type_obj.name;
    if (std.mem.eql(u8, name, "list")) {
        return obj.as(PyListObject).size > 0;
    }
    if (std.mem.eql(u8, name, "tuple")) {
        return obj.as(PyTupleObject).size > 0;
    }
    if (std.mem.eql(u8, name, "dict")) {
        return obj.as(PyDictObject).active_count > 0;
    }
    if (std.mem.eql(u8, name, "int")) {
        return obj.as(primitives.PyIntObject).value != 0;
    }
    if (std.mem.eql(u8, name, "float")) {
        return obj.as(primitives.PyFloatObject).value != 0.0;
    }
    if (obj.type_obj.tp_bool) |bool_fn| {
        return bool_fn(obj);
    }
    return true;
}

pub const VM = struct {
    allocator: std.mem.Allocator,
    mm: *PyMemoryManager,
    frames: [64]PyFrameObject = undefined,
    frame_count: usize = 0,
    globals: std.StringHashMap(*PyObject),
    stdout_writer: *std.Io.Writer,
    last_result: ?*PyObject = null,
    io: std.Io,

    fn buildClass(args: []*PyObject, vm_opaque: *anyopaque) anyerror!*PyObject {
        // args[0] = body func, args[1] = class name str, args[2]? = base class
        const vm: *VM = @ptrCast(@alignCast(vm_opaque));
        if (args.len < 2) return error.TypeError;
        
        const body_func = args[0];
        const name_obj = args[1];
        const base_obj: ?*PyObject = if (args.len >= 3) args[2] else null;
        
        if (!std.mem.eql(u8, body_func.type_obj.name, "function")) return error.TypeError;
        if (!std.mem.eql(u8, name_obj.type_obj.name, "str")) return error.TypeError;
        
        const func = body_func.as(PyFunctionObject);
        const code_wrapper = func.code.as(PyCodeObjectWrapper);
        const func_code = code_wrapper.code;
        
        if (vm.frame_count >= 64) return error.StackOverflow;
        
        // Build a class frame — locals become class attributes
        const child_frame = PyFrameObject{
            .code = func_code,
            .ip = 0,
            .stack_top = 0,
            .locals = std.StringHashMap(*PyObject).init(vm.allocator),
            .globals = func.globals,
            .is_module = false,
            .is_class_body = true,
            .class_name = name_obj,
            .class_base = base_obj,
            .func = func,
        };
        name_obj.incRef();
        if (base_obj) |b| b.incRef();
        func.base.incRef();
        
        vm.frames[vm.frame_count] = child_frame;
        vm.frame_count += 1;
        // Return sentinel None; popFrameAndPushResult will push the real class object
        return PyNone;
    }

    fn registerBuiltin(self: *VM, name: []const u8, func: *const fn (args: []*PyObject, vm: *anyopaque) anyerror!*PyObject) !void {
        const builtin_obj = try PyBuiltinFunctionObject.create(name, func, self.mm);
        errdefer builtin_obj.base.decRef(self.mm);
        const name_copy = try self.allocator.dupe(u8, name);
        try self.globals.put(name_copy, &builtin_obj.base);
    }

    fn registerExceptionClass(self: *VM) !void {
        var wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyException_Type, self.mm);
        var name_copy = try self.allocator.dupe(u8, "Exception");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyAssertionError_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "AssertionError");
        try self.globals.put(name_copy, &wrapper.base);

        wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/class.zig").PyInstance_Type, self.mm);
        name_copy = try self.allocator.dupe(u8, "object");
        try self.globals.put(name_copy, &wrapper.base);
    }

    pub fn init(allocator: std.mem.Allocator, mm: *PyMemoryManager, stdout_writer: *std.Io.Writer, io: std.Io) anyerror!VM {
        var vm = VM{
            .allocator = allocator,
            .mm = mm,
            .stdout_writer = stdout_writer,
            .globals = std.StringHashMap(*PyObject).init(allocator),
            .io = io,
        };
        errdefer vm.deinit();
        
        const builtins = @import("../stdlib/builtins.zig");
        try vm.registerBuiltin("len", builtins.builtinLen);
        try vm.registerBuiltin("type", builtins.builtinType);
        try vm.registerBuiltin("range", builtins.builtinRange);
        try vm.registerBuiltin("str", builtins.builtinStr);
        try vm.registerBuiltin("print", builtins.builtinPrint);
        try vm.registerBuiltin("input", builtins.builtinInput);
        try vm.registerBuiltin("int", builtins.builtinInt);
        try vm.registerBuiltin("float", builtins.builtinFloat);
        try vm.registerBuiltin("bool", builtins.builtinBool);
        try vm.registerBuiltin("abs", builtins.builtinAbs);
        try vm.registerBuiltin("max", builtins.builtinMax);
        try vm.registerBuiltin("min", builtins.builtinMin);
        try vm.registerBuiltin("sum", builtins.builtinSum);
        try vm.registerBuiltin("list", builtins.builtinList);
        try vm.registerBuiltin("tuple", builtins.builtinTuple);
        try vm.registerBuiltin("dict", builtins.builtinDict);
        try vm.registerBuiltin("isinstance", builtins.builtinIsinstance);
        try vm.registerBuiltin("hasattr", builtins.builtinHasattr);
        try vm.registerBuiltin("getattr", builtins.builtinGetattr);
        try vm.registerBuiltin("setattr", builtins.builtinSetattr);
        try vm.registerBuiltin("repr", builtins.builtinRepr);
        try vm.registerBuiltin("id", builtins.builtinId);
        try vm.registerBuiltin("chr", builtins.builtinChr);
        try vm.registerBuiltin("ord", builtins.builtinOrd);
        try vm.registerBuiltin("hex", builtins.builtinHex);
        try vm.registerBuiltin("oct", builtins.builtinOct);
        try vm.registerBuiltin("bin", builtins.builtinBin);
        try vm.registerBuiltin("enumerate", builtins.builtinEnumerate);
        try vm.registerBuiltin("zip", builtins.builtinZip);
        try vm.registerBuiltin("map", builtins.builtinMap);
        try vm.registerBuiltin("filter", builtins.builtinFilter);
        try vm.registerBuiltin("sorted", builtins.builtinSorted);
        try vm.registerBuiltin("reversed", builtins.builtinReversed);
        try vm.registerBuiltin("any", builtins.builtinAny);
        try vm.registerBuiltin("all", builtins.builtinAll);
        try vm.registerBuiltin("pow", builtins.builtinPow);
        try vm.registerBuiltin("round", builtins.builtinRound);
        try vm.registerBuiltin("hash", builtins.builtinHash);
        try vm.registerBuiltin("__build_class__", buildClass);
        try vm.registerExceptionClass();
        
        return vm;
    }

    pub fn deinit(self: *VM) void {
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            std.debug.print("Deinit global key: '{s}', type: '{s}', refcnt: {d}\n", .{entry.key_ptr.*, entry.value_ptr.*.type_obj.name, entry.value_ptr.*.refcnt});
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(self.mm);
        }
        self.globals.deinit();
        
        @import("../import_system/import.zig").deinitImportSystem(self.mm);
        
        while (self.frame_count > 0) {
            self.frame_count -= 1;
            self.frames[self.frame_count].deinit(self.mm, self.allocator);
        }
    }

    fn popFrameAndPushResult(self: *VM, result: *PyObject, starting_frame_count: usize) void {
        var f = &self.frames[self.frame_count - 1];
        
        var actual_result = result;
        if (f.is_class_body) {
            result.decRef(self.mm);
            
            const dict = PyDictObject.create(self.mm) catch @panic("OOM");
            var it = f.locals.iterator();
            while (it.next()) |entry| {
                const key_str = PyStringObject.create(entry.key_ptr.*, self.mm) catch @panic("OOM");
                defer key_str.decRef(self.mm);
                dict.setItem(key_str, entry.value_ptr.*, self.mm) catch @panic("OOM");
            }
            
            const class_obj = PyClassObject.create(f.class_name.?, f.class_base, &dict.base, self.mm) catch @panic("OOM");
            dict.base.decRef(self.mm); // PyClassObject.create did incRef; drop our local ref
            actual_result = &class_obj.base;
        } else if (f.init_instance) |inst| {
            result.decRef(self.mm);
            // Transfer ownership: null out init_instance so f.deinit doesn't decRef it,
            // then use that reference as actual_result directly.
            f.init_instance = null;
            actual_result = inst;
        }
        
        f.deinit(self.mm, self.allocator);
        self.frame_count -= 1;
        
        if (self.frame_count > starting_frame_count) {
            self.frames[self.frame_count - 1].push(actual_result);
        } else {
            self.last_result = actual_result;
        }
    }

    fn lookupClassAttribute(self: *VM, class_obj: *PyClassObject, name: []const u8) anyerror!?*PyObject {
        const key_str = try PyStringObject.create(name, self.mm);
        defer key_str.decRef(self.mm);
        
        var current: ?*PyClassObject = class_obj;
        while (current) |curr| {
            const dict = curr.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }
            if (curr.base_class) |base| {
                // Only recurse if the base is a user-defined class (PyClassObject)
                if (std.mem.eql(u8, base.type_obj.name, "type")) {
                    // Built-in base (e.g., Exception) — stop traversal
                    current = null;
                } else {
                    current = base.as(PyClassObject);
                }
            } else {
                current = null;
            }
        }
        return null;
    }

    fn isExceptionMatch(self: *VM, exc: *PyObject, type_name: []const u8) bool {
        _ = self;
        // Built-in exception (PyExceptionObject)
        if (std.mem.eql(u8, exc.type_obj.name, type_name)) return true;
        if (std.mem.eql(u8, type_name, "Exception")) {
            if (std.mem.eql(u8, exc.type_obj.name, "AssertionError")) return true;
        }
        // User-defined class instance (PyInstanceObject wraps PyClassObject)
        if (std.mem.eql(u8, exc.type_obj.name, "object")) {
            const inst = exc.as(PyInstanceObject);
            var curr: ?*PyClassObject = inst.class_obj;
            while (curr) |cls| {
                const cls_name = cls.name.as(PyStringObject).value();
                if (std.mem.eql(u8, cls_name, type_name)) return true;
                // Check against base class
                if (cls.base_class) |bc| {
                    // base is a PyTypeWrapper (built-in type)
                    if (std.mem.eql(u8, bc.type_obj.name, "type")) {
                        const wrapper = bc.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
                        if (std.mem.eql(u8, wrapper.type_ptr.name, type_name)) return true;
                        // "Exception" is the catch-all
                        if (std.mem.eql(u8, type_name, "Exception")) return true;
                        break;
                    }
                    // base is another user class
                    curr = bc.as(PyClassObject);
                } else {
                    break;
                }
            }
            // Catch-all "Exception" matches any user class that derives from Exception
            if (std.mem.eql(u8, type_name, "Exception")) {
                var c: ?*PyClassObject = inst.class_obj;
                while (c) |cls| {
                    if (cls.base_class) |bc| {
                        if (std.mem.eql(u8, bc.type_obj.name, "type")) {
                            return true;
                        }
                        c = bc.as(PyClassObject);
                    } else break;
                }
            }
        }
        return false;
    }

    pub fn loadAttribute(self: *VM, inst: *PyObject, name: []const u8) anyerror!*PyObject {

        const key_str = try PyStringObject.create(name, self.mm);
        defer key_str.decRef(self.mm);
        
        if (std.mem.eql(u8, inst.type_obj.name, "object")) {
            const instance = inst.as(PyInstanceObject);
            const dict = instance.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }
            
            if (try self.lookupClassAttribute(instance.class_obj, name)) |val| {
                if (std.mem.eql(u8, val.type_obj.name, "function")) {
                    const bound = try PyMethodObject.create(inst, val, self.mm);
                    val.decRef(self.mm);
                    return &bound.base;
                }
                return val;
            }
            
            std.debug.print("AttributeError: '{s}' object has no attribute '{s}'\n", .{instance.class_obj.name.as(PyStringObject).value(), name});
            return error.AttributeError;
        } else if (std.mem.eql(u8, inst.type_obj.name, "module")) {
            const module = inst.as(@import("../import_system/import.zig").PyModuleObject);
            const dict = module.dict.as(PyDictObject);
            if (try dict.getItem(key_str, self.mm)) |val| {
                val.incRef();
                return val;
            }
            std.debug.print("AttributeError: module '{s}' has no attribute '{s}'\n", .{module.name.as(PyStringObject).value(), name});
            return error.AttributeError;
        } else {
            std.debug.print("TypeError: '{s}' object has no attributes\n", .{inst.type_obj.name});
            return error.TypeError;
        }
    }

    pub fn storeAttribute(self: *VM, inst: *PyObject, name: []const u8, val: *PyObject) anyerror!void {
        const key_str = try PyStringObject.create(name, self.mm);
        defer key_str.decRef(self.mm);
        
        if (std.mem.eql(u8, inst.type_obj.name, "object")) {
            const instance = inst.as(PyInstanceObject);
            const dict = instance.dict.as(PyDictObject);
            try dict.setItem(key_str, val, self.mm);
        } else {
            std.debug.print("TypeError: '{s}' object does not support attribute assignment\n", .{inst.type_obj.name});
            return error.TypeError;
        }
    }

    fn callObject(self: *VM, callable: *PyObject, args: []*PyObject, init_instance: ?*PyObject) anyerror!void {
        const f = &self.frames[self.frame_count - 1];
        if (std.mem.eql(u8, callable.type_obj.name, "function")) {
            const func = callable.as(PyFunctionObject);
            const code_wrapper = func.code.as(PyCodeObjectWrapper);
            const func_code = code_wrapper.code;
            
            if (args.len != func_code.argcount) {
                std.debug.print("TypeError: expected {d} arguments, got {d}\n", .{func_code.argcount, args.len});
                for (args) |arg| {
                    arg.decRef(self.mm);
                }
                return error.TypeError;
            }
            
            if (self.frame_count >= 64) {
                for (args) |arg| {
                    arg.decRef(self.mm);
                }
                return error.StackOverflow;
            }
            
            var child_frame = PyFrameObject.init(self.allocator, func_code, func.globals, false);
            child_frame.func = func;
            child_frame.init_instance = init_instance;
            func.base.incRef();
            if (init_instance) |ii| ii.incRef();
            errdefer child_frame.deinit(self.mm, self.allocator);
            
            for (args, 0..) |arg_val, arg_idx| {
                child_frame.fastlocals[arg_idx] = arg_val;
            }
            
            self.frames[self.frame_count] = child_frame;
            self.frame_count += 1;
        } else if (std.mem.eql(u8, callable.type_obj.name, "builtin_function")) {
            const func = callable.as(PyBuiltinFunctionObject);
            const prev_frame_count = self.frame_count;
            const res = try func.func(args, self);
            for (args) |arg| {
                arg.decRef(self.mm);
            }
            if (self.frame_count > prev_frame_count) {
                // Builtin pushed a new frame (e.g., __build_class__); don't push sentinel result
                res.decRef(self.mm);
            } else {
                f.push(res);
                if (init_instance) |inst| {
                    res.decRef(self.mm);
                    inst.incRef();
                    f.push(inst);
                }
            }
        } else if (std.mem.eql(u8, callable.type_obj.name, "method")) {
            const method = callable.as(PyMethodObject);
            var new_args = try self.allocator.alloc(*PyObject, args.len + 1);
            defer self.allocator.free(new_args);
            
            new_args[0] = method.self_obj;
            method.self_obj.incRef();
            
            for (args, 0..) |arg, idx| {
                new_args[idx + 1] = arg;
            }
            
            try self.callObject(method.func, new_args, init_instance);
        } else if (std.mem.eql(u8, callable.type_obj.name, "type")) {
            const wrapper = callable.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
            if (std.mem.eql(u8, wrapper.type_ptr.name, "Exception") or std.mem.eql(u8, wrapper.type_ptr.name, "AssertionError")) {
                const msg = if (args.len > 0) args[0] else try PyStringObject.create("", self.mm);
                const exc = try PyExceptionObject.create(wrapper.type_ptr, msg, self.mm);
                if (args.len == 0) {
                    msg.decRef(self.mm);
                }
                f.push(&exc.base);
                for (args) |arg| arg.decRef(self.mm);
            } else {
                std.debug.print("TypeError: built-in type '{s}' is not subclassable or directly constructible here\n", .{wrapper.type_ptr.name});
                for (args) |arg| arg.decRef(self.mm);
                return error.TypeError;
            }
        } else if (std.mem.eql(u8, callable.type_obj.name, "class_type")) {
            const class_obj = callable.as(PyClassObject);
            const inst = try PyInstanceObject.create(class_obj, self.mm);
            
            if (try self.lookupClassAttribute(class_obj, "__init__")) |init_func| {
                defer init_func.decRef(self.mm);
                const bound_init = try PyMethodObject.create(&inst.base, init_func, self.mm);
                defer bound_init.base.decRef(self.mm);
                
                try self.callObject(&bound_init.base, args, &inst.base);
                // popFrameAndPushResult will push inst (via init_instance ownership);
                // release our local create-reference now.
                inst.base.decRef(self.mm);
            } else {
                for (args) |arg| {
                    arg.decRef(self.mm);
                }
                f.push(&inst.base);
            }
        } else {
            std.debug.print("TypeError: '{s}' object is not callable\n", .{callable.type_obj.name});
            for (args) |arg| {
                arg.decRef(self.mm);
            }
            return error.TypeError;
        }
    }

    fn raiseException(self: *VM, exc: *PyObject) anyerror!void {
        exc.incRef();
        
        while (self.frame_count > 0) {
            const f = &self.frames[self.frame_count - 1];
            if (f.block_stack_top > 0) {
                f.block_stack_top -= 1;
                const block = f.block_stack[f.block_stack_top];
                
                while (f.stack_top > block.stack_level) {
                    f.stack_top -= 1;
                    f.stack[f.stack_top].decRef(self.mm);
                }
                
                if (f.active_exception) |ae| ae.decRef(self.mm);
                f.active_exception = exc;
                
                f.ip = block.handler;
                exc.incRef();
                f.push(exc);
                return;
            }
            
            f.deinit(self.mm, self.allocator);
            self.frame_count -= 1;
        }
        
        const repr_val = try exc.type_obj.tp_repr.?(exc, self.mm);
        defer repr_val.decRef(self.mm);
        try self.stdout_writer.print("{s}\n", .{repr_val.as(PyStringObject).value()});
        exc.decRef(self.mm);
        return error.PythonException;
    }

    pub fn run(self: *VM, code: *PyCodeObject, opt_globals: ?*std.StringHashMap(*PyObject)) anyerror!*PyObject {
        for (code.instructions, 0..) |inst, idx| {
            std.debug.print("Instr {d}: op={s}, arg={d}\n", .{idx, @tagName(inst.op), inst.arg});
        }
        self.last_result = null;
        if (self.frame_count >= 64) return error.StackOverflow;
        
        const starting_frame_count = self.frame_count;
        const globals_ptr = opt_globals orelse &self.globals;
        self.frames[self.frame_count] = PyFrameObject.init(self.allocator, code, globals_ptr, true);
        self.frame_count += 1;

        try self.runLoop(starting_frame_count);
        return self.last_result.?;
    }

    pub fn runLoop(self: *VM, starting_frame_count: usize) anyerror!void {
        const push = StackHelper.push;
        const pop = StackHelper.pop;

        var frame_idx = self.frame_count - 1;
        var f = &self.frames[frame_idx];
        var ip = f.ip;
        var stack_top = f.stack_top;
        var instructions = f.code.instructions;
        var consts = f.code.consts;
        var names = f.code.names;
        var varnames = f.code.varnames;
        var fastlocals = f.fastlocals;
        var globals = f.globals;
        var locals = &f.locals;
        var is_module = f.is_module;
        var is_class_body = f.is_class_body;
        var func = f.func;

        defer {
            if (frame_idx < self.frame_count) {
                self.frames[frame_idx].ip = ip;
                self.frames[frame_idx].stack_top = stack_top;
            }
        }

        while (self.frame_count > starting_frame_count) {
            if (self.frame_count - 1 != frame_idx) {
                if (frame_idx < self.frame_count) {
                    self.frames[frame_idx].ip = ip;
                    self.frames[frame_idx].stack_top = stack_top;
                }
                frame_idx = self.frame_count - 1;
                f = &self.frames[frame_idx];
                ip = f.ip;
                stack_top = f.stack_top;
                instructions = f.code.instructions;
                consts = f.code.consts;
                names = f.code.names;
                varnames = f.code.varnames;
                fastlocals = f.fastlocals;
                globals = f.globals;
                locals = &f.locals;
                is_module = f.is_module;
                is_class_body = f.is_class_body;
                func = f.func;
            }

            if (ip >= instructions.len) {
                // Implicit return None
                f.ip = ip;
                f.stack_top = stack_top;
                PyNone.incRef();
                self.popFrameAndPushResult(PyNone, starting_frame_count);
                continue;
            }

            const instr = instructions[ip];
            ip += 1;

            switch (instr.op) {
                .LOAD_CONST => {
                    const obj = consts[instr.arg];
                    obj.incRef();
                    push(f, &stack_top, obj);
                },
                .STORE_NAME => {
                    const obj = pop(f, &stack_top);
                    const name = names[instr.arg];
                    const map = if (is_class_body) locals else globals;
                    const g = try map.getOrPut(name);
                    if (g.found_existing) {
                        g.value_ptr.*.decRef(self.mm);
                    } else {
                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                    }
                    g.value_ptr.* = obj;
                },
                .LOAD_NAME => {
                    const name = names[instr.arg];
                    var found_obj: ?*PyObject = null;
                    if (!is_module) {
                        found_obj = locals.get(name);
                    }
                    if (found_obj == null) {
                        found_obj = globals.get(name);
                    }
                    
                    if (found_obj) |obj| {
                        obj.incRef();
                        push(f, &stack_top, obj);
                    } else {
                        std.debug.print("NameError: name '{s}' is not defined\n", .{name});
                        return error.NameError;
                    }
                },
                .BINARY_ADD => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a + val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_add) |add_fn| {
                            const res = try add_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_SUB => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a - val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_sub) |sub_fn| {
                            const res = try sub_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_MUL => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(val_a * val_b, self.mm);
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_mul) |mul_fn| {
                            const res = try mul_fn(a, b, self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .BINARY_DIV => {
                    const b = pop(f, &stack_top);
                    defer b.decRef(self.mm);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_truediv) |div_fn| {
                        const res = try div_fn(a, b, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .COMPARE_OP => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        const op: CompareOp = @enumFromInt(instr.arg);
                        const match = switch (op) {
                            .Lt => val_a < val_b,
                            .Le => val_a <= val_b,
                            .Eq => val_a == val_b,
                            .Ne => val_a != val_b,
                            .Gt => val_a > val_b,
                            .Ge => val_a >= val_b,
                        };
                        const res = if (match) PyTrue else PyFalse;
                        res.incRef();
                        a.decRef(self.mm);
                        b.decRef(self.mm);
                        push(f, &stack_top, res);
                    } else {
                        defer a.decRef(self.mm);
                        defer b.decRef(self.mm);
                        if (a.type_obj.tp_richcompare) |cmp_fn| {
                            const res = try cmp_fn(a, b, @enumFromInt(instr.arg), self.mm);
                            push(f, &stack_top, res);
                        } else {
                            return error.TypeError;
                        }
                    }
                },
                .PRINT_EXPR => {
                    const obj = pop(f, &stack_top);
                    defer obj.decRef(self.mm);

                    var str_obj: *PyObject = undefined;
                    if (obj.type_obj.tp_str) |str_fn| {
                        str_obj = try str_fn(obj, self.mm);
                    } else if (obj.type_obj.tp_repr) |repr_fn| {
                        str_obj = try repr_fn(obj, self.mm);
                    } else {
                        str_obj = try PyStringObject.create(obj.type_obj.name, self.mm);
                    }
                    defer str_obj.decRef(self.mm);

                    try self.stdout_writer.print("{s}\n", .{str_obj.as(PyStringObject).value()});
                },
                .RETURN_VALUE => {
                    const res = pop(f, &stack_top);
                    f.ip = ip;
                    f.stack_top = stack_top;
                    self.popFrameAndPushResult(res, starting_frame_count);
                },
                .JUMP_FORWARD => {
                    ip = instr.arg;
                },
                .JUMP_BACKWARD => {
                    ip = instr.arg;
                },
                .POP_JUMP_IF_FALSE => {
                    const cond_val = pop(f, &stack_top);
                    defer cond_val.decRef(self.mm);
                    if (!isTrue(cond_val)) {
                        ip = instr.arg;
                    }
                },
                .POP_JUMP_IF_TRUE => {
                    const cond_val = pop(f, &stack_top);
                    defer cond_val.decRef(self.mm);
                    if (isTrue(cond_val)) {
                        ip = instr.arg;
                    }
                },
                .UNARY_NOT => {
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    const res = if (isTrue(val)) PyFalse else PyTrue;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .JUMP_IF_FALSE_OR_POP => {
                    const cond = f.stack[stack_top - 1];
                    if (!isTrue(cond)) {
                        ip = instr.arg;
                    } else {
                        _ = pop(f, &stack_top);
                        cond.decRef(self.mm);
                    }
                },
                .JUMP_IF_TRUE_OR_POP => {
                    const cond = f.stack[stack_top - 1];
                    if (isTrue(cond)) {
                        ip = instr.arg;
                    } else {
                        _ = pop(f, &stack_top);
                        cond.decRef(self.mm);
                    }
                },
                .BUILD_LIST => {
                    const count = instr.arg;
                    const list = try PyListObject.create(count, self.mm);
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            list.items.?[count - 1 - i] = pop(f, &stack_top);
                        }
                        list.size = count;
                    }
                    push(f, &stack_top, &list.base);
                },
                .BUILD_TUPLE => {
                    const count = instr.arg;
                    const tuple = try PyTupleObject.create(count, self.mm);
                    const slice = tuple.items();
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            PyNone.decRef(self.mm);
                            slice[count - 1 - i] = pop(f, &stack_top);
                        }
                    }
                    push(f, &stack_top, &tuple.base);
                },
                .BUILD_MAP => {
                    const count = instr.arg;
                    const dict = try PyDictObject.create(self.mm);
                    errdefer dict.base.decRef(self.mm);
                    
                    var keys = try self.allocator.alloc(*PyObject, count);
                    defer self.allocator.free(keys);
                    var values = try self.allocator.alloc(*PyObject, count);
                    defer self.allocator.free(values);
                    
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        values[count - 1 - i] = pop(f, &stack_top);
                        keys[count - 1 - i] = pop(f, &stack_top);
                    }
                    
                    for (0..count) |idx| {
                        try dict.setItem(keys[idx], values[idx], self.mm);
                        keys[idx].decRef(self.mm);
                        values[idx].decRef(self.mm);
                    }
                    push(f, &stack_top, &dict.base);
                },
                .MAKE_FUNCTION => {
                    const code_obj = pop(f, &stack_top);
                    defer code_obj.decRef(self.mm);
                    
                    const func_obj = try PyFunctionObject.create(code_obj, globals, self.mm);
                    errdefer func_obj.base.decRef(self.mm);
                    
                    const code_wrapper = code_obj.as(PyCodeObjectWrapper);
                    const func_code = code_wrapper.code;
                    
                    for (func_code.instructions) |instr_val| {
                        if (instr_val.op == .LOAD_DEREF or instr_val.op == .STORE_DEREF or instr_val.op == .LOAD_CLOSURE) {
                            const name = func_code.names[instr_val.arg];
                            if (func_obj.closure.contains(name)) continue;
                            
                            var found_cell: ?*PyObject = null;
                            
                            if (locals.get(name)) |c| {
                                if (std.mem.eql(u8, c.type_obj.name, "cell")) {
                                    found_cell = c;
                                } else {
                                    const cell = try PyCellObject.create(c, self.mm);
                                    const g = try locals.getOrPut(name);
                                    if (!g.found_existing) {
                                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                                    }
                                    g.value_ptr.* = &cell.base;
                                    c.decRef(self.mm);
                                    found_cell = &cell.base;
                                }
                            } else if (func) |curr_func| {
                                if (curr_func.closure.get(name)) |c| {
                                    found_cell = c;
                                }
                            }
                            
                            if (found_cell == null) {
                                var idx = self.frame_count - 1;
                                while (idx > 0) {
                                    idx -= 1;
                                    const pf = &self.frames[idx];
                                    if (pf.locals.get(name)) |c| {
                                        if (std.mem.eql(u8, c.type_obj.name, "cell")) {
                                            found_cell = c;
                                        } else {
                                            const cell = try PyCellObject.create(c, self.mm);
                                            const g = try pf.locals.getOrPut(name);
                                            if (!g.found_existing) {
                                                g.key_ptr.* = try self.allocator.dupe(u8, name);
                                            }
                                            g.value_ptr.* = &cell.base;
                                            c.decRef(self.mm);
                                            found_cell = &cell.base;
                                        }
                                        break;
                                    }
                                }
                            }
                            
                            if (found_cell) |fc| {
                                fc.incRef();
                                try func_obj.closure.put(try self.allocator.dupe(u8, name), fc);
                            }
                        }
                    }
                    
                    push(f, &stack_top, &func_obj.base);
                },
                .CALL => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        stack_top -= 1;
                        args[argc - 1 - i] = f.stack[stack_top];
                    }
                    stack_top -= 1;
                    const callable = f.stack[stack_top];
                    defer callable.decRef(self.mm);
                    
                    f.ip = ip;
                    f.stack_top = stack_top;
                    
                    try self.callObject(callable, args, null);
                    
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .LOAD_ATTR => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const name = names[instr.arg];
                    const attr = try self.loadAttribute(inst, name);
                    push(f, &stack_top, attr);
                },
                .STORE_ATTR => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    const name = names[instr.arg];
                    try self.storeAttribute(inst, name, val);
                },
                .LOAD_METHOD => {
                    const inst = pop(f, &stack_top);
                    defer inst.decRef(self.mm);
                    const name = names[instr.arg];
                    const attr = try self.loadAttribute(inst, name);
                    push(f, &stack_top, attr);
                },
                .CALL_METHOD => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        stack_top -= 1;
                        args[argc - 1 - i] = f.stack[stack_top];
                    }
                    stack_top -= 1;
                    const callable = f.stack[stack_top];
                    defer callable.decRef(self.mm);
                    
                    f.ip = ip;
                    f.stack_top = stack_top;
                    
                    try self.callObject(callable, args, null);
                    
                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .SETUP_FINALLY => {
                    if (f.block_stack_top >= 16) return error.StackOverflow;
                    f.block_stack[f.block_stack_top] = .{
                        .type = .Finally,
                        .handler = instr.arg,
                        .stack_level = stack_top,
                    };
                    f.block_stack_top += 1;
                },
                .POP_BLOCK => {
                    if (f.block_stack_top == 0) return error.SystemError;
                    f.block_stack_top -= 1;
                },
                .RAISE_VARARGS => {
                    f.ip = ip;

                    if (instr.arg == 1) {
                        const exc = pop(f, &stack_top);
                        f.stack_top = stack_top;
                        try self.raiseException(exc);
                        exc.decRef(self.mm);
                    } else {
                        f.stack_top = stack_top;
                        if (f.active_exception) |ae| {
                            try self.raiseException(ae);
                        } else {
                            std.debug.print("RuntimeError: No active exception to re-raise\n", .{});
                            return error.RuntimeError;
                        }
                    }

                    frame_idx = self.frame_count - 1;
                    f = &self.frames[frame_idx];
                    ip = f.ip;
                    stack_top = f.stack_top;
                    instructions = f.code.instructions;
                    consts = f.code.consts;
                    names = f.code.names;
                    varnames = f.code.varnames;
                    fastlocals = f.fastlocals;
                    globals = f.globals;
                    locals = &f.locals;
                    is_module = f.is_module;
                    is_class_body = f.is_class_body;
                    func = f.func;
                },
                .LOAD_CLOSURE => {
                    const name = names[instr.arg];
                    var cell_obj: ?*PyObject = null;
                    if (locals.get(name)) |val| {
                        if (std.mem.eql(u8, val.type_obj.name, "cell")) {
                            cell_obj = val;
                        } else {
                            const cell = try PyCellObject.create(val, self.mm);
                            const g = try locals.getOrPut(name);
                            if (!g.found_existing) {
                                g.key_ptr.* = try self.allocator.dupe(u8, name);
                            }
                            g.value_ptr.* = &cell.base;
                            val.decRef(self.mm);
                            cell_obj = &cell.base;
                        }
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c;
                        }
                    }
                    
                    if (cell_obj) |co| {
                        co.incRef();
                        push(f, &stack_top, co);
                    } else {
                        const cell = try PyCellObject.create(null, self.mm);
                        const g = try locals.getOrPut(name);
                        if (g.found_existing) {
                            g.value_ptr.*.decRef(self.mm);
                        } else {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        cell.base.incRef();
                        push(f, &stack_top, &cell.base);
                    }
                },
                .LOAD_DEREF => {
                    const name = names[instr.arg];
                    var cell_val: ?*PyObject = null;
                    if (locals.get(name)) |c| {
                        cell_val = c.as(PyCellObject).value;
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_val = c.as(PyCellObject).value;
                        }
                    }
                    
                    if (cell_val) |cv| {
                        cv.incRef();
                        push(f, &stack_top, cv);
                    } else {
                        std.debug.print("NameError: free variable '{s}' referenced before assignment in enclosing scope\n", .{name});
                        return error.NameError;
                    }
                },
                .STORE_DEREF => {
                    const val = pop(f, &stack_top);
                    const name = names[instr.arg];
                    var cell_obj: ?*PyCellObject = null;
                    if (locals.get(name)) |c| {
                        cell_obj = c.as(PyCellObject);
                    } else if (func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c.as(PyCellObject);
                        }
                    }
                    
                    if (cell_obj) |co| {
                        if (co.value) |old_val| old_val.decRef(self.mm);
                        co.value = val;
                    } else {
                        const cell = try PyCellObject.create(val, self.mm);
                        const g = try locals.getOrPut(name);
                        if (g.found_existing) {
                            g.value_ptr.*.decRef(self.mm);
                        } else {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        val.decRef(self.mm);
                    }
                },
                .IMPORT_NAME => {
                    const name = names[instr.arg];
                    const mod = try @import("../import_system/import.zig").importModule(name, self);
                    push(f, &stack_top, mod);
                },
                .IMPORT_FROM => {
                    const mod = f.stack[stack_top - 1];
                    const name = names[instr.arg];
                    const val = try self.loadAttribute(mod, name);
                    push(f, &stack_top, val);
                },
                .POP_TOP => {
                    const obj = pop(f, &stack_top);
                    obj.decRef(self.mm);
                },
                .CHECK_EXCEPTION => {
                    const name = names[instr.arg];
                    const exc = f.stack[stack_top - 1];
                    const is_match = self.isExceptionMatch(exc, name);
                    
                    const res = if (is_match) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .LOAD_FAST => {
                    const idx = instr.arg;
                    if (fastlocals[idx]) |val| {
                        val.incRef();
                        push(f, &stack_top, val);
                    } else {
                        const name = varnames[idx];
                        std.debug.print("NameError: local variable '{s}' referenced before assignment\n", .{name});
                        return error.NameError;
                    }
                },
                .STORE_FAST => {
                    const val = pop(f, &stack_top);
                    const idx = instr.arg;
                    if (fastlocals[idx]) |old_val| {
                        old_val.decRef(self.mm);
                    }
                    fastlocals[idx] = val;
                },
                .BINARY_MOD => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b == 0) return error.ZeroDivisionError;
                        const res = try primitives.PyIntObject.create(@rem(val_a, val_b), self.mm);
                        push(f, &stack_top, res);
                    } else if (std.mem.eql(u8, a.type_obj.name, "float") or std.mem.eql(u8, b.type_obj.name, "float")) {
                        const fa = if (std.mem.eql(u8, a.type_obj.name, "float"))
                            a.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value));
                        const fb = if (std.mem.eql(u8, b.type_obj.name, "float"))
                            b.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value));
                        if (fb == 0.0) return error.ZeroDivisionError;
                        const res = try primitives.PyFloatObject.create(@mod(fa, fb), self.mm);
                        push(f, &stack_top, res);
                    } else if (std.mem.eql(u8, a.type_obj.name, "str")) {
                        // String formatting: "Hello %s" % "world"
                        // Simple: just use the string repr of b
                        const fmt_str = a.as(PyStringObject).value();
                        _ = fmt_str;
                        // For now, push a as-is (basic support)
                        a.incRef();
                        push(f, &stack_top, a);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_POW => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const base_val = a.as(primitives.PyIntObject).value;
                        const exp_val = b.as(primitives.PyIntObject).value;
                        var result: i64 = 1;
                        var i_exp: i64 = 0;
                        while (i_exp < exp_val) : (i_exp += 1) {
                            result = result * base_val;
                        }
                        const res = try primitives.PyIntObject.create(result, self.mm);
                        push(f, &stack_top, res);
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
                        const res = try primitives.PyFloatObject.create(std.math.pow(f64, fa, fb), self.mm);
                        push(f, &stack_top, res);
                    }
                },
                .BINARY_FLOOR_DIV => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);

                    if (std.mem.eql(u8, a.type_obj.name, "int") and std.mem.eql(u8, b.type_obj.name, "int")) {
                        const val_a = a.as(primitives.PyIntObject).value;
                        const val_b = b.as(primitives.PyIntObject).value;
                        if (val_b == 0) return error.ZeroDivisionError;
                        const res = try primitives.PyIntObject.create(@divFloor(val_a, val_b), self.mm);
                        push(f, &stack_top, res);
                    } else {
                        const fa = if (std.mem.eql(u8, a.type_obj.name, "float"))
                            a.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(a.as(primitives.PyIntObject).value));
                        const fb = if (std.mem.eql(u8, b.type_obj.name, "float"))
                            b.as(primitives.PyFloatObject).value
                        else
                            @as(f64, @floatFromInt(b.as(primitives.PyIntObject).value));
                        if (fb == 0.0) return error.ZeroDivisionError;
                        const res = try primitives.PyFloatObject.create(@floor(fa / fb), self.mm);
                        push(f, &stack_top, res);
                    }
                },
                .UNARY_NEG => {
                    const val = pop(f, &stack_top);
                    defer val.decRef(self.mm);
                    if (std.mem.eql(u8, val.type_obj.name, "int")) {
                        const v = val.as(primitives.PyIntObject).value;
                        const res = try primitives.PyIntObject.create(-v, self.mm);
                        push(f, &stack_top, res);
                    } else if (std.mem.eql(u8, val.type_obj.name, "float")) {
                        const v = val.as(primitives.PyFloatObject).value;
                        const res = try primitives.PyFloatObject.create(-v, self.mm);
                        push(f, &stack_top, res);
                    } else {
                        return error.TypeError;
                    }
                },
                .GET_ITER => {
                    // The iterable is on the stack. We push an iterator object.
                    // For simplicity, we use a PyListObject as a "materialized iterator":
                    // Convert range/list/tuple/str/dict to list, push [list, index=0]
                    const iterable = pop(f, &stack_top);
                    defer iterable.decRef(self.mm);
                    
                    const name = iterable.type_obj.name;
                    if (std.mem.eql(u8, name, "list")) {
                        // Already a list — wrap as iterator: push [list, 0]
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (std.mem.eql(u8, name, "tuple")) {
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (std.mem.eql(u8, name, "str")) {
                        // Convert string to list of chars
                        const str_val = iterable.as(PyStringObject).value();
                        const list = try PyListObject.create(str_val.len, self.mm);
                        for (str_val, 0..) |ch, i| {
                            const ch_str = try PyStringObject.create(str_val[i..i+1], self.mm);
                            _ = ch;
                            list.items.?[i] = ch_str;
                        }
                        list.size = str_val.len;
                        push(f, &stack_top, &list.base);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else if (std.mem.eql(u8, name, "dict")) {
                        // Iterate over dict keys
                        const dict = iterable.as(PyDictObject);
                        const list = try PyListObject.create(dict.active_count, self.mm);
                        var list_idx: usize = 0;
                        for (0..dict.entries_size) |i| {
                            if (dict.entries[i].key) |key| {
                                key.incRef();
                                list.items.?[list_idx] = key;
                                list_idx += 1;
                            }
                        }
                        list.size = list_idx;
                        push(f, &stack_top, &list.base);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    } else {
                        // Try if it's a range object (which is a list in our implementation)
                        iterable.incRef();
                        push(f, &stack_top, iterable);
                        const idx_obj = try primitives.PyIntObject.create(0, self.mm);
                        push(f, &stack_top, idx_obj);
                    }
                },
                .FOR_ITER => {
                    // Stack: [..., iterable, index]
                    // If index < len: push iterable[index], index += 1
                    // If index >= len: jump to arg (end of for loop)
                    const idx_obj = pop(f, &stack_top);
                    defer idx_obj.decRef(self.mm);
                    const iterable = f.stack[stack_top - 1]; // peek, don't pop
                    
                    const idx = idx_obj.as(primitives.PyIntObject).value;
                    const name = iterable.type_obj.name;
                    
                    var size: i64 = 0;
                    if (std.mem.eql(u8, name, "list")) {
                        size = @intCast(iterable.as(PyListObject).size);
                    } else if (std.mem.eql(u8, name, "tuple")) {
                        size = @intCast(iterable.as(PyTupleObject).size);
                    }
                    
                    if (idx < size) {
                        // Get item
                        var item: *PyObject = undefined;
                        if (std.mem.eql(u8, name, "list")) {
                            const list = iterable.as(PyListObject);
                            item = list.items.?[@intCast(idx)];
                        } else if (std.mem.eql(u8, name, "tuple")) {
                            const tuple = iterable.as(PyTupleObject);
                            item = tuple.items()[@intCast(idx)];
                        } else {
                            return error.TypeError;
                        }
                        
                        // Push next index
                        const new_idx = try primitives.PyIntObject.create(idx + 1, self.mm);
                        push(f, &stack_top, new_idx);
                        
                        // Push the item
                        item.incRef();
                        push(f, &stack_top, item);
                    } else {
                        // Iterator exhausted — jump to end
                        ip = instr.arg;
                    }
                },
                .BINARY_SUBSCR => {
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);
                    
                    const name = container.type_obj.name;
                    if (std.mem.eql(u8, name, "list")) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const item = list.items.?[@intCast(actual_idx)];
                        item.incRef();
                        push(f, &stack_top, item);
                    } else if (std.mem.eql(u8, name, "tuple")) {
                        const tuple = container.as(PyTupleObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(tuple.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(tuple.size))) {
                            return error.IndexError;
                        }
                        const item = tuple.items()[@intCast(actual_idx)];
                        item.incRef();
                        push(f, &stack_top, item);
                    } else if (std.mem.eql(u8, name, "dict")) {
                        const dict = container.as(PyDictObject);
                        if (try dict.getItem(index, self.mm)) |val| {
                            val.incRef();
                            push(f, &stack_top, val);
                        } else {
                            return error.KeyError;
                        }
                    } else if (std.mem.eql(u8, name, "str")) {
                        const str_val = container.as(PyStringObject).value();
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(str_val.len)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(str_val.len))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        const ch_str = try PyStringObject.create(str_val[uidx..uidx+1], self.mm);
                        push(f, &stack_top, ch_str);
                    } else {
                        return error.TypeError;
                    }
                },
                .STORE_SUBSCR => {
                    // Stack: value, container, index
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    const value = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);
                    defer value.decRef(self.mm);
                    
                    const name = container.type_obj.name;
                    if (std.mem.eql(u8, name, "list")) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        list.items.?[uidx].decRef(self.mm);
                        value.incRef();
                        list.items.?[uidx] = value;
                    } else if (std.mem.eql(u8, name, "dict")) {
                        const dict = container.as(PyDictObject);
                        try dict.setItem(index, value, self.mm);
                    } else {
                        return error.TypeError;
                    }
                },
                .DELETE_NAME => {
                    const name = names[instr.arg];
                    const map = if (is_class_body) locals else globals;
                    if (map.fetchRemove(name)) |kv| {
                        self.allocator.free(kv.key);
                        kv.value.decRef(self.mm);
                    }
                },
                .DELETE_FAST => {
                    const idx = instr.arg;
                    if (fastlocals[idx]) |val| {
                        val.decRef(self.mm);
                        fastlocals[idx] = null;
                    }
                },
                .DELETE_SUBSCR => {
                    // Stack: container, index
                    const index = pop(f, &stack_top);
                    const container = pop(f, &stack_top);
                    defer index.decRef(self.mm);
                    defer container.decRef(self.mm);
                    
                    const name = container.type_obj.name;
                    if (std.mem.eql(u8, name, "dict")) {
                        const dict = container.as(PyDictObject);
                        if (!try dict.delItem(index, self.mm)) {
                            // Key not found — Python does not raise on del for missing keys
                            // but we could print a warning
                        }
                    } else if (std.mem.eql(u8, name, "list")) {
                        const list = container.as(PyListObject);
                        const idx = index.as(primitives.PyIntObject).value;
                        const actual_idx = if (idx < 0) @as(i64, @intCast(list.size)) + idx else idx;
                        if (actual_idx < 0 or actual_idx >= @as(i64, @intCast(list.size))) {
                            return error.IndexError;
                        }
                        const uidx: usize = @intCast(actual_idx);
                        list.items.?[uidx].decRef(self.mm);
                        // Shift remaining items left
                        for (uidx..list.size - 1) |j| {
                            list.items.?[j] = list.items.?[j + 1];
                        }
                        list.size -= 1;
                    } else {
                        return error.TypeError;
                    }
                },
                .DELETE_ATTR => {
                    const obj = pop(f, &stack_top);
                    defer obj.decRef(self.mm);
                    const name = names[instr.arg];
                    const key_str = try PyStringObject.create(name, self.mm);
                    defer key_str.decRef(self.mm);
                    
                    if (std.mem.eql(u8, obj.type_obj.name, "object")) {
                        const instance = obj.as(PyInstanceObject);
                        const dict = instance.dict.as(PyDictObject);
                        _ = dict.delItem(key_str, self.mm) catch {};
                    } else {
                        return error.TypeError;
                    }
                },
                .IS_OP => {
                    const b = pop(f, &stack_top);
                    const a = pop(f, &stack_top);
                    defer a.decRef(self.mm);
                    defer b.decRef(self.mm);
                    const is_same = (a == b);
                    const result = if (instr.arg == 0) is_same else !is_same;
                    const res = if (result) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
                .CONTAINS_OP => {
                    const container = pop(f, &stack_top);
                    const item = pop(f, &stack_top);
                    defer container.decRef(self.mm);
                    defer item.decRef(self.mm);
                    
                    var found = false;
                    const name = container.type_obj.name;
                    if (std.mem.eql(u8, name, "list")) {
                        const list = container.as(PyListObject);
                        for (0..list.size) |i| {
                            const el = list.items.?[i];
                            if (try self.objectsEqual(el, item)) {
                                found = true;
                                break;
                            }
                        }
                    } else if (std.mem.eql(u8, name, "tuple")) {
                        const tuple = container.as(PyTupleObject);
                        for (tuple.items()) |el| {
                            if (try self.objectsEqual(el, item)) {
                                found = true;
                                break;
                            }
                        }
                    } else if (std.mem.eql(u8, name, "dict")) {
                        const dict = container.as(PyDictObject);
                        if (try dict.getItem(item, self.mm)) |_| {
                            found = true;
                        }
                    } else if (std.mem.eql(u8, name, "str")) {
                        const hay = container.as(PyStringObject).value();
                        const needle = item.as(PyStringObject).value();
                        found = std.mem.indexOf(u8, hay, needle) != null;
                    }
                    
                    const result = if (instr.arg == 0) found else !found;
                    const res = if (result) PyTrue else PyFalse;
                    res.incRef();
                    push(f, &stack_top, res);
                },
            }
        }
    }

    fn objectsEqual(self: *VM, a: *PyObject, b: *PyObject) anyerror!bool {
        if (a == b) return true;
        const name_a = a.type_obj.name;
        const name_b = b.type_obj.name;
        if (std.mem.eql(u8, name_a, "int") and std.mem.eql(u8, name_b, "int")) {
            return a.as(primitives.PyIntObject).value == b.as(primitives.PyIntObject).value;
        }
        if (std.mem.eql(u8, name_a, "str") and std.mem.eql(u8, name_b, "str")) {
            return std.mem.eql(u8, a.as(PyStringObject).value(), b.as(PyStringObject).value());
        }
        if (a.type_obj.tp_richcompare) |cmp_fn| {
            const res = try cmp_fn(a, b, .Eq, self.mm);
            defer res.decRef(self.mm);
            return res == PyTrue;
        }
        return false;
    }

    pub fn callCallable(self: *VM, callable: *PyObject, args: []*PyObject) anyerror!*PyObject {
        if (std.mem.eql(u8, callable.type_obj.name, "builtin_function")) {
            const func = callable.as(PyBuiltinFunctionObject);
            for (args) |arg| arg.incRef();
            const res = try func.func(args, self);
            return res;
        } else if (std.mem.eql(u8, callable.type_obj.name, "function")) {
            const func = callable.as(PyFunctionObject);
            const code_wrapper = func.code.as(PyCodeObjectWrapper);
            const func_code = code_wrapper.code;
            
            if (args.len != func_code.argcount) {
                std.debug.print("TypeError: expected {d} arguments, got {d}\n", .{func_code.argcount, args.len});
                return error.TypeError;
            }
            
            if (self.frame_count >= 64) return error.StackOverflow;
            
            var child_frame = PyFrameObject.init(self.allocator, func_code, func.globals, false);
            child_frame.func = func;
            func.base.incRef();
            
            for (args, 0..) |arg_val, arg_idx| {
                arg_val.incRef();
                child_frame.fastlocals[arg_idx] = arg_val;
            }
            
            const starting_frame_count = self.frame_count;
            self.frames[self.frame_count] = child_frame;
            self.frame_count += 1;
            
            const saved_result = self.last_result;
            defer self.last_result = saved_result;
            self.last_result = null;
            
            try self.runLoop(starting_frame_count);
            
            return self.last_result orelse PyNone;
        } else {
            return error.TypeError;
        }
    }
};


test "VM execution of simple arithmetic" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    // Dynamic output capture for test
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    // Bytecode to run: x = 10 + 20; print(x)
    // Consts: 10, 20, None
    // Names: "x"
    // Instructions:
    // 0: LOAD_CONST 0 (10)
    // 1: LOAD_CONST 1 (20)
    // 2: BINARY_ADD
    // 3: STORE_NAME 0 ("x")
    // 4: LOAD_NAME 0 ("x")
    // 5: PRINT_EXPR
    // 6: LOAD_CONST 2 (None)
    // 7: RETURN_VALUE

    const c10 = try primitives.PyIntObject.create(10, &mm);
    const c20 = try primitives.PyIntObject.create(20, &mm);
    PyNone.incRef();

    var consts = [_]*PyObject{ c10, c20, PyNone };
    var names = [_][]const u8{ try allocator.dupe(u8, "x") };

    var instrs = [_]Instruction{
        .{ .op = .LOAD_CONST, .arg = 0 },
        .{ .op = .LOAD_CONST, .arg = 1 },
        .{ .op = .BINARY_ADD },
        .{ .op = .STORE_NAME, .arg = 0 },
        .{ .op = .LOAD_NAME, .arg = 0 },
        .{ .op = .PRINT_EXPR },
        .{ .op = .LOAD_CONST, .arg = 2 },
        .{ .op = .RETURN_VALUE },
    };

    var code = PyCodeObject{
        .instructions = instrs[0..],
        .consts = consts[0..],
        .names = names[0..],
    };

    const res = try vm.run(&code, null);
    try testing.expectEqual(PyNone, res);

    try testing.expectEqualStrings("30\n", alloc_writer.written());

    c10.decRef(&mm);
    c20.decRef(&mm);

    // Free manually duplicated name
    allocator.free(names[0]);
    // Note: PyCodeObject deinit will be bypassed because we allocated static instrs/consts on stack
}

test "VM integration test - control flow and collections" {
    const Lexer = @import("../lexer/lexer.zig").Lexer;
    const Parser = @import("../parser/parser.zig").Parser;
    const Compiler = @import("../compiler/compiler.zig").Compiler;

    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    const src =
        \\x = 10
        \\if x > 5:
        \\    y = 100
        \\else:
        \\    y = 200
        \\print(y)
        \\
        \\a = 0
        \\b = 0
        \\while a < 5:
        \\    b = b + a
        \\    a = a + 1
        \\print(b)
        \\
        \\l = [1, 2]
        \\t = (3, 4)
        \\print(l)
        \\print(t)
    ;

    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module_ast = try parser.parseModule();

    var compiler = Compiler.init(arena.allocator(), &mm);
    defer compiler.deinit();

    var code = try compiler.compile(&module_ast);
    defer code.deinit(arena.allocator(), &mm);

    const res = try vm.run(&code, null);
    res.decRef(&mm);

    try testing.expectEqualStrings("100\n10\n[1, 2]\n(3, 4)\n", alloc_writer.written());
}

test "VM integration test - recursive function" {
    const Lexer = @import("../lexer/lexer.zig").Lexer;
    const Parser = @import("../parser/parser.zig").Parser;
    const Compiler = @import("../compiler/compiler.zig").Compiler;

    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var vm = try VM.init(allocator, &mm, &alloc_writer.writer, io);
    defer vm.deinit();

    const src =
        \\def fib(n):
        \\    if n <= 1:
        \\        return n
        \\    return fib(n-1) + fib(n-2)
        \\print(fib(5))
    ;

    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(&lexer, arena.allocator());
    const module_ast = try parser.parseModule();

    var compiler = Compiler.init(arena.allocator(), &mm);
    defer compiler.deinit();

    var code = try compiler.compile(&module_ast);
    defer code.deinit(arena.allocator(), &mm);

    const res = try vm.run(&code, null);
    res.decRef(&mm);

    try testing.expectEqualStrings("5\n", alloc_writer.written());
}

