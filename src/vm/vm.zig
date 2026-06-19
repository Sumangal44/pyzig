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

pub const PyFrameObject = struct {
    code: *PyCodeObject,
    ip: usize = 0,
    stack: [256]*PyObject = undefined,
    stack_top: usize = 0,
    locals: std.StringHashMap(*PyObject),
    globals: *std.StringHashMap(*PyObject),
    is_module: bool,
    
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
        return .{
            .code = code,
            .locals = std.StringHashMap(*PyObject).init(allocator),
            .globals = globals,
            .is_module = is_module,
        };
    }

    pub fn deinit(self: *PyFrameObject, mm: *PyMemoryManager, allocator: std.mem.Allocator) void {
        var it = self.locals.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.decRef(mm);
        }
        self.locals.deinit();
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

    pub fn push(self: *PyFrameObject, obj: *PyObject) void {
        if (self.stack_top >= 256) {
            @panic("Stack overflow");
        }
        self.stack[self.stack_top] = obj;
        self.stack_top += 1;
    }

    pub fn pop(self: *PyFrameObject) *PyObject {
        if (self.stack_top == 0) {
            @panic("Stack underflow");
        }
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }
};

fn isTrue(obj: *PyObject) bool {
    if (obj == PyTrue) return true;
    if (obj == PyFalse or obj == PyNone) return false;
    if (std.mem.eql(u8, obj.type_obj.name, "list")) {
        return obj.as(PyListObject).size > 0;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "tuple")) {
        return obj.as(PyTupleObject).size > 0;
    }
    if (std.mem.eql(u8, obj.type_obj.name, "dict")) {
        return obj.as(PyDictObject).active_count > 0;
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
        const wrapper = try @import("../stdlib/builtins.zig").PyTypeWrapper.create(&@import("../objects/exception.zig").PyException_Type, self.mm);
        const name_copy = try self.allocator.dupe(u8, "Exception");
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
        try vm.registerBuiltin("__build_class__", buildClass);
        try vm.registerExceptionClass();
        
        return vm;
    }

    pub fn deinit(self: *VM) void {
        var it = self.globals.iterator();
        while (it.next()) |entry| {
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
                if (base.type_obj == &@import("../stdlib/builtins.zig").PyTypeWrapper_Type) {
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
        if (std.mem.eql(u8, exc.type_obj.name, "exception")) {
            if (std.mem.eql(u8, type_name, "Exception")) return true;
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
                    if (bc.type_obj == &@import("../stdlib/builtins.zig").PyTypeWrapper_Type) {
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
                        if (bc.type_obj == &@import("../stdlib/builtins.zig").PyTypeWrapper_Type) {
                            return true;
                        }
                        c = bc.as(PyClassObject);
                    } else break;
                }
            }
        }
        return false;
    }

    fn loadAttribute(self: *VM, inst: *PyObject, name: []const u8) anyerror!*PyObject {

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

    fn storeAttribute(self: *VM, inst: *PyObject, name: []const u8, val: *PyObject) anyerror!void {
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
            
            var child_frame = PyFrameObject{
                .code = func_code,
                .ip = 0,
                .stack_top = 0,
                .locals = std.StringHashMap(*PyObject).init(self.allocator),
                .globals = func.globals,
                .is_module = false,
                .func = func,
                .init_instance = init_instance,
            };
            func.base.incRef();
            if (init_instance) |ii| ii.incRef();
            errdefer child_frame.deinit(self.mm, self.allocator);
            
            for (args, 0..) |arg_val, arg_idx| {
                const param_name = func_code.varnames[arg_idx];
                const param_name_copy = try self.allocator.dupe(u8, param_name);
                try child_frame.locals.put(param_name_copy, arg_val);
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
            if (callable.type_obj == &@import("../stdlib/builtins.zig").PyTypeWrapper_Type) {
                const wrapper = callable.as(@import("../stdlib/builtins.zig").PyTypeWrapper);
                if (std.mem.eql(u8, wrapper.type_ptr.name, "Exception")) {
                    const msg = if (args.len > 0) args[0] else try PyStringObject.create("", self.mm);
                    const exc = try PyExceptionObject.create(msg, self.mm);
                    f.push(&exc.base);
                    for (args) |arg| arg.decRef(self.mm);
                } else {
                    std.debug.print("TypeError: built-in type '{s}' is not subclassable or directly constructible here\n", .{wrapper.type_ptr.name});
                    for (args) |arg| arg.decRef(self.mm);
                    return error.TypeError;
                }
            } else {
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
        self.last_result = null;
        if (self.frame_count >= 64) return error.StackOverflow;
        
        const starting_frame_count = self.frame_count;
        const globals_ptr = opt_globals orelse &self.globals;
        self.frames[self.frame_count] = PyFrameObject.init(self.allocator, code, globals_ptr, true);
        self.frame_count += 1;

        while (self.frame_count > starting_frame_count) {
            const f = &self.frames[self.frame_count - 1];
            if (f.ip >= f.code.instructions.len) {
                // Implicit return None
                PyNone.incRef();
                self.popFrameAndPushResult(PyNone, starting_frame_count);
                continue;
            }

            const instr = f.code.instructions[f.ip];
            f.ip += 1;

            switch (instr.op) {
                .LOAD_CONST => {
                    const obj = f.code.consts[instr.arg];
                    obj.incRef();
                    f.push(obj);
                },
                .STORE_NAME => {
                    const obj = f.pop();
                    const name = f.code.names[instr.arg];
                    const map = if (f.is_module) f.globals else &f.locals;
                    const g = try map.getOrPut(name);
                    if (g.found_existing) {
                        g.value_ptr.*.decRef(self.mm);
                    } else {
                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                    }
                    g.value_ptr.* = obj;
                },
                .LOAD_NAME => {
                    const name = f.code.names[instr.arg];
                    var found_obj: ?*PyObject = null;
                    if (!f.is_module) {
                        found_obj = f.locals.get(name);
                    }
                    if (found_obj == null) {
                        found_obj = f.globals.get(name);
                    }
                    
                    if (found_obj) |obj| {
                        obj.incRef();
                        f.push(obj);
                    } else {
                        std.debug.print("NameError: name '{s}' is not defined\n", .{name});
                        return error.NameError;
                    }
                },
                .BINARY_ADD => {
                    const b = f.pop();
                    defer b.decRef(self.mm);
                    const a = f.pop();
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_add) |add_fn| {
                        const res = try add_fn(a, b, self.mm);
                        f.push(res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_SUB => {
                    const b = f.pop();
                    defer b.decRef(self.mm);
                    const a = f.pop();
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_sub) |sub_fn| {
                        const res = try sub_fn(a, b, self.mm);
                        f.push(res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_MUL => {
                    const b = f.pop();
                    defer b.decRef(self.mm);
                    const a = f.pop();
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_mul) |mul_fn| {
                        const res = try mul_fn(a, b, self.mm);
                        f.push(res);
                    } else {
                        return error.TypeError;
                    }
                },
                .BINARY_DIV => {
                    const b = f.pop();
                    defer b.decRef(self.mm);
                    const a = f.pop();
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_truediv) |div_fn| {
                        const res = try div_fn(a, b, self.mm);
                        f.push(res);
                    } else {
                        return error.TypeError;
                    }
                },
                .COMPARE_OP => {
                    const b = f.pop();
                    defer b.decRef(self.mm);
                    const a = f.pop();
                    defer a.decRef(self.mm);

                    if (a.type_obj.tp_richcompare) |cmp_fn| {
                        const res = try cmp_fn(a, b, @enumFromInt(instr.arg), self.mm);
                        f.push(res);
                    } else {
                        return error.TypeError;
                    }
                },
                .PRINT_EXPR => {
                    const obj = f.pop();
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
                    const res = f.pop();
                    self.popFrameAndPushResult(res, starting_frame_count);
                },
                .JUMP_FORWARD => {
                    f.ip = instr.arg;
                },
                .JUMP_BACKWARD => {
                    f.ip = instr.arg;
                },
                .POP_JUMP_IF_FALSE => {
                    const cond_val = f.pop();
                    defer cond_val.decRef(self.mm);
                    if (!isTrue(cond_val)) {
                        f.ip = instr.arg;
                    }
                },
                .POP_JUMP_IF_TRUE => {
                    const cond_val = f.pop();
                    defer cond_val.decRef(self.mm);
                    if (isTrue(cond_val)) {
                        f.ip = instr.arg;
                    }
                },
                .BUILD_LIST => {
                    const count = instr.arg;
                    const list = try PyListObject.create(count, self.mm);
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            list.items.?[count - 1 - i] = f.pop();
                        }
                        list.size = count;
                    }
                    f.push(&list.base);
                },
                .BUILD_TUPLE => {
                    const count = instr.arg;
                    const tuple = try PyTupleObject.create(count, self.mm);
                    const slice = tuple.items();
                    if (count > 0) {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            PyNone.decRef(self.mm);
                            slice[count - 1 - i] = f.pop();
                        }
                    }
                    f.push(&tuple.base);
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
                        values[count - 1 - i] = f.pop();
                        keys[count - 1 - i] = f.pop();
                    }
                    
                    for (0..count) |idx| {
                        try dict.setItem(keys[idx], values[idx], self.mm);
                        keys[idx].decRef(self.mm);
                        values[idx].decRef(self.mm);
                    }
                    f.push(&dict.base);
                },
                .MAKE_FUNCTION => {
                    const code_obj = f.pop();
                    defer code_obj.decRef(self.mm);
                    
                    const func = try PyFunctionObject.create(code_obj, f.globals, self.mm);
                    errdefer func.base.decRef(self.mm);
                    
                    const code_wrapper = code_obj.as(PyCodeObjectWrapper);
                    const func_code = code_wrapper.code;
                    
                    for (func_code.instructions) |instr_val| {
                        if (instr_val.op == .LOAD_DEREF or instr_val.op == .STORE_DEREF or instr_val.op == .LOAD_CLOSURE) {
                            const name = func_code.names[instr_val.arg];
                            if (func.closure.contains(name)) continue;
                            
                            var found_cell: ?*PyObject = null;
                            
                            if (f.locals.get(name)) |c| {
                                if (std.mem.eql(u8, c.type_obj.name, "cell")) {
                                    found_cell = c;
                                } else {
                                    const cell = try PyCellObject.create(c, self.mm);
                                    const g = try f.locals.getOrPut(name);
                                    if (!g.found_existing) {
                                        g.key_ptr.* = try self.allocator.dupe(u8, name);
                                    }
                                    g.value_ptr.* = &cell.base;
                                    c.decRef(self.mm);
                                    found_cell = &cell.base;
                                }
                            } else if (f.func) |curr_func| {
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
                                try func.closure.put(try self.allocator.dupe(u8, name), fc);
                            }
                        }
                    }
                    
                    f.push(&func.base);
                },
                .CALL => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        args[argc - 1 - i] = f.pop();
                    }
                    const callable = f.pop();
                    defer callable.decRef(self.mm);
                    
                    try self.callObject(callable, args, null);
                },
                .LOAD_ATTR => {
                    const inst = f.pop();
                    defer inst.decRef(self.mm);
                    const name = f.code.names[instr.arg];
                    const attr = try self.loadAttribute(inst, name);
                    f.push(attr);
                },
                .STORE_ATTR => {
                    const inst = f.pop();
                    defer inst.decRef(self.mm);
                    const val = f.pop();
                    defer val.decRef(self.mm);
                    const name = f.code.names[instr.arg];
                    try self.storeAttribute(inst, name, val);
                },
                .LOAD_METHOD => {
                    const inst = f.pop();
                    defer inst.decRef(self.mm);
                    const name = f.code.names[instr.arg];
                    const attr = try self.loadAttribute(inst, name);
                    f.push(attr);
                },
                .CALL_METHOD => {
                    const argc = instr.arg;
                    var args = try self.allocator.alloc(*PyObject, argc);
                    defer self.allocator.free(args);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        args[argc - 1 - i] = f.pop();
                    }
                    const callable = f.pop();
                    defer callable.decRef(self.mm);
                    
                    try self.callObject(callable, args, null);
                },
                .SETUP_FINALLY => {
                    if (f.block_stack_top >= 16) return error.StackOverflow;
                    f.block_stack[f.block_stack_top] = .{
                        .type = .Finally,
                        .handler = instr.arg,
                        .stack_level = f.stack_top,
                    };
                    f.block_stack_top += 1;
                },
                .POP_BLOCK => {
                    if (f.block_stack_top == 0) return error.SystemError;
                    f.block_stack_top -= 1;
                },
                .RAISE_VARARGS => {
                    if (instr.arg == 1) {
                        const exc = f.pop();
                        try self.raiseException(exc);
                        exc.decRef(self.mm);
                    } else {
                        if (f.active_exception) |ae| {
                            try self.raiseException(ae);
                        } else {
                            std.debug.print("RuntimeError: No active exception to re-raise\n", .{});
                            return error.RuntimeError;
                        }
                    }
                },
                .LOAD_CLOSURE => {
                    const name = f.code.names[instr.arg];
                    var cell_obj: ?*PyObject = null;
                    if (f.locals.get(name)) |val| {
                        if (std.mem.eql(u8, val.type_obj.name, "cell")) {
                            cell_obj = val;
                        } else {
                            const cell = try PyCellObject.create(val, self.mm);
                            const g = try f.locals.getOrPut(name);
                            if (!g.found_existing) {
                                g.key_ptr.* = try self.allocator.dupe(u8, name);
                            }
                            g.value_ptr.* = &cell.base;
                            val.decRef(self.mm);
                            cell_obj = &cell.base;
                        }
                    } else if (f.func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c;
                        }
                    }
                    
                    if (cell_obj) |co| {
                        co.incRef();
                        f.push(co);
                    } else {
                        const cell = try PyCellObject.create(null, self.mm);
                        const g = try f.locals.getOrPut(name);
                        if (g.found_existing) {
                            g.value_ptr.*.decRef(self.mm);
                        } else {
                            g.key_ptr.* = try self.allocator.dupe(u8, name);
                        }
                        g.value_ptr.* = &cell.base;
                        cell.base.incRef();
                        f.push(&cell.base);
                    }
                },
                .LOAD_DEREF => {
                    const name = f.code.names[instr.arg];
                    var cell_val: ?*PyObject = null;
                    if (f.locals.get(name)) |c| {
                        cell_val = c.as(PyCellObject).value;
                    } else if (f.func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_val = c.as(PyCellObject).value;
                        }
                    }
                    
                    if (cell_val) |cv| {
                        cv.incRef();
                        f.push(cv);
                    } else {
                        std.debug.print("NameError: free variable '{s}' referenced before assignment in enclosing scope\n", .{name});
                        return error.NameError;
                    }
                },
                .STORE_DEREF => {
                    const val = f.pop();
                    const name = f.code.names[instr.arg];
                    var cell_obj: ?*PyCellObject = null;
                    if (f.locals.get(name)) |c| {
                        cell_obj = c.as(PyCellObject);
                    } else if (f.func) |fu| {
                        if (fu.closure.get(name)) |c| {
                            cell_obj = c.as(PyCellObject);
                        }
                    }
                    
                    if (cell_obj) |co| {
                        if (co.value) |old_val| old_val.decRef(self.mm);
                        co.value = val;
                    } else {
                        const cell = try PyCellObject.create(val, self.mm);
                        const g = try f.locals.getOrPut(name);
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
                    const name = f.code.names[instr.arg];
                    const mod = try @import("../import_system/import.zig").importModule(name, self);
                    f.push(mod);
                },
                .IMPORT_FROM => {
                    const mod = f.stack[f.stack_top - 1];
                    const name = f.code.names[instr.arg];
                    const val = try self.loadAttribute(mod, name);
                    f.push(val);
                },
                .POP_TOP => {
                    const obj = f.pop();
                    obj.decRef(self.mm);
                },
                .CHECK_EXCEPTION => {
                    const name = f.code.names[instr.arg];
                    const exc = f.stack[f.stack_top - 1];
                    const is_match = self.isExceptionMatch(exc, name);
                    
                    const res = if (is_match) PyTrue else PyFalse;
                    res.incRef();
                    f.push(res);
                },
            }
        }

        return self.last_result.?;
    }
};


test "VM execution of simple arithmetic" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);

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

