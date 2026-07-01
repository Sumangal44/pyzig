const std = @import("std");
const testing = std.testing;

pub const TokenType = enum {
    // Keywords
    kw_def, kw_class, kw_return, kw_if, kw_else, kw_elif, kw_while, kw_for, kw_in, kw_import, kw_from, kw_as,
    kw_and, kw_or, kw_not, kw_is, kw_None, kw_True, kw_False, kw_pass, kw_break, kw_continue, kw_lambda,
    kw_try, kw_except, kw_finally, kw_raise, kw_nonlocal, kw_assert, kw_async, kw_await, kw_del, kw_global,
    kw_with, kw_yield,

    // Identifiers and Literals
    identifier,
    number_int,
    number_float,
    number_complex,
    string,
    fstring,
    bytes,

    // Operators and delimiters
    plus, minus, star, slash, percent, equal, double_equal, not_equal,
    less, less_equal, greater, greater_equal,
    lparen, rparen, lbrace, rbrace, lbracket, rbracket,
    colon, comma, newline, indent, dedent, dot, semicolon,
    ampersand, vbar, caret, tilde,
    left_shift, right_shift,
    at,
    colon_equal,
    // Augmented assignment and compound operators
    plus_equal, minus_equal, star_equal, slash_equal, percent_equal,
    double_star, double_slash,
    double_star_equal, double_slash_equal,
    ampersand_equal, vbar_equal, caret_equal,
    left_shift_equal, right_shift_equal,
    at_equal,

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    indent_stack: [100]usize = init_stack(),
    indent_stack_len: usize = 1,
    paren_depth: usize = 0,
    pending_dedents: usize = 0,
    at_line_start: bool = true,

    fn init_stack() [100]usize {
        var s = std.mem.zeroes([100]usize);
        s[0] = 0;
        return s;
    }

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
        };
    }

    pub const State = struct {
        index: usize,
        line: usize,
        column: usize,
        indent_stack: [100]usize,
        indent_stack_len: usize,
        paren_depth: usize,
        pending_dedents: usize,
        at_line_start: bool,
    };

    pub fn save(self: Lexer) State {
        return .{
            .index = self.index,
            .line = self.line,
            .column = self.column,
            .indent_stack = self.indent_stack,
            .indent_stack_len = self.indent_stack_len,
            .paren_depth = self.paren_depth,
            .pending_dedents = self.pending_dedents,
            .at_line_start = self.at_line_start,
        };
    }

    pub fn restore(self: *Lexer, state: State) void {
        self.index = state.index;
        self.line = state.line;
        self.column = state.column;
        self.indent_stack = state.indent_stack;
        self.indent_stack_len = state.indent_stack_len;
        self.paren_depth = state.paren_depth;
        self.pending_dedents = state.pending_dedents;
        self.at_line_start = state.at_line_start;
    }

    fn peek(self: Lexer) u8 {
        if (self.index >= self.source.len) return 0;
        return self.source[self.index];
    }

    fn peekNext(self: Lexer) u8 {
        if (self.index + 1 >= self.source.len) return 0;
        return self.source[self.index + 1];
    }

    fn advance(self: *Lexer) u8 {
        if (self.index >= self.source.len) return 0;
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    pub fn next(self: *Lexer) Token {
        // Emit pending dedents if any
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            return .{
                .type = .dedent,
                .lexeme = "",
                .line = self.line,
                .column = self.column,
            };
        }

        while (self.index < self.source.len or self.at_line_start) {
            if (self.at_line_start) {
                self.at_line_start = false;
                const start_line = self.line;
                const start_col = self.column;

                // Count spaces and tabs
                var spaces: usize = 0;
                while (self.index < self.source.len) {
                    const c = self.peek();
                    if (c == ' ') {
                        spaces += 1;
                        _ = self.advance();
                    } else if (c == '\t') {
                        spaces += 8; // Python standard handles tab as 8 spaces
                        _ = self.advance();
                    } else {
                        break;
                    }
                }

                const c = self.peek();
                // Empty lines or lines with comments do not trigger indents/dedents
                if (c == '\n' or c == '\r' or c == '#' or self.index >= self.source.len) {
                    continue;
                }

                if (self.paren_depth == 0) {
                    const current_indent = self.indent_stack[self.indent_stack_len - 1];
                    if (spaces > current_indent) {
                        if (self.indent_stack_len >= 100) {
                            return .{ .type = .invalid, .lexeme = "Indentation limit exceeded", .line = start_line, .column = start_col };
                        }
                        self.indent_stack[self.indent_stack_len] = spaces;
                        self.indent_stack_len += 1;
                        return .{
                            .type = .indent,
                            .lexeme = "",
                            .line = start_line,
                            .column = start_col,
                        };
                    } else if (spaces < current_indent) {
                        var pops: usize = 0;
                        var matched = false;
                        while (self.indent_stack_len > 0) {
                            self.indent_stack_len -= 1;
                            if (self.indent_stack[self.indent_stack_len] == spaces) {
                                self.indent_stack_len += 1; // keep this one
                                matched = true;
                                break;
                            }
                            pops += 1;
                        }
                        if (!matched) {
                            return .{ .type = .invalid, .lexeme = "Unindent does not match any outer indentation level", .line = start_line, .column = start_col };
                        }
                        if (pops > 0) {
                            self.pending_dedents = pops - 1;
                            return .{
                                .type = .dedent,
                                .lexeme = "",
                                .line = start_line,
                                .column = start_col,
                            };
                        }
                    }
                }
            }

            // Normal lexing
            const start_idx = self.index;
            const start_line = self.line;
            const start_col = self.column;
            const c = self.advance();

            switch (c) {
                0 => break,
                ' ', '\t' => continue,
                '\r' => {
                    if (self.peek() == '\n') {
                        _ = self.advance();
                    }
                    if (self.paren_depth == 0) {
                        self.at_line_start = true;
                        return .{ .type = .newline, .lexeme = "\n", .line = start_line, .column = start_col };
                    }
                },
                '\n' => {
                    if (self.paren_depth == 0) {
                        self.at_line_start = true;
                        return .{ .type = .newline, .lexeme = "\n", .line = start_line, .column = start_col };
                    }
                },
                '#' => {
                    // Comment, skip till end of line
                    while (self.index < self.source.len and self.peek() != '\n' and self.peek() != '\r') {
                        _ = self.advance();
                    }
                },
                '(' => {
                    self.paren_depth += 1;
                    return .{ .type = .lparen, .lexeme = "(", .line = start_line, .column = start_col };
                },
                ')' => {
                    if (self.paren_depth > 0) self.paren_depth -= 1;
                    return .{ .type = .rparen, .lexeme = ")", .line = start_line, .column = start_col };
                },
                '{' => {
                    self.paren_depth += 1;
                    return .{ .type = .lbrace, .lexeme = "{", .line = start_line, .column = start_col };
                },
                '}' => {
                    if (self.paren_depth > 0) self.paren_depth -= 1;
                    return .{ .type = .rbrace, .lexeme = "}", .line = start_line, .column = start_col };
                },
                '[' => {
                    self.paren_depth += 1;
                    return .{ .type = .lbracket, .lexeme = "[", .line = start_line, .column = start_col };
                },
                ']' => {
                    if (self.paren_depth > 0) self.paren_depth -= 1;
                    return .{ .type = .rbracket, .lexeme = "]", .line = start_line, .column = start_col };
                },
                ':' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .colon_equal, .lexeme = ":=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .colon, .lexeme = ":", .line = start_line, .column = start_col };
                },
                ',' => return .{ .type = .comma, .lexeme = ",", .line = start_line, .column = start_col },
                '.' => return .{ .type = .dot, .lexeme = ".", .line = start_line, .column = start_col },
                ';' => {
                    // Treat semicolons as newlines (statement separator)
                    // Do NOT set at_line_start - semicolons don't create new indentation contexts.
                    // The space after a `;` is not Python indentation.
                    if (self.paren_depth == 0) {
                        return .{ .type = .newline, .lexeme = ";", .line = start_line, .column = start_col };
                    }
                },
                '+' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .plus_equal, .lexeme = "+=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .plus, .lexeme = "+", .line = start_line, .column = start_col };
                },
                '-' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .minus_equal, .lexeme = "-=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .minus, .lexeme = "-", .line = start_line, .column = start_col };
                },
                '*' => {
                    if (self.peek() == '*') {
                        _ = self.advance();
                        if (self.peek() == '=') {
                            _ = self.advance();
                            return .{ .type = .double_star_equal, .lexeme = "**=", .line = start_line, .column = start_col };
                        }
                        return .{ .type = .double_star, .lexeme = "**", .line = start_line, .column = start_col };
                    }
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .star_equal, .lexeme = "*=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .star, .lexeme = "*", .line = start_line, .column = start_col };
                },
                '/' => {
                    if (self.peek() == '/') {
                        _ = self.advance();
                        if (self.peek() == '=') {
                            _ = self.advance();
                            return .{ .type = .double_slash_equal, .lexeme = "//=", .line = start_line, .column = start_col };
                        }
                        return .{ .type = .double_slash, .lexeme = "//", .line = start_line, .column = start_col };
                    }
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .slash_equal, .lexeme = "/=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .slash, .lexeme = "/", .line = start_line, .column = start_col };
                },
                '%' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .percent_equal, .lexeme = "%=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .percent, .lexeme = "%", .line = start_line, .column = start_col };
                },
                '=' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .double_equal, .lexeme = "==", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .equal, .lexeme = "=", .line = start_line, .column = start_col };
                },
                '!' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .not_equal, .lexeme = "!=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .invalid, .lexeme = "!", .line = start_line, .column = start_col };
                },
                '<' => {
                    if (self.peek() == '<') {
                        _ = self.advance();
                        if (self.peek() == '=') {
                            _ = self.advance();
                            return .{ .type = .left_shift_equal, .lexeme = "<<=", .line = start_line, .column = start_col };
                        }
                        return .{ .type = .left_shift, .lexeme = "<<", .line = start_line, .column = start_col };
                    }
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .less_equal, .lexeme = "<=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .less, .lexeme = "<", .line = start_line, .column = start_col };
                },
                '>' => {
                    if (self.peek() == '>') {
                        _ = self.advance();
                        if (self.peek() == '=') {
                            _ = self.advance();
                            return .{ .type = .right_shift_equal, .lexeme = ">>=", .line = start_line, .column = start_col };
                        }
                        return .{ .type = .right_shift, .lexeme = ">>", .line = start_line, .column = start_col };
                    }
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .greater_equal, .lexeme = ">=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .greater, .lexeme = ">", .line = start_line, .column = start_col };
                },
                '&' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .ampersand_equal, .lexeme = "&=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .ampersand, .lexeme = "&", .line = start_line, .column = start_col };
                },
                '|' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .vbar_equal, .lexeme = "|=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .vbar, .lexeme = "|", .line = start_line, .column = start_col };
                },
                '^' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .caret_equal, .lexeme = "^=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .caret, .lexeme = "^", .line = start_line, .column = start_col };
                },
                '~' => {
                    return .{ .type = .tilde, .lexeme = "~", .line = start_line, .column = start_col };
                },
                '@' => {
                    if (self.peek() == '=') {
                        _ = self.advance();
                        return .{ .type = .at_equal, .lexeme = "@=", .line = start_line, .column = start_col };
                    }
                    return .{ .type = .at, .lexeme = "@", .line = start_line, .column = start_col };
                },
                '\'', '"' => {
                    // Check for triple-quoted string
                    const quote = c;
                    if (self.peek() == quote and self.peekNext() == quote) {
                        _ = self.advance(); // second quote
                        _ = self.advance(); // third quote
                        // Read until triple-close
                        while (self.index < self.source.len) {
                            const ch = self.advance();
                            if (ch == quote and self.peek() == quote and self.peekNext() == quote) {
                                _ = self.advance();
                                _ = self.advance();
                                break;
                            }
                        }
                        const lexeme = self.source[start_idx + 4 .. self.index - 3];
                        return .{ .type = .string, .lexeme = lexeme, .line = start_line, .column = start_col };
                    }
                    // Single-quoted string literal
                    while (self.index < self.source.len and self.peek() != quote) {
                        if (self.peek() == '\\') _ = self.advance(); // skip escape
                        if (self.index < self.source.len) _ = self.advance();
                    }
                    if (self.index >= self.source.len) {
                        return .{ .type = .invalid, .lexeme = "Unterminated string literal", .line = start_line, .column = start_col };
                    }
                    _ = self.advance(); // consume closing quote
                    const lexeme = self.source[start_idx + 1 .. self.index - 1];
                    return .{ .type = .string, .lexeme = lexeme, .line = start_line, .column = start_col };
                },
                else => {
                    // f-string prefix: f"..." or f'...'
                    if ((c == 'f' or c == 'F') and (self.peek() == '\'' or self.peek() == '"')) {
                        const quote = self.advance();
                        // Check for triple-quoted f-string
                        if (self.peek() == quote and self.peekNext() == quote) {
                            _ = self.advance();
                            _ = self.advance();
                            while (self.index < self.source.len) {
                                const ch = self.advance();
                                if (ch == quote and self.peek() == quote and self.peekNext() == quote) {
                                    _ = self.advance();
                                    _ = self.advance();
                                    break;
                                }
                            }
                            const lexeme = self.source[start_idx + 5 .. self.index - 3];
                            return .{ .type = .fstring, .lexeme = lexeme, .line = start_line, .column = start_col };
                        }
                        while (self.index < self.source.len and self.peek() != quote) {
                            if (self.peek() == '\\') _ = self.advance(); // skip escape
                            if (self.index < self.source.len) _ = self.advance();
                        }
                        if (self.index >= self.source.len) {
                            return .{ .type = .invalid, .lexeme = "Unterminated f-string literal", .line = start_line, .column = start_col };
                        }
                        _ = self.advance(); // consume closing quote
                        const lexeme = self.source[start_idx + 2 .. self.index - 1];
                        return .{ .type = .fstring, .lexeme = lexeme, .line = start_line, .column = start_col };
                    }
                    // r-string prefix: r"..." or r'...' (raw string, treat as plain string)
                    if ((c == 'r' or c == 'R') and (self.peek() == '\'' or self.peek() == '"')) {
                        const quote = self.advance();
                        while (self.index < self.source.len and self.peek() != quote) {
                            _ = self.advance(); // no escape processing for raw strings
                        }
                        if (self.index >= self.source.len) {
                            return .{ .type = .invalid, .lexeme = "Unterminated string literal", .line = start_line, .column = start_col };
                        }
                        _ = self.advance(); // consume closing quote
                        const lexeme = self.source[start_idx + 2 .. self.index - 1];
                        return .{ .type = .string, .lexeme = lexeme, .line = start_line, .column = start_col };
                    }
                    if ((c == 'b' or c == 'B') and (self.peek() == '\'' or self.peek() == '"')) {
                        const quote = self.advance();
                        while (self.index < self.source.len and self.peek() != quote) {
                            _ = self.advance();
                        }
                        if (self.index >= self.source.len) {
                            return .{ .type = .invalid, .lexeme = "Unterminated bytes literal", .line = start_line, .column = start_col };
                        }
                        _ = self.advance(); // consume quote
                        const lexeme = self.source[start_idx + 2 .. self.index - 1];
                        return .{ .type = .bytes, .lexeme = lexeme, .line = start_line, .column = start_col };
                    }
                    if (std.ascii.isDigit(c)) {
                        // Integer or Float
                        var is_float = false;
                        while (std.ascii.isDigit(self.peek())) {
                            _ = self.advance();
                        }
                        if (self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
                            is_float = true;
                            _ = self.advance(); // consume '.'
                            while (std.ascii.isDigit(self.peek())) {
                                _ = self.advance();
                            }
                        }
                        var is_complex = false;
                        if (self.peek() == 'j' or self.peek() == 'J') {
                            is_complex = true;
                            _ = self.advance(); // consume 'j' or 'J'
                        }
                        const lexeme = self.source[start_idx..self.index];
                        return .{
                            .type = if (is_complex) .number_complex else (if (is_float) .number_float else .number_int),
                            .lexeme = lexeme,
                            .line = start_line,
                            .column = start_col,
                        };
                    } else if (std.ascii.isAlphabetic(c) or c == '_') {
                        // Identifier or Keyword
                        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
                            _ = self.advance();
                        }
                        const lexeme = self.source[start_idx..self.index];
                        const t_type = checkKeyword(lexeme);
                        return .{
                            .type = t_type,
                            .lexeme = lexeme,
                            .line = start_line,
                            .column = start_col,
                        };
                    } else {
                        return .{ .type = .invalid, .lexeme = self.source[start_idx..self.index], .line = start_line, .column = start_col };
                    }
                },
            }
        }

        // Handle end of file dedents
        if (self.indent_stack_len > 1) {
            self.indent_stack_len -= 1;
            return .{
                .type = .dedent,
                .lexeme = "",
                .line = self.line,
                .column = self.column,
            };
        }

        return .{
            .type = .eof,
            .lexeme = "",
            .line = self.line,
            .column = self.column,
        };
    }

    fn checkKeyword(lexeme: []const u8) TokenType {
        if (std.mem.eql(u8, lexeme, "def")) return .kw_def;
        if (std.mem.eql(u8, lexeme, "class")) return .kw_class;
        if (std.mem.eql(u8, lexeme, "return")) return .kw_return;
        if (std.mem.eql(u8, lexeme, "if")) return .kw_if;
        if (std.mem.eql(u8, lexeme, "else")) return .kw_else;
        if (std.mem.eql(u8, lexeme, "elif")) return .kw_elif;
        if (std.mem.eql(u8, lexeme, "while")) return .kw_while;
        if (std.mem.eql(u8, lexeme, "for")) return .kw_for;
        if (std.mem.eql(u8, lexeme, "in")) return .kw_in;
        if (std.mem.eql(u8, lexeme, "import")) return .kw_import;
        if (std.mem.eql(u8, lexeme, "from")) return .kw_from;
        if (std.mem.eql(u8, lexeme, "as")) return .kw_as;
        if (std.mem.eql(u8, lexeme, "and")) return .kw_and;
        if (std.mem.eql(u8, lexeme, "or")) return .kw_or;
        if (std.mem.eql(u8, lexeme, "not")) return .kw_not;
        if (std.mem.eql(u8, lexeme, "is")) return .kw_is;
        if (std.mem.eql(u8, lexeme, "None")) return .kw_None;
        if (std.mem.eql(u8, lexeme, "True")) return .kw_True;
        if (std.mem.eql(u8, lexeme, "False")) return .kw_False;
        if (std.mem.eql(u8, lexeme, "pass")) return .kw_pass;
        if (std.mem.eql(u8, lexeme, "break")) return .kw_break;
        if (std.mem.eql(u8, lexeme, "continue")) return .kw_continue;
        if (std.mem.eql(u8, lexeme, "try")) return .kw_try;
        if (std.mem.eql(u8, lexeme, "except")) return .kw_except;
        if (std.mem.eql(u8, lexeme, "finally")) return .kw_finally;
        if (std.mem.eql(u8, lexeme, "raise")) return .kw_raise;
        if (std.mem.eql(u8, lexeme, "nonlocal")) return .kw_nonlocal;
        if (std.mem.eql(u8, lexeme, "lambda")) return .kw_lambda;
        if (std.mem.eql(u8, lexeme, "assert")) return .kw_assert;
        if (std.mem.eql(u8, lexeme, "async")) return .kw_async;
        if (std.mem.eql(u8, lexeme, "await")) return .kw_await;
        if (std.mem.eql(u8, lexeme, "del")) return .kw_del;
        if (std.mem.eql(u8, lexeme, "global")) return .kw_global;
        if (std.mem.eql(u8, lexeme, "with")) return .kw_with;
        if (std.mem.eql(u8, lexeme, "yield")) return .kw_yield;
        return .identifier;
    }
};

test "lexer simple indentation and keywords" {
    const src =
        \\def foo():
        \\    x = 10
        \\    if x == 10:
        \\        pass
        \\    return x
        \\
    ;
    var lexer = Lexer.init(src);
    
    const expected = [_]TokenType{
        .kw_def, .identifier, .lparen, .rparen, .colon, .newline,
        .indent, .identifier, .equal, .number_int, .newline,
        .kw_if, .identifier, .double_equal, .number_int, .colon, .newline,
        .indent, .kw_pass, .newline,
        .dedent, .kw_return, .identifier, .newline,
        .dedent, .eof
    };

    for (expected) |t_type| {
        const token = lexer.next();
        try testing.expectEqual(t_type, token.type);
    }
}

test "lexer ignore newline inside parens" {
    const src =
        \\(
        \\  1 +
        \\  2
        \\)
    ;
    var lexer = Lexer.init(src);
    
    const expected = [_]TokenType{
        .lparen, .number_int, .plus, .number_int, .rparen, .eof
    };

    for (expected) |t_type| {
        const token = lexer.next();
        try testing.expectEqual(t_type, token.type);
    }
}

test "lexer all standard python keywords" {
    const src = "def class return if else elif while for in import from as and or not is None True False pass break continue try except finally raise nonlocal lambda assert async await del global with yield";
    var lexer = Lexer.init(src);
    
    const expected = [_]TokenType{
        .kw_def, .kw_class, .kw_return, .kw_if, .kw_else, .kw_elif, .kw_while, .kw_for,
        .kw_in, .kw_import, .kw_from, .kw_as, .kw_and, .kw_or, .kw_not, .kw_is,
        .kw_None, .kw_True, .kw_False, .kw_pass, .kw_break, .kw_continue, .kw_try, .kw_except,
        .kw_finally, .kw_raise, .kw_nonlocal, .kw_lambda, .kw_assert, .kw_async, .kw_await, .kw_del,
        .kw_global, .kw_with, .kw_yield, .eof
    };

    for (expected) |t_type| {
        const token = lexer.next();
        try testing.expectEqual(t_type, token.type);
    }
}
