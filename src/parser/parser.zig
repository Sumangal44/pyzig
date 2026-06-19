const std = @import("std");
const testing = std.testing;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Token = @import("../lexer/lexer.zig").Token;
const TokenType = @import("../lexer/lexer.zig").TokenType;
const AST = @import("../ast/ast.zig").AST;
const ASTBuilder = @import("../ast/ast.zig").ASTBuilder;
const Op = @import("../ast/ast.zig").Op;
const CompareOp = @import("../ast/ast.zig").CompareOp;
const ExceptHandler = @import("../ast/ast.zig").ExceptHandler;

pub const Parser = struct {
    lexer: *Lexer,
    current_token: Token,
    builder: ASTBuilder,

    const ParserState = struct {
        lexer_state: Lexer.State,
        current_token: Token,
    };

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var p = Parser{
            .lexer = lexer,
            .current_token = undefined,
            .builder = ASTBuilder.init(allocator),
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lexer.next();
    }

    fn peekType(self: Parser) TokenType {
        return self.current_token.type;
    }

    fn match(self: *Parser, t_type: TokenType) bool {
        if (self.peekType() == t_type) {
            self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *Parser, t_type: TokenType, err_msg: []const u8) !void {
        if (self.peekType() == t_type) {
            self.advance();
            return;
        }
        std.debug.print("Error at token '{s}' (line {d}, col {d}): {s}\n", .{self.current_token.lexeme, self.current_token.line, self.current_token.column, err_msg});
        return error.ParseError;
    }

    fn saveState(self: Parser) ParserState {
        return .{
            .lexer_state = self.lexer.save(),
            .current_token = self.current_token,
        };
    }

    fn restoreState(self: *Parser, state: ParserState) void {
        self.lexer.restore(state.lexer_state);
        self.current_token = state.current_token;
    }

    pub fn parseModule(self: *Parser) anyerror!AST {
        var body = std.ArrayList(AST).empty;
        errdefer body.deinit(self.builder.allocator);

        while (self.peekType() != .eof) {
            if (self.match(.newline)) continue;
            const stmt = try self.parseStatement();
            try body.append(self.builder.allocator, stmt);
            if (self.peekType() != .eof) {
                const is_compound = switch (stmt) {
                    .If, .While, .FunctionDef, .ClassDef, .Try => true,
                    else => false,
                };
                if (!is_compound) {
                    try self.consume(.newline, "Expect newline after statement");
                } else {
                    _ = self.match(.newline);
                }
            }
        }

        return AST{ .Module = .{ .body = try body.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseBlock(self: *Parser) anyerror![]AST {
        try self.consume(.newline, "Expect newline before block");
        try self.consume(.indent, "Expect indent to start block");
        
        var body = std.ArrayList(AST).empty;
        errdefer body.deinit(self.builder.allocator);
        
        while (self.peekType() != .dedent and self.peekType() != .eof) {
            if (self.match(.newline)) continue;
            const stmt = try self.parseStatement();
            try body.append(self.builder.allocator, stmt);
            if (self.peekType() != .dedent and self.peekType() != .eof) {
                const is_compound = switch (stmt) {
                    .If, .While, .FunctionDef, .ClassDef, .Try => true,
                    else => false,
                };
                if (!is_compound) {
                    try self.consume(.newline, "Expect newline after statement in block");
                } else {
                    _ = self.match(.newline);
                }
            }
        }
        
        try self.consume(.dedent, "Expect dedent to end block");
        return try body.toOwnedSlice(self.builder.allocator);
    }

    fn parseIfStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_if, "Expect 'if'");
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after condition");
        const body = try self.parseBlock();
        
        var orelse_list = std.ArrayList(AST).empty;
        errdefer orelse_list.deinit(self.builder.allocator);
        
        if (self.match(.kw_elif)) {
            const elif_ast = try self.parseElifRecursive();
            try orelse_list.append(self.builder.allocator, elif_ast);
        } else if (self.match(.kw_else)) {
            try self.consume(.colon, "Expect ':' after else");
            const else_body = try self.parseBlock();
            for (else_body) |stmt| {
                try orelse_list.append(self.builder.allocator, stmt);
            }
        }
        
        return AST{ .If = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
            .orelse_body = try orelse_list.toOwnedSlice(self.builder.allocator),
        } };
    }

    fn parseElifRecursive(self: *Parser) anyerror!AST {
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after condition");
        const body = try self.parseBlock();
        
        var orelse_list = std.ArrayList(AST).empty;
        errdefer orelse_list.deinit(self.builder.allocator);
        
        if (self.match(.kw_elif)) {
            const elif_ast = try self.parseElifRecursive();
            try orelse_list.append(self.builder.allocator, elif_ast);
        } else if (self.match(.kw_else)) {
            try self.consume(.colon, "Expect ':' after else");
            const else_body = try self.parseBlock();
            for (else_body) |stmt| {
                try orelse_list.append(self.builder.allocator, stmt);
            }
        }
        
        return AST{ .If = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
            .orelse_body = try orelse_list.toOwnedSlice(self.builder.allocator),
        } };
    }

    fn parseWhileStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_while, "Expect 'while'");
        const cond = try self.parseExpression();
        try self.consume(.colon, "Expect ':' after condition");
        const body = try self.parseBlock();
        return AST{ .While = .{
            .cond = try self.builder.newAST(cond),
            .body = body,
        } };
    }

    fn parseFunctionDef(self: *Parser) anyerror!AST {
        try self.consume(.kw_def, "Expect 'def'");
        const name_tok = self.current_token;
        try self.consume(.identifier, "Expect function name");
        try self.consume(.lparen, "Expect '(' after function name");
        
        var args = std.ArrayList([]const u8).empty;
        errdefer {
            for (args.items) |arg| {
                self.builder.allocator.free(arg);
            }
            args.deinit(self.builder.allocator);
        }
        
        while (self.peekType() != .rparen) {
            const arg_name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect parameter name");
            const arg_copy = try self.builder.allocator.dupe(u8, arg_name);
            try args.append(self.builder.allocator, arg_copy);
            
            if (self.peekType() == .comma) {
                self.advance();
            } else if (self.peekType() != .rparen) {
                return error.ParseError;
            }
        }
        try self.consume(.rparen, "Expect ')' after parameters");
        try self.consume(.colon, "Expect ':' after function signature");
        
        const body = try self.parseBlock();
        
        return AST{ .FunctionDef = .{
            .name = try self.builder.allocator.dupe(u8, name_tok.lexeme),
            .args = try args.toOwnedSlice(self.builder.allocator),
            .body = body,
        } };
    }

    fn parseReturnStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_return, "Expect 'return'");
        if (self.peekType() == .newline or self.peekType() == .dedent or self.peekType() == .eof) {
            return AST{ .Return = .{ .value = null } };
        }
        const expr = try self.parseExpression();
        return AST{ .Return = .{ .value = try self.builder.newAST(expr) } };
    }

    fn parseStatement(self: *Parser) anyerror!AST {
        if (self.peekType() == .kw_if) {
            return try self.parseIfStatement();
        }
        if (self.peekType() == .kw_while) {
            return try self.parseWhileStatement();
        }
        if (self.peekType() == .kw_def) {
            return try self.parseFunctionDef();
        }
        if (self.peekType() == .kw_class) {
            return try self.parseClassDef();
        }
        if (self.peekType() == .kw_try) {
            return try self.parseTryStatement();
        }
        if (self.peekType() == .kw_raise) {
            return try self.parseRaiseStatement();
        }
        if (self.peekType() == .kw_nonlocal) {
            return try self.parseNonlocalStatement();
        }
        if (self.peekType() == .kw_import) {
            return try self.parseImportStatement();
        }
        if (self.peekType() == .kw_from) {
            return try self.parseImportFromStatement();
        }
        if (self.peekType() == .kw_return) {
            return try self.parseReturnStatement();
        }
        if (self.match(.kw_pass)) {
            return AST{ .Pass = {} };
        }

        // Try parsing Assignment: target = expr
        const state = self.saveState();
        if (self.peekType() == .identifier) {
            const target_expr = self.parsePrimary() catch blk: {
                self.restoreState(state);
                break :blk null;
            };
            if (target_expr) |t| {
                if (self.match(.equal)) {
                    const expr = try self.parseExpression();
                    switch (t) {
                        .Name => |n| {
                            return AST{ .Assign = .{ .target = n, .value = try self.builder.newAST(expr) } };
                        },
                        .Attribute => |attr| {
                            return AST{ .AssignAttr = .{
                                .value = attr.value,
                                .attr = attr.attr,
                                .expr = try self.builder.newAST(expr),
                            } };
                        },
                        else => {
                            self.restoreState(state);
                        },
                    }
                } else {
                    self.restoreState(state);
                }
            }
        } else {
            self.restoreState(state);
        }

        // Try parsing Print statement: print(expr)
        if (self.peekType() == .identifier and std.mem.eql(u8, self.current_token.lexeme, "print")) {
            self.advance();
            try self.consume(.lparen, "Expect '(' after print");
            const expr = try self.parseExpression();
            try self.consume(.rparen, "Expect ')' after print expression");
            return AST{ .Print = .{ .value = try self.builder.newAST(expr) } };
        }

        // Otherwise, it's just an expression statement
        return try self.parseExpression();
    }

    fn parseExpression(self: *Parser) anyerror!AST {
        return try self.parseComparison();
    }

    fn parseComparison(self: *Parser) anyerror!AST {
        var expr = try self.parseTerm();
        while (true) {
            const op: ?CompareOp = switch (self.peekType()) {
                .less => .Lt,
                .less_equal => .Le,
                .double_equal => .Eq,
                .not_equal => .Ne,
                .greater => .Gt,
                .greater_equal => .Ge,
                else => null,
            };
            if (op) |cmp_op| {
                self.advance();
                const right = try self.parseTerm();
                expr = AST{ .Compare = .{
                    .op = cmp_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseTerm(self: *Parser) anyerror!AST {
        var expr = try self.parseFactor();
        while (true) {
            const op: ?Op = switch (self.peekType()) {
                .plus => .Add,
                .minus => .Sub,
                else => null,
            };
            if (op) |bin_op| {
                self.advance();
                const right = try self.parseFactor();
                expr = AST{ .BinOp = .{
                    .op = bin_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseFactor(self: *Parser) anyerror!AST {
        var expr = try self.parsePrimary();
        while (true) {
            const op: ?Op = switch (self.peekType()) {
                .star => .Mul,
                .slash => .Div,
                else => null,
            };
            if (op) |bin_op| {
                self.advance();
                const right = try self.parsePrimary();
                expr = AST{ .BinOp = .{
                    .op = bin_op,
                    .left = try self.builder.newAST(expr),
                    .right = try self.builder.newAST(right),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseBase(self: *Parser) anyerror!AST {
        if (self.match(.kw_None)) {
            return AST{ .Constant = .None };
        }
        if (self.match(.kw_True)) {
            return AST{ .Constant = .{ .Bool = true } };
        }
        if (self.match(.kw_False)) {
            return AST{ .Constant = .{ .Bool = false } };
        }
        if (self.peekType() == .number_int) {
            const val = try std.fmt.parseInt(i64, self.current_token.lexeme, 10);
            self.advance();
            return AST{ .Constant = .{ .Int = val } };
        }
        if (self.peekType() == .number_float) {
            const val = try std.fmt.parseFloat(f64, self.current_token.lexeme);
            self.advance();
            return AST{ .Constant = .{ .Float = val } };
        }
        if (self.peekType() == .string) {
            const lexeme = self.current_token.lexeme;
            self.advance();
            return AST{ .Constant = .{ .String = lexeme } };
        }
        if (self.peekType() == .identifier) {
            const name = self.current_token.lexeme;
            self.advance();
            return AST{ .Name = name };
        }

        // List literal: [1, 2, 3]
        if (self.match(.lbracket)) {
            var elts = std.ArrayList(AST).empty;
            errdefer elts.deinit(self.builder.allocator);
            while (self.peekType() != .rbracket) {
                const elt = try self.parseExpression();
                try elts.append(self.builder.allocator, elt);
                if (self.peekType() == .comma) {
                    self.advance();
                } else if (self.peekType() != .rbracket) {
                    return error.ParseError;
                }
            }
            try self.consume(.rbracket, "Expect ']'");
            return AST{ .List = .{ .elts = try elts.toOwnedSlice(self.builder.allocator) } };
        }

        // Tuple literal or grouped expression
        if (self.match(.lparen)) {
            if (self.match(.rparen)) {
                return AST{ .Tuple = .{ .elts = &[_]AST{} } };
            }
            const first = try self.parseExpression();
            if (self.match(.comma)) {
                var elts = std.ArrayList(AST).empty;
                errdefer elts.deinit(self.builder.allocator);
                try elts.append(self.builder.allocator, first);
                while (self.peekType() != .rparen) {
                    const elt = try self.parseExpression();
                    try elts.append(self.builder.allocator, elt);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rparen) {
                        return error.ParseError;
                    }
                }
                try self.consume(.rparen, "Expect ')'");
                return AST{ .Tuple = .{ .elts = try elts.toOwnedSlice(self.builder.allocator) } };
            } else {
                try self.consume(.rparen, "Expect ')'");
                return first;
            }
        }

        // Dict literal: { "a": 1, "b": 2 }
        if (self.match(.lbrace)) {
            var keys = std.ArrayList(AST).empty;
            var values = std.ArrayList(AST).empty;
            errdefer {
                keys.deinit(self.builder.allocator);
                values.deinit(self.builder.allocator);
            }
            while (self.peekType() != .rbrace) {
                const k = try self.parseExpression();
                try self.consume(.colon, "Expect ':' after key in dictionary literal");
                const v = try self.parseExpression();
                
                try keys.append(self.builder.allocator, k);
                try values.append(self.builder.allocator, v);
                
                if (self.peekType() == .comma) {
                    self.advance();
                } else if (self.peekType() != .rbrace) {
                    return error.ParseError;
                }
            }
            try self.consume(.rbrace, "Expect '}'");
            return AST{ .Dict = .{
                .keys = try keys.toOwnedSlice(self.builder.allocator),
                .values = try values.toOwnedSlice(self.builder.allocator),
            } };
        }

        return error.ParseError;
    }

    fn parsePrimary(self: *Parser) anyerror!AST {
        var expr = try self.parseBase();
        
        while (true) {
            if (self.match(.lparen)) {
                var args = std.ArrayList(AST).empty;
                errdefer args.deinit(self.builder.allocator);
                while (self.peekType() != .rparen) {
                    const arg = try self.parseExpression();
                    try args.append(self.builder.allocator, arg);
                    if (self.peekType() == .comma) {
                        self.advance();
                    } else if (self.peekType() != .rparen) {
                        return error.ParseError;
                    }
                }
                try self.consume(.rparen, "Expect ')' after arguments");
                expr = AST{ .Call = .{
                    .func = try self.builder.newAST(expr),
                    .args = try args.toOwnedSlice(self.builder.allocator),
                } };
            } else if (self.match(.dot)) {
                const name = self.current_token.lexeme;
                try self.consume(.identifier, "Expect attribute name after '.'");
                expr = AST{ .Attribute = .{
                    .value = try self.builder.newAST(expr),
                    .attr = try self.builder.allocator.dupe(u8, name),
                } };
            } else {
                break;
            }
        }
        return expr;
    }

    fn parseClassDef(self: *Parser) anyerror!AST {
        try self.consume(.kw_class, "Expect 'class'");
        const name_tok = self.current_token;
        try self.consume(.identifier, "Expect class name");
        
        var base: ?[]const u8 = null;
        if (self.match(.lparen)) {
            if (self.peekType() == .identifier) {
                base = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                self.advance();
            }
            try self.consume(.rparen, "Expect ')' after base class");
        }
        try self.consume(.colon, "Expect ':' after class signature");
        const body = try self.parseBlock();
        
        return AST{ .ClassDef = .{
            .name = try self.builder.allocator.dupe(u8, name_tok.lexeme),
            .base = base,
            .body = body,
        } };
    }

    fn parseTryStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_try, "Expect 'try'");
        try self.consume(.colon, "Expect ':' after try");
        const try_body = try self.parseBlock();
        
        var handlers = std.ArrayList(ExceptHandler).empty;
        errdefer {
            for (handlers.items) |h| {
                if (h.type_name) |t| self.builder.allocator.free(t);
                if (h.name) |n| self.builder.allocator.free(n);
                self.builder.allocator.free(h.body);
            }
            handlers.deinit(self.builder.allocator);
        }
        
        while (self.match(.kw_except)) {
            var type_name: ?[]const u8 = null;
            var as_name: ?[]const u8 = null;
            
            if (self.peekType() == .identifier) {
                type_name = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                self.advance();
                
                if (self.match(.kw_as)) {
                    as_name = try self.builder.allocator.dupe(u8, self.current_token.lexeme);
                    try self.consume(.identifier, "Expect identifier after 'as'");
                }
            }
            try self.consume(.colon, "Expect ':' after except");
            const handler_body = try self.parseBlock();
            
            try handlers.append(self.builder.allocator, .{
                .type_name = type_name,
                .name = as_name,
                .body = handler_body,
            });
        }
        
        var final_body: []AST = &[_]AST{};
        if (self.match(.kw_finally)) {
            try self.consume(.colon, "Expect ':' after finally");
            final_body = try self.parseBlock();
        }
        
        return AST{ .Try = .{
            .body = try_body,
            .handlers = try handlers.toOwnedSlice(self.builder.allocator),
            .finalbody = final_body,
        } };
    }

    fn parseRaiseStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_raise, "Expect 'raise'");
        var exc: ?*AST = null;
        if (self.peekType() != .newline and self.peekType() != .eof and self.peekType() != .dedent) {
            const expr = try self.parseExpression();
            exc = try self.builder.newAST(expr);
        }
        return AST{ .Raise = .{ .exc = exc } };
    }

    fn parseNonlocalStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_nonlocal, "Expect 'nonlocal'");
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect variable name in nonlocal");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .Nonlocal = .{ .names = try names.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseImportStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_import, "Expect 'import'");
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect module name");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .Import = .{ .names = try names.toOwnedSlice(self.builder.allocator) } };
    }

    fn parseImportFromStatement(self: *Parser) anyerror!AST {
        try self.consume(.kw_from, "Expect 'from'");
        const mod_name = self.current_token.lexeme;
        try self.consume(.identifier, "Expect module name");
        try self.consume(.kw_import, "Expect 'import' after module");
        
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| self.builder.allocator.free(name);
            names.deinit(self.builder.allocator);
        }
        while (true) {
            const name = self.current_token.lexeme;
            try self.consume(.identifier, "Expect imported name");
            try names.append(self.builder.allocator, try self.builder.allocator.dupe(u8, name));
            if (self.match(.comma)) {
                continue;
            }
            break;
        }
        return AST{ .ImportFrom = .{
            .module = try self.builder.allocator.dupe(u8, mod_name),
            .names = try names.toOwnedSlice(self.builder.allocator),
        } };
    }
};

test "parser simple module, print and math" {
    const src =
        \\x = 10 + 5
        \\print(x)
    ;
    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module = try parser.parseModule();

    switch (module) {
        .Module => |mod| {
            try testing.expectEqual(@as(usize, 2), mod.body.len);
            
            // Check assignment
            switch (mod.body[0]) {
                .Assign => |assign| {
                    try testing.expectEqualStrings("x", assign.target);
                    switch (assign.value.*) {
                        .BinOp => |binop| {
                            try testing.expectEqual(Op.Add, binop.op);
                            try testing.expectEqual(@as(i64, 10), binop.left.*.Constant.Int);
                            try testing.expectEqual(@as(i64, 5), binop.right.*.Constant.Int);
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }

            // Check print
            switch (mod.body[1]) {
                .Print => |p| {
                    try testing.expectEqualStrings("x", p.value.*.Name);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parser if and while" {
    const src =
        \\if x == 10:
        \\    pass
        \\else:
        \\    pass
        \\while x > 0:
        \\    x = x - 1
    ;
    var lexer = Lexer.init(src);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    var parser = Parser.init(&lexer, arena.allocator());
    const module = try parser.parseModule();
    
    switch (module) {
        .Module => |mod| {
            try testing.expectEqual(@as(usize, 2), mod.body.len);
            try testing.expect(mod.body[0] == .If);
            try testing.expect(mod.body[1] == .While);
        },
        else => return error.TestFailed,
    }
}
