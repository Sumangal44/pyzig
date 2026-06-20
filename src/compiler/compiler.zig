const std = @import("std");
const testing = std.testing;
const AST = @import("../ast/ast.zig").AST;
const Op = @import("../ast/ast.zig").Op;
const CompareOp = @import("../ast/ast.zig").CompareOp;
const PyObject = @import("../objects/object.zig").PyObject;
const PyMemoryManager = @import("../memory/allocator.zig").PyMemoryManager;
const primitives = @import("../objects/primitives.zig");
const PyNone = primitives.PyNone;
const PyTrue = primitives.PyTrue;
const PyFalse = primitives.PyFalse;
const PyIntObject = primitives.PyIntObject;
const PyFloatObject = primitives.PyFloatObject;
const PyStringObject = primitives.PyStringObject;
const PyInt_Type = primitives.PyInt_Type;
const PyFloat_Type = primitives.PyFloat_Type;
const PyString_Type = primitives.PyString_Type;
const bytecode = @import("../bytecode/bytecode.zig");
const Opcode = bytecode.Opcode;
const Instruction = bytecode.Instruction;
const PyCodeObject = bytecode.PyCodeObject;
const PyCodeObjectWrapper = bytecode.PyCodeObjectWrapper;


pub const Compiler = struct {
    allocator: std.mem.Allocator,
    mm: *PyMemoryManager,
    instructions: std.ArrayList(Instruction),
    consts: std.ArrayList(*PyObject),
    names: std.ArrayList([]const u8),
    nonlocals: std.StringHashMap(void),
    locals: std.StringHashMap(void),
    varnames: std.ArrayList([]const u8),
    is_function: bool = false,
    parent: ?*Compiler = null,

    pub fn init(allocator: std.mem.Allocator, mm: *PyMemoryManager) Compiler {
        return .{
            .allocator = allocator,
            .mm = mm,
            .instructions = std.ArrayList(Instruction).empty,
            .consts = std.ArrayList(*PyObject).empty,
            .names = std.ArrayList([]const u8).empty,
            .nonlocals = std.StringHashMap(void).init(allocator),
            .locals = std.StringHashMap(void).init(allocator),
            .varnames = std.ArrayList([]const u8).empty,
            .is_function = false,
            .parent = null,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instructions.deinit(self.allocator);
        for (self.consts.items) |c| {
            c.decRef(self.mm);
        }
        self.consts.deinit(self.allocator);
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
        for (self.varnames.items) |name| {
            self.allocator.free(name);
        }
        self.varnames.deinit(self.allocator);
        self.nonlocals.deinit();
        self.locals.deinit();
    }

    fn addVarname(self: *Compiler, name: []const u8) !u16 {
        for (self.varnames.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) {
                return @intCast(i);
            }
        }
        const name_copy = try self.allocator.dupe(u8, name);
        try self.varnames.append(self.allocator, name_copy);
        return @intCast(self.varnames.items.len - 1);
    }

    fn emitStore(self: *Compiler, name: []const u8) anyerror!void {
        if (self.nonlocals.contains(name) or try self.checkEnclosingScope(name)) {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .STORE_DEREF, .arg = name_idx });
        } else if (self.is_function and self.locals.contains(name)) {
            const var_idx = try self.addVarname(name);
            try self.instructions.append(self.allocator, .{ .op = .STORE_FAST, .arg = var_idx });
        } else {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .STORE_NAME, .arg = name_idx });
        }
    }

    fn emitLoad(self: *Compiler, name: []const u8) anyerror!void {
        if (self.nonlocals.contains(name) or try self.checkEnclosingScope(name)) {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .LOAD_DEREF, .arg = name_idx });
        } else if (self.is_function and self.locals.contains(name)) {
            const var_idx = try self.addVarname(name);
            try self.instructions.append(self.allocator, .{ .op = .LOAD_FAST, .arg = var_idx });
        } else {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .LOAD_NAME, .arg = name_idx });
        }
    }

    fn addConst(self: *Compiler, obj: *PyObject) !u16 {
        for (self.consts.items, 0..) |item, i| {
            if (item.type_obj == obj.type_obj) {
                if (item.type_obj == &PyInt_Type) {
                    if (item.as(PyIntObject).value == obj.as(PyIntObject).value) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                } else if (item.type_obj == &PyFloat_Type) {
                    if (item.as(PyFloatObject).value == obj.as(PyFloatObject).value) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                } else if (item.type_obj == &PyString_Type) {
                    if (std.mem.eql(u8, item.as(PyStringObject).value(), obj.as(PyStringObject).value())) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                } else if (item == PyNone or item == PyTrue or item == PyFalse) {
                    if (item == obj) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                }
            }
        }
        try self.consts.append(self.allocator, obj);
        return @intCast(self.consts.items.len - 1);
    }

    fn addName(self: *Compiler, name: []const u8) !u16 {
        for (self.names.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) {
                return @intCast(i);
            }
        }
        const name_copy = try self.allocator.dupe(u8, name);
        try self.names.append(self.allocator, name_copy);
        return @intCast(self.names.items.len - 1);
    }

    fn preScanLocals(self: *Compiler, body: []const AST) anyerror!void {
        for (body) |stmt| {
            switch (stmt) {
                .Assign => |assign| {
                    try self.locals.put(assign.target, {});
                },
                .FunctionDef => |func| {
                    try self.locals.put(func.name, {});
                },
                .ClassDef => |class_def| {
                    try self.locals.put(class_def.name, {});
                },
                .Try => |try_node| {
                    try self.preScanLocals(try_node.body);
                    for (try_node.handlers) |h| {
                        if (h.name) |as_name| {
                            try self.locals.put(as_name, {});
                        }
                        try self.preScanLocals(h.body);
                    }
                    try self.preScanLocals(try_node.finalbody);
                },
                .If => |if_node| {
                    try self.preScanLocals(if_node.body);
                    try self.preScanLocals(if_node.orelse_body);
                },
                .While => |while_node| {
                    try self.preScanLocals(while_node.body);
                },
                else => {},
            }
        }
    }

    fn checkEnclosingScope(self: *Compiler, name: []const u8) anyerror!bool {
        var curr = self.parent;
        while (curr) |c| {
            if (c.parent == null) break;
            if (c.locals.contains(name)) {
                try self.nonlocals.put(name, {});
                var temp = self.parent;
                while (temp != c) {
                    if (temp) |t| {
                        try t.nonlocals.put(name, {});
                        temp = t.parent;
                    } else break;
                }
                try c.nonlocals.put(name, {});
                return true;
            }
            curr = c.parent;
        }
        return false;
    }

    fn compileAST(self: *Compiler, node: *const AST) anyerror!void {
        switch (node.*) {
            .Module => |mod| {
                for (mod.body) |*stmt| {
                    try self.compileAST(stmt);
                }
            },
            .Assign => |assign| {
                try self.compileAST(assign.value);
                try self.emitStore(assign.target);
            },
            .BinOp => |binop| {
                try self.compileAST(binop.left);
                try self.compileAST(binop.right);
                const op = switch (binop.op) {
                    .Add => Opcode.BINARY_ADD,
                    .Sub => Opcode.BINARY_SUB,
                    .Mul => Opcode.BINARY_MUL,
                    .Div => Opcode.BINARY_DIV,
                };
                try self.instructions.append(self.allocator, .{ .op = op });
            },
            .Compare => |cmp| {
                try self.compileAST(cmp.left);
                try self.compileAST(cmp.right);
                try self.instructions.append(self.allocator, .{ .op = .COMPARE_OP, .arg = @intFromEnum(cmp.op) });
            },
            .Constant => |val| {
                const obj = switch (val) {
                    .None => blk: {
                        PyNone.incRef();
                        break :blk PyNone;
                    },
                    .Bool => |b| blk: {
                        const o = if (b) PyTrue else PyFalse;
                        o.incRef();
                        break :blk o;
                    },
                    .Int => |i| try PyIntObject.create(i, self.mm),
                    .Float => |f| try PyFloatObject.create(f, self.mm),
                    .String => |s| try PyStringObject.create(s, self.mm),
                };
                const const_idx = try self.addConst(obj);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
            },
            .Name => |name| {
                try self.emitLoad(name);
            },
            .Print => |p| {
                try self.compileAST(p.value);
                try self.instructions.append(self.allocator, .{ .op = .PRINT_EXPR });
            },
            .If => |if_node| {
                try self.compileAST(if_node.cond);
                const jump_false_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 });
                for (if_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                if (if_node.orelse_body.len > 0) {
                    const jump_forward_idx = self.instructions.items.len;
                    try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                    self.instructions.items[jump_false_idx].arg = @intCast(self.instructions.items.len);
                    for (if_node.orelse_body) |*stmt| {
                        try self.compileAST(stmt);
                    }
                    self.instructions.items[jump_forward_idx].arg = @intCast(self.instructions.items.len);
                } else {
                    self.instructions.items[jump_false_idx].arg = @intCast(self.instructions.items.len);
                }
            },
            .While => |while_node| {
                const loop_start = self.instructions.items.len;
                try self.compileAST(while_node.cond);
                const jump_false_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 });
                for (while_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                try self.instructions.append(self.allocator, .{ .op = .JUMP_BACKWARD, .arg = @intCast(loop_start) });
                self.instructions.items[jump_false_idx].arg = @intCast(self.instructions.items.len);
            },
            .List => |list_node| {
                for (list_node.elts) |*elt| {
                    try self.compileAST(elt);
                }
                try self.instructions.append(self.allocator, .{ .op = .BUILD_LIST, .arg = @intCast(list_node.elts.len) });
            },
            .Tuple => |tuple_node| {
                for (tuple_node.elts) |*elt| {
                    try self.compileAST(elt);
                }
                try self.instructions.append(self.allocator, .{ .op = .BUILD_TUPLE, .arg = @intCast(tuple_node.elts.len) });
            },
            .Dict => |dict_node| {
                for (dict_node.keys, 0..) |*key, i| {
                    try self.compileAST(key);
                    try self.compileAST(&dict_node.values[i]);
                }
                try self.instructions.append(self.allocator, .{ .op = .BUILD_MAP, .arg = @intCast(dict_node.keys.len) });
            },
            .FunctionDef => |func_def| {
                var child_compiler = Compiler.init(self.mm.allocator, self.mm);
                child_compiler.parent = self;
                child_compiler.is_function = true;
                defer child_compiler.deinit();
                
                // Add args to child compiler's varnames and locals
                for (func_def.args) |arg| {
                    try child_compiler.varnames.append(child_compiler.allocator, try child_compiler.allocator.dupe(u8, arg));
                    try child_compiler.locals.put(arg, {});
                }
                
                // Pre-scan locals in function body
                try child_compiler.preScanLocals(func_def.body);
                
                // Resolve scopes recursively
                try child_compiler.resolveFunctionScopes(func_def.body);
                
                for (func_def.body) |*stmt| {
                    try child_compiler.compileAST(stmt);
                }
                
                PyNone.incRef();
                const none_idx = try child_compiler.addConst(PyNone);
                try child_compiler.instructions.append(child_compiler.allocator, .{ .op = .LOAD_CONST, .arg = none_idx });
                try child_compiler.instructions.append(child_compiler.allocator, .{ .op = .RETURN_VALUE });
                
                const code_obj = try self.mm.allocator.create(PyCodeObject);
                errdefer self.mm.allocator.destroy(code_obj);
                
                // Move child_compiler.varnames to owned slice using mm.allocator (since PyCodeObject owns it)
                var child_varnames = try self.mm.allocator.alloc([]const u8, child_compiler.varnames.items.len);
                errdefer {
                    for (child_varnames) |name| self.mm.allocator.free(name);
                    self.mm.allocator.free(child_varnames);
                }
                for (child_compiler.varnames.items, 0..) |vname, i| {
                    child_varnames[i] = try self.mm.allocator.dupe(u8, vname);
                }
                
                code_obj.* = PyCodeObject{
                    .instructions = try child_compiler.instructions.toOwnedSlice(self.mm.allocator),
                    .consts = try child_compiler.consts.toOwnedSlice(self.mm.allocator),
                    .names = try child_compiler.names.toOwnedSlice(self.mm.allocator),
                    .argcount = func_def.args.len,
                    .varnames = child_varnames,
                };
                
                const wrapper = try PyCodeObjectWrapper.create(code_obj, self.mm);
                const const_idx = try self.addConst(wrapper);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
                try self.instructions.append(self.allocator, .{ .op = .MAKE_FUNCTION });
                try self.emitStore(func_def.name);
            },
            .Return => |ret| {
                if (ret.value) |val| {
                    try self.compileAST(val);
                } else {
                    PyNone.incRef();
                    const none_idx = try self.addConst(PyNone);
                    try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = none_idx });
                }
                try self.instructions.append(self.allocator, .{ .op = .RETURN_VALUE });
            },
            .Call => |call_node| {
                try self.compileAST(call_node.func);
                for (call_node.args) |*arg| {
                    try self.compileAST(arg);
                }
                try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = @intCast(call_node.args.len) });
            },
            .Pass => {},
            .ClassDef => |class_def| {
                const build_class_idx = try self.addName("__build_class__");
                try self.instructions.append(self.allocator, .{ .op = .LOAD_NAME, .arg = build_class_idx });
                
                const child_varnames = &[_][]const u8{};
                var child_compiler = Compiler.init(self.mm.allocator, self.mm);
                child_compiler.parent = self;
                defer child_compiler.deinit();
                
                try child_compiler.preScanLocals(class_def.body);
                for (class_def.body) |*stmt| {
                    try child_compiler.compileAST(stmt);
                }
                
                PyNone.incRef();
                const none_idx = try child_compiler.addConst(PyNone);
                try child_compiler.instructions.append(child_compiler.allocator, .{ .op = .LOAD_CONST, .arg = none_idx });
                try child_compiler.instructions.append(child_compiler.allocator, .{ .op = .RETURN_VALUE });
                
                const code_obj = try self.mm.allocator.create(PyCodeObject);
                errdefer self.mm.allocator.destroy(code_obj);
                code_obj.* = PyCodeObject{
                    .instructions = try child_compiler.instructions.toOwnedSlice(self.mm.allocator),
                    .consts = try child_compiler.consts.toOwnedSlice(self.mm.allocator),
                    .names = try child_compiler.names.toOwnedSlice(self.mm.allocator),
                    .argcount = 0,
                    .varnames = child_varnames,
                };
                
                const wrapper = try PyCodeObjectWrapper.create(code_obj, self.mm);
                const const_idx = try self.addConst(wrapper);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
                try self.instructions.append(self.allocator, .{ .op = .MAKE_FUNCTION });
                
                const name_str = try PyStringObject.create(class_def.name, self.mm);
                const name_const_idx = try self.addConst(name_str);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = name_const_idx });
                
                var argc: u16 = 2;
                if (class_def.base) |base_name| {
                    try self.emitLoad(base_name);
                    argc = 3;
                }
                
                try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = argc });
                
                try self.emitStore(class_def.name);
            },
            .Attribute => |attr_node| {
                try self.compileAST(attr_node.value);
                const attr_idx = try self.addName(attr_node.attr);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_ATTR, .arg = attr_idx });
            },
            .AssignAttr => |assign_attr| {
                try self.compileAST(assign_attr.expr);
                try self.compileAST(assign_attr.value);
                const attr_idx = try self.addName(assign_attr.attr);
                try self.instructions.append(self.allocator, .{ .op = .STORE_ATTR, .arg = attr_idx });
            },
            .Try => |try_node| {
                const has_finally = try_node.finalbody.len > 0;
                const has_except = try_node.handlers.len > 0;
                
                var finally_jump_idx: usize = 0;
                if (has_finally) {
                    finally_jump_idx = self.instructions.items.len;
                    try self.instructions.append(self.allocator, .{ .op = .SETUP_FINALLY, .arg = 0 });
                }
                
                var except_jump_idx: usize = 0;
                if (has_except) {
                    except_jump_idx = self.instructions.items.len;
                    try self.instructions.append(self.allocator, .{ .op = .SETUP_FINALLY, .arg = 0 });
                }
                
                for (try_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                
                if (has_except) {
                    try self.instructions.append(self.allocator, .{ .op = .POP_BLOCK });
                    const except_end_jump_idx = self.instructions.items.len;
                    try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                    
                    self.instructions.items[except_jump_idx].arg = @intCast(self.instructions.items.len);
                    
                    var jumps_to_end = std.ArrayList(usize).empty;
                    defer jumps_to_end.deinit(self.allocator);
                    
                    for (try_node.handlers) |h| {
                        if (h.type_name) |t_name| {
                            const t_idx = try self.addName(t_name);
                            try self.instructions.append(self.allocator, .{ .op = .CHECK_EXCEPTION, .arg = t_idx });
                            const next_handler_idx = self.instructions.items.len;
                            try self.instructions.append(self.allocator, .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 });
                            
                            if (h.name) |as_name| {
                                const as_idx = try self.addName(as_name);
                                try self.instructions.append(self.allocator, .{ .op = .STORE_NAME, .arg = as_idx });
                            } else {
                                try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
                            }
                            
                            for (h.body) |*stmt| {
                                try self.compileAST(stmt);
                            }
                            
                            const end_jmp = self.instructions.items.len;
                            try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                            try jumps_to_end.append(self.allocator, end_jmp);
                            
                            self.instructions.items[next_handler_idx].arg = @intCast(self.instructions.items.len);
                        } else {
                            try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
                            for (h.body) |*stmt| {
                                try self.compileAST(stmt);
                            }
                            const end_jmp = self.instructions.items.len;
                            try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                            try jumps_to_end.append(self.allocator, end_jmp);
                        }
                    }
                    
                    try self.instructions.append(self.allocator, .{ .op = .RAISE_VARARGS, .arg = 0 });
                    
                    const end_except_pos = self.instructions.items.len;
                    self.instructions.items[except_end_jump_idx].arg = @intCast(end_except_pos);
                    for (jumps_to_end.items) |jmp| {
                        self.instructions.items[jmp].arg = @intCast(end_except_pos);
                    }
                }
                
                if (has_finally) {
                    try self.instructions.append(self.allocator, .{ .op = .POP_BLOCK });
                    for (try_node.finalbody) |*stmt| {
                        try self.compileAST(stmt);
                    }
                    const finally_end_jump_idx = self.instructions.items.len;
                    try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                    
                    self.instructions.items[finally_jump_idx].arg = @intCast(self.instructions.items.len);
                    
                    for (try_node.finalbody) |*stmt| {
                        try self.compileAST(stmt);
                    }
                    try self.instructions.append(self.allocator, .{ .op = .RAISE_VARARGS, .arg = 0 });
                    
                    self.instructions.items[finally_end_jump_idx].arg = @intCast(self.instructions.items.len);
                }
            },
            .Raise => |raise_node| {
                if (raise_node.exc) |exc_ast| {
                    try self.compileAST(exc_ast);
                    try self.instructions.append(self.allocator, .{ .op = .RAISE_VARARGS, .arg = 1 });
                } else {
                    try self.instructions.append(self.allocator, .{ .op = .RAISE_VARARGS, .arg = 0 });
                }
            },
            .Nonlocal => |nonlocal_node| {
                for (nonlocal_node.names) |name| {
                    try self.nonlocals.put(name, {});
                }
            },
            .Import => |import_node| {
                for (import_node.names) |name| {
                    const name_idx = try self.addName(name);
                    try self.instructions.append(self.allocator, .{ .op = .IMPORT_NAME, .arg = name_idx });
                    try self.emitStore(name);
                }
            },
            .ImportFrom => |import_from| {
                const mod_idx = try self.addName(import_from.module);
                try self.instructions.append(self.allocator, .{ .op = .IMPORT_NAME, .arg = mod_idx });
                for (import_from.names) |name| {
                    const name_idx = try self.addName(name);
                    try self.instructions.append(self.allocator, .{ .op = .IMPORT_FROM, .arg = name_idx });
                    try self.emitStore(name);
                }
                try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
            },
        }
    }

    fn resolveFunctionScopes(self: *Compiler, body: []const AST) anyerror!void {
        for (body) |stmt| {
            try self.resolveScopesAST(&stmt);
        }
    }

    fn resolveScopesAST(self: *Compiler, node: *const AST) anyerror!void {
        switch (node.*) {
            .Module => |mod| {
                for (mod.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .Assign => |assign| {
                try self.resolveScopesAST(assign.value);
            },
            .BinOp => |binop| {
                try self.resolveScopesAST(binop.left);
                try self.resolveScopesAST(binop.right);
            },
            .Compare => |cmp| {
                try self.resolveScopesAST(cmp.left);
                try self.resolveScopesAST(cmp.right);
            },
            .Constant => {},
            .Name => |name| {
                _ = try self.checkEnclosingScope(name);
            },
            .Print => |p| {
                try self.resolveScopesAST(p.value);
            },
            .If => |if_node| {
                try self.resolveScopesAST(if_node.cond);
                for (if_node.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
                for (if_node.orelse_body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .While => |while_node| {
                try self.resolveScopesAST(while_node.cond);
                for (while_node.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .List => |list_node| {
                for (list_node.elts) |*elt| {
                    try self.resolveScopesAST(elt);
                }
            },
            .Tuple => |tuple_node| {
                for (tuple_node.elts) |*elt| {
                    try self.resolveScopesAST(elt);
                }
            },
            .Dict => |dict_node| {
                for (dict_node.keys, 0..) |*key, i| {
                    try self.resolveScopesAST(key);
                    try self.resolveScopesAST(&dict_node.values[i]);
                }
            },
            .FunctionDef => |func_def| {
                var child_compiler = Compiler.init(self.allocator, self.mm);
                child_compiler.parent = self;
                child_compiler.is_function = true;
                defer child_compiler.deinit();
                
                for (func_def.args) |arg| {
                    try child_compiler.locals.put(arg, {});
                }
                try child_compiler.preScanLocals(func_def.body);
                try child_compiler.resolveFunctionScopes(func_def.body);
            },
            .Return => |ret| {
                if (ret.value) |val| {
                    try self.resolveScopesAST(val);
                }
            },
            .Call => |call_node| {
                try self.resolveScopesAST(call_node.func);
                for (call_node.args) |*arg| {
                    try self.resolveScopesAST(arg);
                }
            },
            .ClassDef => |class_def| {
                var child_compiler = Compiler.init(self.allocator, self.mm);
                child_compiler.parent = self;
                child_compiler.is_function = false;
                defer child_compiler.deinit();
                
                try child_compiler.preScanLocals(class_def.body);
                try child_compiler.resolveFunctionScopes(class_def.body);
            },
            .Attribute => |attr_node| {
                try self.resolveScopesAST(attr_node.value);
            },
            .AssignAttr => |assign_attr| {
                try self.resolveScopesAST(assign_attr.expr);
                try self.resolveScopesAST(assign_attr.value);
            },
            .Try => |try_node| {
                for (try_node.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
                for (try_node.handlers) |*h| {
                    for (h.body) |*stmt| {
                        try self.resolveScopesAST(stmt);
                    }
                }
                for (try_node.finalbody) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .Raise => |raise_node| {
                if (raise_node.exc) |exc| {
                    try self.resolveScopesAST(exc);
                }
            },
            .Nonlocal => |nonlocal_node| {
                for (nonlocal_node.names) |name| {
                    try self.nonlocals.put(name, {});
                }
            },
            .Import => {},
            .ImportFrom => {},
            .Pass => {},
        }
    }

    pub fn compile(self: *Compiler, node: *const AST) anyerror!PyCodeObject {
        switch (node.*) {
            .Module => |mod| {
                try self.preScanLocals(mod.body);
                try self.resolveFunctionScopes(mod.body);
            },
            else => {},
        }
        
        try self.compileAST(node);

        // Implicit return None
        PyNone.incRef();
        const none_idx = try self.addConst(PyNone);
        try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = none_idx });
        try self.instructions.append(self.allocator, .{ .op = .RETURN_VALUE });

        return PyCodeObject{
            .instructions = try self.instructions.toOwnedSlice(self.allocator),
            .consts = try self.consts.toOwnedSlice(self.allocator),
            .names = try self.names.toOwnedSlice(self.allocator),
        };
    }
};

test "compiler basic assignment and binary addition" {
    const allocator = testing.allocator;
    var mm = PyMemoryManager.init(allocator);
    defer mm.deinit();

    var l_ptr = AST{ .Constant = .{ .Int = 10 } };
    var r_ptr = AST{ .Constant = .{ .Int = 20 } };

    const binop = AST{ .BinOp = .{ .op = .Add, .left = &l_ptr, .right = &r_ptr } };
    var binop_ptr = binop;

    const assign = AST{ .Assign = .{ .target = "x", .value = &binop_ptr } };

    var compiler = Compiler.init(allocator, &mm);
    defer compiler.deinit();

    var code = try compiler.compile(&assign);
    defer code.deinit(allocator, &mm);

    try testing.expectEqual(@as(usize, 6), code.instructions.len);
    try testing.expectEqual(Opcode.LOAD_CONST, code.instructions[0].op);
    try testing.expectEqual(Opcode.LOAD_CONST, code.instructions[1].op);
    try testing.expectEqual(Opcode.BINARY_ADD, code.instructions[2].op);
    try testing.expectEqual(Opcode.STORE_NAME, code.instructions[3].op);
    try testing.expectEqual(Opcode.LOAD_CONST, code.instructions[4].op); // return None
    try testing.expectEqual(Opcode.RETURN_VALUE, code.instructions[5].op);

    try testing.expectEqual(@as(usize, 3), code.consts.len);
    try testing.expectEqual(@as(usize, 1), code.names.len);
    try testing.expectEqualStrings("x", code.names[0]);
}
