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
const PyComplexObject = primitives.PyComplexObject;
const PyStringObject = primitives.PyStringObject;
const PyBytesObject = primitives.PyBytesObject;
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
    globals_set: std.StringHashMap(void),
    locals: std.StringHashMap(void),
    varnames: std.ArrayList([]const u8),
    is_function: bool = false,
    is_generator: bool = false,
    parent: ?*Compiler = null,
    // Loop context for break/continue
    loop_start_stack: std.ArrayList(usize),
    loop_break_patches: std.ArrayList(std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator, mm: *PyMemoryManager) Compiler {
        return .{
            .allocator = allocator,
            .mm = mm,
            .instructions = std.ArrayList(Instruction).empty,
            .consts = std.ArrayList(*PyObject).empty,
            .names = std.ArrayList([]const u8).empty,
            .nonlocals = std.StringHashMap(void).init(allocator),
            .globals_set = std.StringHashMap(void).init(allocator),
            .locals = std.StringHashMap(void).init(allocator),
            .varnames = std.ArrayList([]const u8).empty,
            .is_function = false,
            .is_generator = false,
            .parent = null,
            .loop_start_stack = std.ArrayList(usize).empty,
            .loop_break_patches = std.ArrayList(std.ArrayList(usize)).empty,
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
        self.globals_set.deinit();
        self.locals.deinit();
        self.loop_start_stack.deinit(self.allocator);
        for (self.loop_break_patches.items) |*bp| {
            bp.deinit(self.allocator);
        }
        self.loop_break_patches.deinit(self.allocator);
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
        // If marked as global, always use STORE_NAME (global scope)
        if (self.is_function and self.globals_set.contains(name)) {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .STORE_NAME, .arg = name_idx });
            return;
        }
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
        // If marked as global, always use LOAD_NAME (global scope)
        if (self.is_function and self.globals_set.contains(name)) {
            const name_idx = try self.addName(name);
            try self.instructions.append(self.allocator, .{ .op = .LOAD_NAME, .arg = name_idx });
            return;
        }
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

    fn emitDelete(self: *Compiler, target: *const AST) anyerror!void {
        switch (target.*) {
            .Name => |name| {
                if (self.is_function and self.locals.contains(name)) {
                    const var_idx = try self.addVarname(name);
                    try self.instructions.append(self.allocator, .{ .op = .DELETE_FAST, .arg = var_idx });
                } else {
                    const name_idx = try self.addName(name);
                    try self.instructions.append(self.allocator, .{ .op = .DELETE_NAME, .arg = name_idx });
                }
            },
            .Subscript => |sub| {
                try self.compileAST(sub.value);
                try self.compileAST(sub.index);
                try self.instructions.append(self.allocator, .{ .op = .DELETE_SUBSCR });
            },
            .Attribute => |attr| {
                try self.compileAST(attr.value);
                const attr_idx = try self.addName(attr.attr);
                try self.instructions.append(self.allocator, .{ .op = .DELETE_ATTR, .arg = attr_idx });
            },
            else => {
                return error.SyntaxError;
            },
        }
    }

    fn addConst(self: *Compiler, obj: *PyObject) !u16 {
        for (self.consts.items, 0..) |item, i| {
            const name = item.type_obj.name;
            const obj_name = obj.type_obj.name;
            if (std.mem.eql(u8, name, obj_name)) {
                if (std.mem.eql(u8, name, "int")) {
                    if (item.as(PyIntObject).value == obj.as(PyIntObject).value) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                } else if (std.mem.eql(u8, name, "float")) {
                    if (item.as(PyFloatObject).value == obj.as(PyFloatObject).value) {
                        obj.decRef(self.mm);
                        return @intCast(i);
                    }
                } else if (std.mem.eql(u8, name, "str")) {
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

    fn preScanExpr(self: *Compiler, node: *const AST) anyerror!void {
        switch (node.*) {
            .NamedExpr => |ne| {
                if (!self.globals_set.contains(ne.target)) {
                    try self.locals.put(ne.target, {});
                }
                try self.preScanExpr(ne.value);
            },
            .BinOp => |bin| {
                try self.preScanExpr(bin.left);
                try self.preScanExpr(bin.right);
            },
            .UnaryOp => |un| {
                try self.preScanExpr(un.operand);
            },
            .Compare => |cmp| {
                try self.preScanExpr(cmp.left);
                try self.preScanExpr(cmp.right);
            },
            .Call => |call| {
                try self.preScanExpr(call.func);
                for (call.args) |*arg| {
                    try self.preScanExpr(arg);
                }
            },
            .List => |lst| {
                for (lst.elts) |*elt| {
                    try self.preScanExpr(elt);
                }
            },
            .Tuple => |tup| {
                for (tup.elts) |*elt| {
                    try self.preScanExpr(elt);
                }
            },
            .Set => |set| {
                for (set.elts) |*elt| {
                    try self.preScanExpr(elt);
                }
            },
            .Dict => |dict| {
                for (dict.keys, 0..) |*key, i| {
                    try self.preScanExpr(key);
                    try self.preScanExpr(&dict.values[i]);
                }
            },
            .Attribute => |attr| {
                try self.preScanExpr(attr.value);
            },
            .Subscript => |sub| {
                try self.preScanExpr(sub.value);
                try self.preScanExpr(sub.index);
            },
            .Yield => |y| {
                if (y.value) |val| {
                    try self.preScanExpr(val);
                }
            },
            .YieldFrom => |yf| {
                try self.preScanExpr(yf.value);
            },
            .Await => |aw| {
                try self.preScanExpr(aw.value);
            },
            .LogicalOp => |log| {
                try self.preScanExpr(log.left);
                try self.preScanExpr(log.right);
            },
            .Expr => |e| {
                try self.preScanExpr(e.value);
            },
            else => {},
        }
    }

    fn preScanLocals(self: *Compiler, body: []const AST) anyerror!void {
        for (body) |stmt| {
            switch (stmt) {
                .Assign => |assign| {
                    if (!self.globals_set.contains(assign.target)) {
                        try self.locals.put(assign.target, {});
                    }
                    try self.preScanExpr(assign.value);
                },
                .AugAssign => |aug| {
                    if (!self.globals_set.contains(aug.target)) {
                        try self.locals.put(aug.target, {});
                    }
                    try self.preScanExpr(aug.value);
                },
                .FunctionDef => |func| {
                    try self.locals.put(func.name, {});
                    for (func.decorators) |*dec| {
                        try self.preScanExpr(dec);
                    }
                },
                .ClassDef => |class_def| {
                    try self.locals.put(class_def.name, {});
                    for (class_def.decorators) |*dec| {
                        try self.preScanExpr(dec);
                    }
                },
                .For => |for_node| {
                    if (!self.globals_set.contains(for_node.target)) {
                        try self.locals.put(for_node.target, {});
                    }
                    try self.preScanExpr(for_node.iter);
                    try self.preScanLocals(for_node.body);
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
                    try self.preScanExpr(if_node.cond);
                    try self.preScanLocals(if_node.body);
                    try self.preScanLocals(if_node.orelse_body);
                },
                .While => |while_node| {
                    try self.preScanExpr(while_node.cond);
                    try self.preScanLocals(while_node.body);
                },
                .With => |with_node| {
                    for (with_node.items) |item| {
                        try self.preScanExpr(&item.context_expr);
                        if (item.optional_vars) |vars| {
                            try self.preScanExpr(vars);
                        }
                    }
                    try self.preScanLocals(with_node.body);
                },
                .Return => |ret| {
                    if (ret.value) |val| {
                        try self.preScanExpr(val);
                    }
                },
                .Raise => |raise_node| {
                    if (raise_node.exc) |exc| {
                        try self.preScanExpr(exc);
                    }
                },
                .Global => |global_node| {
                    for (global_node.names) |name| {
                        try self.globals_set.put(name, {});
                    }
                },
                else => {
                    try self.preScanExpr(&stmt);
                },
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

    fn processEscapes(self: *Compiler, input: []const u8) ![]const u8 {
        // Check if there are any escape sequences
        var has_escape = false;
        for (input) |ch| {
            if (ch == '\\') {
                has_escape = true;
                break;
            }
        }
        if (!has_escape) return input;

        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);
        
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                const next = input[i + 1];
                switch (next) {
                    'n' => { try result.append(self.allocator, '\n'); i += 2; },
                    't' => { try result.append(self.allocator, '\t'); i += 2; },
                    'r' => { try result.append(self.allocator, '\r'); i += 2; },
                    '\\' => { try result.append(self.allocator, '\\'); i += 2; },
                    '\'' => { try result.append(self.allocator, '\''); i += 2; },
                    '"' => { try result.append(self.allocator, '"'); i += 2; },
                    '0' => { try result.append(self.allocator, 0); i += 2; },
                    else => { try result.append(self.allocator, '\\'); try result.append(self.allocator, next); i += 2; },
                }
            } else {
                try result.append(self.allocator, input[i]);
                i += 1;
            }
        }
        return try self.allocator.dupe(u8, result.items);
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
            .AugAssign => |aug| {
                try self.emitLoad(aug.target);
                try self.compileAST(aug.value);
                const op = switch (aug.op) {
                    .Add => Opcode.BINARY_ADD,
                    .Sub => Opcode.BINARY_SUB,
                    .Mul => Opcode.BINARY_MUL,
                    .Div => Opcode.BINARY_DIV,
                    .Mod => Opcode.BINARY_MOD,
                    .Pow => Opcode.BINARY_POW,
                    .FloorDiv => Opcode.BINARY_FLOOR_DIV,
                    .And => Opcode.BINARY_AND,
                    .Or => Opcode.BINARY_OR,
                    .Xor => Opcode.BINARY_XOR,
                    .LShift => Opcode.BINARY_LSHIFT,
                    .RShift => Opcode.BINARY_RSHIFT,
                    .MatMul => Opcode.BINARY_MATRIX_MULTIPLY,
                };
                try self.instructions.append(self.allocator, .{ .op = op });
                try self.emitStore(aug.target);
            },
            .BinOp => |binop| {
                try self.compileAST(binop.left);
                try self.compileAST(binop.right);
                const op = switch (binop.op) {
                    .Add => Opcode.BINARY_ADD,
                    .Sub => Opcode.BINARY_SUB,
                    .Mul => Opcode.BINARY_MUL,
                    .Div => Opcode.BINARY_DIV,
                    .Mod => Opcode.BINARY_MOD,
                    .Pow => Opcode.BINARY_POW,
                    .FloorDiv => Opcode.BINARY_FLOOR_DIV,
                    .And => Opcode.BINARY_AND,
                    .Or => Opcode.BINARY_OR,
                    .Xor => Opcode.BINARY_XOR,
                    .LShift => Opcode.BINARY_LSHIFT,
                    .RShift => Opcode.BINARY_RSHIFT,
                    .MatMul => Opcode.BINARY_MATRIX_MULTIPLY,
                };
                try self.instructions.append(self.allocator, .{ .op = op });
            },
            .Compare => |cmp| {
                try self.compileAST(cmp.left);
                try self.compileAST(cmp.right);
                switch (cmp.op) {
                    .Is => try self.instructions.append(self.allocator, .{ .op = .IS_OP, .arg = 0 }),
                    .IsNot => try self.instructions.append(self.allocator, .{ .op = .IS_OP, .arg = 1 }),
                    .In => try self.instructions.append(self.allocator, .{ .op = .CONTAINS_OP, .arg = 0 }),
                    .NotIn => try self.instructions.append(self.allocator, .{ .op = .CONTAINS_OP, .arg = 1 }),
                    else => try self.instructions.append(self.allocator, .{ .op = .COMPARE_OP, .arg = @intFromEnum(cmp.op) }),
                }
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
                    .Float => |f_val| try PyFloatObject.create(f_val, self.mm),
                    .Complex => |c| try PyComplexObject.create(c.real, c.imag, self.mm),
                    .String => |s| blk: {
                        const processed = try self.processEscapes(s);
                        break :blk try PyStringObject.create(processed, self.mm);
                    },
                    .Bytes => |b| blk: {
                        const processed = try self.processEscapes(b);
                        break :blk try PyBytesObject.create(processed, self.mm);
                    },
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
                
                // Push loop context
                try self.loop_start_stack.append(self.allocator, loop_start);
                var break_patches = std.ArrayList(usize).empty;
                try self.loop_break_patches.append(self.allocator, break_patches);
                
                try self.compileAST(while_node.cond);
                const jump_false_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .POP_JUMP_IF_FALSE, .arg = 0 });
                for (while_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                try self.instructions.append(self.allocator, .{ .op = .JUMP_BACKWARD, .arg = @intCast(loop_start) });
                self.instructions.items[jump_false_idx].arg = @intCast(self.instructions.items.len);
                
                // Patch break jumps
                break_patches = self.loop_break_patches.pop().?;
                for (break_patches.items) |bp| {
                    self.instructions.items[bp].arg = @intCast(self.instructions.items.len);
                }
                break_patches.deinit(self.allocator);
                _ = self.loop_start_stack.pop().?;
            },
            .For => |for_node| {
                // Compile the iterable expression
                try self.compileAST(for_node.iter);
                // GET_ITER: convert to iterator
                try self.instructions.append(self.allocator, .{ .op = .GET_ITER });
                
                const loop_start = self.instructions.items.len;
                
                // Push loop context
                try self.loop_start_stack.append(self.allocator, loop_start);
                var break_patches = std.ArrayList(usize).empty;
                try self.loop_break_patches.append(self.allocator, break_patches);
                
                // FOR_ITER: get next item or jump to end
                const for_iter_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .FOR_ITER, .arg = 0 });
                
                // Store the loop variable
                try self.emitStore(for_node.target);
                
                // Compile loop body
                for (for_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                
                // Jump back to FOR_ITER
                try self.instructions.append(self.allocator, .{ .op = .JUMP_BACKWARD, .arg = @intCast(loop_start) });
                
                // Patch FOR_ITER jump target
                self.instructions.items[for_iter_idx].arg = @intCast(self.instructions.items.len);
                
                // Pop the iterator (exhausted)
                try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
                
                // Patch break jumps
                break_patches = self.loop_break_patches.pop().?;
                for (break_patches.items) |bp| {
                    self.instructions.items[bp].arg = @intCast(self.instructions.items.len);
                }
                break_patches.deinit(self.allocator);
                _ = self.loop_start_stack.pop().?;
            },
            .Break => {
                if (self.loop_break_patches.items.len == 0) {
                    return error.SyntaxError; // break outside loop
                }
                const bp_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .JUMP_FORWARD, .arg = 0 });
                try self.loop_break_patches.items[self.loop_break_patches.items.len - 1].append(self.allocator, bp_idx);
            },
            .Continue => {
                if (self.loop_start_stack.items.len == 0) {
                    return error.SyntaxError; // continue outside loop
                }
                const loop_start = self.loop_start_stack.items[self.loop_start_stack.items.len - 1];
                try self.instructions.append(self.allocator, .{ .op = .JUMP_BACKWARD, .arg = @intCast(loop_start) });
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
            .Set => |set_node| {
                for (set_node.elts) |*elt| {
                    try self.compileAST(elt);
                }
                try self.instructions.append(self.allocator, .{ .op = .BUILD_SET, .arg = @intCast(set_node.elts.len) });
            },
            .FunctionDef => |func_def| {
                // Compile decorators first (top-to-bottom)
                for (func_def.decorators) |*dec| {
                    try self.compileAST(dec);
                }

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
                    .is_generator = child_compiler.is_generator,
                };
                
                const wrapper = try PyCodeObjectWrapper.create(code_obj, self.mm);
                const const_idx = try self.addConst(wrapper);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
                try self.instructions.append(self.allocator, .{ .op = .MAKE_FUNCTION });
                
                // If decorators are present, apply them in reverse order
                var i: usize = func_def.decorators.len;
                while (i > 0) {
                    i -= 1;
                    try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = 1 });
                }

                try self.emitStore(func_def.name);
            },
            .Lambda => |lambda_node| {
                var child_compiler = Compiler.init(self.mm.allocator, self.mm);
                child_compiler.parent = self;
                child_compiler.is_function = true;
                defer child_compiler.deinit();
                
                for (lambda_node.args) |arg| {
                    try child_compiler.varnames.append(child_compiler.allocator, try child_compiler.allocator.dupe(u8, arg));
                    try child_compiler.locals.put(arg, {});
                }
                
                // Lambda body is a single expression — compile and return
                try child_compiler.compileAST(lambda_node.body);
                try child_compiler.instructions.append(child_compiler.allocator, .{ .op = .RETURN_VALUE });
                
                const code_obj = try self.mm.allocator.create(PyCodeObject);
                errdefer self.mm.allocator.destroy(code_obj);
                
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
                    .argcount = lambda_node.args.len,
                    .varnames = child_varnames,
                    .is_generator = child_compiler.is_generator,
                };
                
                const wrapper_obj = try PyCodeObjectWrapper.create(code_obj, self.mm);
                const const_idx = try self.addConst(wrapper_obj);
                try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
                try self.instructions.append(self.allocator, .{ .op = .MAKE_FUNCTION });
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
            .Expr => |expr_node| {
                try self.compileAST(expr_node.value);
                try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
            },
            .Pass => {},
            .ClassDef => |class_def| {
                // Compile decorators first (top-to-bottom)
                for (class_def.decorators) |*dec| {
                    try self.compileAST(dec);
                }

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
                
                // If decorators are present, apply them in reverse order
                var i: usize = class_def.decorators.len;
                while (i > 0) {
                    i -= 1;
                    try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = 1 });
                }

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
            .Subscript => |sub| {
                try self.compileAST(sub.value);
                try self.compileAST(sub.index);
                try self.instructions.append(self.allocator, .{ .op = .BINARY_SUBSCR });
            },
            .AssignSubscript => |asub| {
                try self.compileAST(asub.expr);
                try self.compileAST(asub.value);
                try self.compileAST(asub.index);
                try self.instructions.append(self.allocator, .{ .op = .STORE_SUBSCR });
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
            .Global => |global_node| {
                for (global_node.names) |name| {
                    try self.globals_set.put(name, {});
                }
            },
            .Assert => |assert_node| {
                // Compile: if not test_expr: raise AssertionError(msg)
                try self.compileAST(assert_node.test_expr);
                const jump_idx = self.instructions.items.len;
                try self.instructions.append(self.allocator, .{ .op = .POP_JUMP_IF_TRUE, .arg = 0 });
                
                // Load AssertionError and call it
                const exc_idx = try self.addName("AssertionError");
                try self.instructions.append(self.allocator, .{ .op = .LOAD_NAME, .arg = exc_idx });
                if (assert_node.msg) |msg| {
                    try self.compileAST(msg);
                    try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = 1 });
                } else {
                    try self.instructions.append(self.allocator, .{ .op = .CALL, .arg = 0 });
                }
                try self.instructions.append(self.allocator, .{ .op = .RAISE_VARARGS, .arg = 1 });
                
                self.instructions.items[jump_idx].arg = @intCast(self.instructions.items.len);
            },
            .Del => |del_node| {
                try self.emitDelete(del_node.target);
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
            .LogicalOp => |logop| {
                try self.compileAST(logop.left);
                const jump_idx = self.instructions.items.len;
                const op = switch (logop.op) {
                    .And => Opcode.JUMP_IF_FALSE_OR_POP,
                    .Or => Opcode.JUMP_IF_TRUE_OR_POP,
                };
                try self.instructions.append(self.allocator, .{ .op = op, .arg = 0 });
                try self.compileAST(logop.right);
                self.instructions.items[jump_idx].arg = @intCast(self.instructions.items.len);
            },
            .UnaryOp => |unop| {
                try self.compileAST(unop.operand);
                const op = switch (unop.op) {
                    .Not => Opcode.UNARY_NOT,
                    .Neg => Opcode.UNARY_NEG,
                    .Invert => Opcode.UNARY_INVERT,
                };
                try self.instructions.append(self.allocator, .{ .op = op });
            },
            .NamedExpr => |ne| {
                try self.compileAST(ne.value);
                try self.emitStore(ne.target);
                try self.emitLoad(ne.target);
            },
            .Yield => |y| {
                self.is_generator = true;
                if (y.value) |val| {
                    try self.compileAST(val);
                } else {
                    const py_none = @import("../objects/primitives.zig").PyNone;
                    py_none.incRef();
                    const const_idx = try self.addConst(py_none);
                    try self.instructions.append(self.allocator, .{ .op = .LOAD_CONST, .arg = const_idx });
                }
                try self.instructions.append(self.allocator, .{ .op = .YIELD_VALUE });
            },
            .YieldFrom => |yf| {
                self.is_generator = true;
                try self.compileAST(yf.value);
                try self.instructions.append(self.allocator, .{ .op = .YIELD_VALUE });
            },
            .With => |with_node| {
                for (with_node.items) |item| {
                    try self.compileAST(&item.context_expr);
                    try self.instructions.append(self.allocator, .{ .op = .BEFORE_WITH });
                    if (item.optional_vars) |vars| {
                        switch (vars.*) {
                            .Name => |n| try self.emitStore(n),
                            else => unreachable,
                        }
                    } else {
                        try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
                    }
                }
                for (with_node.body) |*stmt| {
                    try self.compileAST(stmt);
                }
                try self.instructions.append(self.allocator, .{ .op = .EXIT_WITH });
                try self.instructions.append(self.allocator, .{ .op = .POP_TOP });
            },
            .Await => |a| {
                try self.compileAST(a.value);
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
            .AugAssign => |aug| {
                _ = try self.checkEnclosingScope(aug.target);
                try self.resolveScopesAST(aug.value);
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
            .For => |for_node| {
                try self.resolveScopesAST(for_node.iter);
                for (for_node.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .Break, .Continue => {},
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
            .Set => |set_node| {
                for (set_node.elts) |*elt| {
                    try self.resolveScopesAST(elt);
                }
            },
            .FunctionDef => |func_def| {
                for (func_def.decorators) |*dec| {
                    try self.resolveScopesAST(dec);
                }
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
            .Lambda => |lambda_node| {
                try self.resolveScopesAST(lambda_node.body);
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
                for (class_def.decorators) |*dec| {
                    try self.resolveScopesAST(dec);
                }
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
            .Subscript => |sub| {
                try self.resolveScopesAST(sub.value);
                try self.resolveScopesAST(sub.index);
            },
            .AssignSubscript => |asub| {
                try self.resolveScopesAST(asub.value);
                try self.resolveScopesAST(asub.index);
                try self.resolveScopesAST(asub.expr);
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
            .Global => |global_node| {
                for (global_node.names) |name| {
                    try self.globals_set.put(name, {});
                }
            },
            .Assert => |assert_node| {
                try self.resolveScopesAST(assert_node.test_expr);
                if (assert_node.msg) |msg| {
                    try self.resolveScopesAST(msg);
                }
            },
            .Del => |del_node| {
                try self.resolveScopesAST(del_node.target);
            },
            .Import => {},
            .ImportFrom => {},
            .Pass => {},
            .LogicalOp => |logop| {
                try self.resolveScopesAST(logop.left);
                try self.resolveScopesAST(logop.right);
            },
            .UnaryOp => |unop| {
                try self.resolveScopesAST(unop.operand);
            },
            .NamedExpr => |ne| {
                try self.resolveScopesAST(ne.value);
                _ = try self.checkEnclosingScope(ne.target);
            },
            .Yield => |y| {
                if (y.value) |val| {
                    try self.resolveScopesAST(val);
                }
            },
            .YieldFrom => |yf| {
                try self.resolveScopesAST(yf.value);
            },
            .With => |with_node| {
                for (with_node.items) |item| {
                    try self.resolveScopesAST(&item.context_expr);
                    if (item.optional_vars) |vars| {
                        try self.resolveScopesAST(vars);
                    }
                }
                for (with_node.body) |*stmt| {
                    try self.resolveScopesAST(stmt);
                }
            },
            .Await => |a| {
                try self.resolveScopesAST(a.value);
            },
            .Expr => |e| {
                try self.resolveScopesAST(e.value);
            },
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
