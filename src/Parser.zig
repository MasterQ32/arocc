const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const Compilation = @import("Compilation.zig");
const Source = @import("Source.zig");
const Token = @import("Tokenizer.zig").Token;
const Preprocessor = @import("Preprocessor.zig");
const Tree = @import("Tree.zig");
const TokenIndex = Tree.TokenIndex;
const NodeIndex = Tree.NodeIndex;
const Type = @import("Type.zig");
const Diagnostics = @import("Diagnostics.zig");
const NodeList = std.ArrayList(NodeIndex);

const Parser = @This();

pub const Result = union(enum) {
    none,
    bool: bool,
    char: i16, // large enough for u8 and i8
    u8: u8,
    i8: i8,
    u16: u16,
    i16: i16,
    u32: u32,
    i32: i32,
    u64: u64,
    i64: i64,
    lval: NodeIndex,
    node: NodeIndex,

    pub fn getBool(res: Result) bool {
        return switch (res) {
            .bool => |v| v,
            .u8 => |v| v != 0,
            .i8 => |v| v != 0,
            .u16 => |v| v != 0,
            .i16, .char => |v| v != 0,
            .u32 => |v| v != 0,
            .i32 => |v| v != 0,
            .u64 => |v| v != 0,
            .i64 => |v| v != 0,
            .none, .node, .lval => unreachable,
        };
    }

    fn expect(res: Result, p: *Parser) Error!void {
        if (res == .none) {
            try p.errTok(.expected_expr, p.tok_i);
            return error.ParsingFailed;
        }
    }

    fn node(p: *Parser, n: Tree.Node) !Result {
        return Result{ .node = try p.addNode(n) };
    }

    fn lval(p: *Parser, n: Tree.Node) !Result {
        return Result{ .lval = try p.addNode(n) };
    }

    fn ty(res: Result, p: *Parser) Type {
        const int_is_32_bits = (Type{ .specifier = .int }).sizeof(p.pp.comp) == 4;
        return switch (res) {
            .none => unreachable,
            .node, .lval => |n| p.nodes.items(.ty)[n],
            .bool => .{ .specifier = .bool },
            .char => .{ .specifier = .char },
            .u8 => .{ .specifier = .uchar },
            .i8 => .{ .specifier = .schar },
            .u16 => .{ .specifier = .ushort },
            .i16 => .{ .specifier = .short },
            .u32 => .{ .specifier = if (int_is_32_bits) .uint else .ulong },
            .i32 => .{ .specifier = if (int_is_32_bits) .int else .long },
            .u64 => .{ .specifier = .ulong_long },
            .i64 => .{ .specifier = .long_long },
        };
    }

    fn toNode(res: Result, p: *Parser) !NodeIndex {
        var parts: [2]TokenIndex = undefined;
        switch (res) {
            .none => return 0,
            .node, .lval => |n| return n,
            .bool => |v| parts[0] = @boolToInt(v),
            .u8 => |v| parts[0] = v,
            .i8 => |v| parts[0] = @bitCast(u32, @as(i32, v)),
            .u16 => |v| parts[0] = v,
            .i16, .char => |v| parts[0] = @bitCast(u32, @as(i32, v)),
            .u32 => |v| parts[0] = v,
            .i32 => |v| parts[0] = @bitCast(u32, v),
            .u64 => |v| parts = @bitCast([2]TokenIndex, v),
            .i64 => |v| parts = @bitCast([2]TokenIndex, v),
        }

        return p.addNode(.{
            .tag = if (res == .u64 or res == .i64) .int_64_literal else .int_32_literal,
            .ty = res.ty(p),
            .first = parts[0],
            .second = parts[1],
        });
    }

    fn coerce(res: Result, p: *Parser, dest_ty: Type) !Result {
        var casted = res;
        var cur_ty = res.ty(p);
        if (casted == .lval) {
            cur_ty.qual.@"const" = false;
            casted = try node(p, .{
                .tag = .lval_to_rval,
                .ty = cur_ty,
                .first = try casted.toNode(p),
            });
        }
        if (dest_ty.specifier == .pointer and cur_ty.isArray()) {
            const elem_ty = &cur_ty.data.array.elem;
            cur_ty.specifier = .pointer;
            cur_ty.data = .{ .sub_type = elem_ty };
            casted = try node(p, .{
                .tag = .array_to_pointer,
                .ty = cur_ty,
                .first = try casted.toNode(p),
            });
        }
        return casted;
    }

    fn hash(res: Result) u64 {
        var val: i64 = undefined;
        switch (res) {
            .bool => |v| val = @boolToInt(v),
            .u8 => |v| val = v,
            .i8 => |v| val = v,
            .u16 => |v| val = v,
            .i16, .char => |v| val = v,
            .u32 => |v| val = v,
            .i32 => |v| val = v,
            .u64 => |v| val = @bitCast(i64, v), // doesn't matter we only want a hash
            .i64 => |v| val = v,
            .none, .node, .lval => unreachable,
        }
        return std.hash.Wyhash.hash(0, mem.asBytes(&val));
    }

    fn eql(a: Result, b: Result) bool {
        var a_val: i64 = undefined;
        switch (a) {
            .bool => |v| a_val = @boolToInt(v),
            .u8 => |v| a_val = v,
            .i8 => |v| a_val = v,
            .u16 => |v| a_val = v,
            .i16, .char => |v| a_val = v,
            .u32 => |v| a_val = v,
            .i32 => |v| a_val = v,
            .u64 => |v| {
                if (v == @truncate(u63, v)) a_val = @truncate(u63, v) else @panic("eql a_val u64");
            },
            .i64 => |v| a_val = v,
            .none, .node, .lval => unreachable,
        }

        var b_val: i64 = undefined;
        switch (b) {
            .bool => |v| b_val = @boolToInt(v),
            .u8 => |v| b_val = v,
            .i8 => |v| b_val = v,
            .u16 => |v| b_val = v,
            .i16, .char => |v| b_val = v,
            .u32 => |v| b_val = v,
            .i32 => |v| b_val = v,
            .u64 => |v| {
                if (v == @truncate(u63, v)) b_val = @truncate(u63, v) else @panic("eql b_val u64");
            },
            .i64 => |v| b_val = v,
            .none, .node, .lval => unreachable,
        }
        return a_val == b_val;
    }
};

const Scope = union(enum) {
    typedef: Symbol,
    @"struct": Symbol,
    @"union": Symbol,
    @"enum": Symbol,
    symbol: Symbol,
    enumeration: Enumeration,
    loop,
    @"switch": *Switch,

    const Symbol = struct {
        name: []const u8,
        node: NodeIndex,
        name_tok: TokenIndex,
    };

    const Enumeration = struct {
        name: []const u8,
        value: Result,
    };

    const Switch = struct {
        cases: CaseMap,
        default: ?Case = null,

        const CaseMap = std.HashMap(Result, Case, Result.hash, Result.eql, std.hash_map.DefaultMaxLoadPercentage);
        const Case = struct {
            node: NodeIndex,
            tok: TokenIndex,
        };
    };
};

const Label = union(enum) {
    unresolved_goto: TokenIndex,
    label: TokenIndex,
};

pub const Error = Compilation.Error || error{ParsingFailed};

pp: *Preprocessor,
arena: *Allocator,
nodes: Tree.Node.List = .{},
data: NodeList,
scopes: std.ArrayList(Scope),
tokens: []const Token,
tok_i: TokenIndex = 0,
want_const: bool = false,
in_function: bool = false,
cur_decl_list: *NodeList,
labels: std.ArrayList(Label),
label_count: u32 = 0,

fn eatToken(p: *Parser, id: Token.Id) ?TokenIndex {
    const tok = p.tokens[p.tok_i];
    if (tok.id == id) {
        defer p.tok_i += 1;
        return p.tok_i;
    } else return null;
}

fn expectToken(p: *Parser, id: Token.Id) Error!TokenIndex {
    const tok = p.tokens[p.tok_i];
    if (tok.id != id) {
        try p.errExtra(
            switch (tok.id) {
                .invalid => .expected_invalid,
                else => .expected_token,
            },
            p.tok_i,
            .{ .tok_id = .{
                .expected = id,
                .actual = tok.id,
            } },
        );
        return error.ParsingFailed;
    }
    defer p.tok_i += 1;
    return p.tok_i;
}

fn expectClosing(p: *Parser, opening: TokenIndex, id: Token.Id) Error!void {
    _ = p.expectToken(id) catch |e| {
        if (e == error.ParsingFailed) {
            const o_tok = p.tokens[opening];
            try p.pp.comp.diag.add(.{
                .tag = switch (id) {
                    .r_paren => .to_match_paren,
                    .r_brace => .to_match_brace,
                    .r_bracket => .to_match_brace,
                    else => unreachable,
                },
                .source_id = o_tok.source,
                .loc_start = o_tok.loc.start,
            });
        }
        return e;
    };
}

pub fn errStr(p: *Parser, tag: Diagnostics.Tag, tok_i: TokenIndex, str: []const u8) Compilation.Error!void {
    @setCold(true);
    const tok = p.tokens[tok_i];
    return p.errExtra(tag, tok_i, .{ .str = str });
}

pub fn errExtra(p: *Parser, tag: Diagnostics.Tag, tok_i: TokenIndex, extra: Diagnostics.Message.Extra) Compilation.Error!void {
    @setCold(true);
    const tok = p.tokens[tok_i];
    try p.pp.comp.diag.add(.{
        .tag = tag,
        .source_id = tok.source,
        .loc_start = tok.loc.start,
        .extra = extra,
    });
}

pub fn errTok(p: *Parser, tag: Diagnostics.Tag, tok_i: TokenIndex) Compilation.Error!void {
    @setCold(true);
    const tok = p.tokens[tok_i];
    try p.pp.comp.diag.add(.{
        .tag = tag,
        .source_id = tok.source,
        .loc_start = tok.loc.start,
    });
}

pub fn err(p: *Parser, tag: Diagnostics.Tag) Compilation.Error!void {
    @setCold(true);
    return p.errTok(tag, p.tok_i);
}

pub fn todo(p: *Parser, msg: []const u8) Error {
    try p.errStr(.todo, p.tok_i, msg);
    return error.ParsingFailed;
}

fn addNode(p: *Parser, node: Tree.Node) Allocator.Error!NodeIndex {
    const res = p.nodes.len;
    try p.nodes.append(p.pp.comp.gpa, node);
    return @intCast(u32, res);
}

const Range = struct { start: u32, end: u32 };
fn addList(p: *Parser, nodes: []const NodeIndex) Allocator.Error!Range {
    const start = @intCast(u32, p.data.items.len);
    try p.data.appendSlice(nodes);
    const end = @intCast(u32, p.data.items.len);
    return Range{ .start = start, .end = end };
}

fn findTypedef(p: *Parser, name: []const u8) ?Scope.Symbol {
    var i = p.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (p.scopes.items[i]) {
            .typedef => |t| if (mem.eql(u8, t.name, name)) return t,
            else => {},
        }
    }
    return null;
}

fn findSymbol(p: *Parser, name_tok: TokenIndex) ?Scope {
    const name = p.pp.tokSlice(p.tokens[name_tok]);
    var i = p.scopes.items.len;
    while (i > 0) {
        i -= 1;
        const sym = p.scopes.items[i];
        switch (sym) {
            .symbol => |s| if (mem.eql(u8, s.name, name)) return sym,
            .enumeration => |e| if (mem.eql(u8, e.name, name)) return sym,
            else => {},
        }
    }
    return null;
}

fn inLoop(p: *Parser) bool {
    var i = p.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (p.scopes.items[i]) {
            .loop => return true,
            else => {},
        }
    }
    return false;
}

fn inLoopOrSwitch(p: *Parser) bool {
    var i = p.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (p.scopes.items[i]) {
            .loop, .@"switch" => return true,
            else => {},
        }
    }
    return false;
}

fn findLabel(p: *Parser, name: []const u8) ?NodeIndex {
    for (p.labels.items) |item| {
        switch (item) {
            .label => |l| if (mem.eql(u8, p.pp.tokSlice(p.tokens[l]), name)) return l,
            .unresolved_goto => {},
        }
    }
    return null;
}

fn findSwitch(p: *Parser) ?*Scope.Switch {
    var i = p.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (p.scopes.items[i]) {
            .@"switch" => |s| return s,
            else => {},
        }
    }
    return null;
}

/// root : (decl | staticAssert)*
pub fn parse(pp: *Preprocessor) Compilation.Error!Tree {
    var root_decls = NodeList.init(pp.comp.gpa);
    defer root_decls.deinit();
    var arena = std.heap.ArenaAllocator.init(pp.comp.gpa);
    errdefer arena.deinit();
    var p = Parser{
        .pp = pp,
        .arena = &arena.allocator,
        .tokens = pp.tokens.items,
        .cur_decl_list = &root_decls,
        .scopes = std.ArrayList(Scope).init(pp.comp.gpa),
        .data = NodeList.init(pp.comp.gpa),
        .labels = std.ArrayList(Label).init(pp.comp.gpa),
    };
    defer p.scopes.deinit();
    defer p.data.deinit();
    defer p.labels.deinit();
    errdefer p.nodes.deinit(pp.comp.gpa);

    // NodeIndex 0 must be invalid
    _ = try p.addNode(.{ .tag = .invalid, .ty = undefined });

    while (p.eatToken(.eof) == null) {
        if (p.staticAssert() catch |er| switch (er) {
            error.ParsingFailed => {
                p.nextExternDecl();
                continue;
            },
            else => |e| return e,
        }) continue;
        if (p.decl() catch |er| switch (er) {
            error.ParsingFailed => {
                p.nextExternDecl();
                continue;
            },
            else => |e| return e,
        }) continue;

        try p.err(.expected_external_decl);
        p.tok_i += 1;
    }
    return Tree{
        .comp = pp.comp,
        .tokens = pp.tokens.items,
        .arena = arena,
        .generated = pp.generated.items,
        .nodes = p.nodes.toOwnedSlice(),
        .data = p.data.toOwnedSlice(),
        .root_decls = root_decls.toOwnedSlice(),
    };
}

fn nextExternDecl(p: *Parser) void {
    var parens: u32 = 0;
    while (p.tok_i < p.tokens.len) : (p.tok_i += 1) {
        switch (p.tokens[p.tok_i].id) {
            .l_paren, .l_brace, .l_bracket => parens += 1,
            .r_paren, .r_brace, .r_bracket => if (parens != 0) {
                parens -= 1;
            },
            .keyword_typedef,
            .keyword_extern,
            .keyword_static,
            .keyword_auto,
            .keyword_register,
            .keyword_thread_local,
            .keyword_inline,
            .keyword_noreturn,
            .keyword_void,
            .keyword_bool,
            .keyword_char,
            .keyword_short,
            .keyword_int,
            .keyword_long,
            .keyword_signed,
            .keyword_unsigned,
            .keyword_float,
            .keyword_double,
            .keyword_complex,
            .keyword_atomic,
            .keyword_enum,
            .keyword_struct,
            .keyword_union,
            .keyword_alignas,
            .identifier,
            => if (parens == 0) return,
            else => {},
        }
    }
    p.tok_i -= 1; // so that we can consume the eof token elsewhere
}

// ====== declarations ======

/// decl
///  : declSpec (initDeclarator ( ',' initDeclarator)*)? ';'
///  | declSpec declarator decl* compoundStmt
fn decl(p: *Parser) Error!bool {
    const first_tok = p.tok_i;
    var decl_spec = if (try p.declSpec()) |some|
        some
    else blk: {
        if (p.in_function) return false;
        switch (p.tokens[first_tok].id) {
            .asterisk, .l_paren, .identifier => {},
            else => return false,
        }
        var d: DeclSpec = .{};
        var spec: Type.Builder = .{};
        try spec.finish(p, &d.ty);
        break :blk d;
    };
    var init_d = (try p.initDeclarator(&decl_spec)) orelse {
        // TODO return if enum struct or union
        try p.errTok(.missing_declaration, first_tok);
        _ = try p.expectToken(.semicolon);
        return true;
    };

    // Check for function definition.
    if (init_d.d.func_declarator != null and init_d.initializer == 0 and init_d.d.ty.isFunc()) fn_def: {
        switch (p.tokens[p.tok_i].id) {
            .comma, .semicolon => break :fn_def,
            .l_brace => {},
            else => {
                if (!p.in_function) try p.err(.expected_fn_body);
                break :fn_def;
            },
        }

        // TODO declare all parameters
        // for (init_d.d.ty.data.func.param_types) |param| {}

        // Collect old style parameter declarations.
        if (init_d.d.old_style_func != null and !p.in_function) {
            param_loop: while (true) {
                const param_decl_spec = (try p.declSpec()) orelse break;
                if (p.eatToken(.semicolon)) |semi| {
                    try p.errTok(.missing_declaration, semi);
                    continue :param_loop;
                }

                while (true) {
                    var d = (try p.declarator(param_decl_spec.ty, .normal)) orelse {
                        try p.errTok(.missing_declaration, first_tok);
                        _ = try p.expectToken(.semicolon);
                        continue :param_loop;
                    };

                    if (d.ty.isFunc()) {
                        // Params declared as functions are converted to function pointers.
                        const elem_ty = try p.arena.create(Type);
                        elem_ty.* = d.ty;
                        d.ty = Type{
                            .specifier = .pointer,
                            .data = .{ .sub_type = elem_ty },
                        };
                    } else if (d.ty.specifier == .void) {
                        try p.errTok(.invalid_void_param, d.name);
                    }

                    // TODO declare and check that d.name is in init_d.d.ty.data.func.param_types
                    if (p.eatToken(.comma) == null) break;
                }
                _ = try p.expectToken(.semicolon);
            }
        }
        if (p.in_function) try p.err(.func_not_in_root);

        const in_function = p.in_function;
        p.in_function = true;
        defer p.in_function = in_function;

        const node = try p.addNode(.{
            .ty = init_d.d.ty,
            .tag = try decl_spec.validateFnDef(p),
            .first = init_d.d.name,
        });
        try p.scopes.append(.{ .symbol = .{
            .name = p.pp.tokSlice(p.tokens[init_d.d.name]),
            .node = node,
            .name_tok = init_d.d.name,
        } });
        const body = try p.compoundStmt();
        p.nodes.items(.second)[node] = body.?;

        // check gotos
        if (!in_function) {
            for (p.labels.items) |item| {
                if (item == .unresolved_goto)
                    try p.errStr(.undeclared_label, item.unresolved_goto, p.pp.tokSlice(p.tokens[item.unresolved_goto]));
            }
            p.labels.items.len = 0;
            p.label_count = 0;
        }

        try p.cur_decl_list.append(node);
        return true;
    }

    // Declare all variable/typedef declarators.
    while (true) {
        if (init_d.d.old_style_func) |tok_i| try p.errTok(.invalid_old_style_params, tok_i);
        const node = try p.addNode(.{
            .ty = init_d.d.ty,
            .tag = try decl_spec.validate(p, init_d.d.ty, init_d.initializer != 0),
            .first = init_d.d.name,
            .second = init_d.initializer,
        });
        try p.cur_decl_list.append(node);
        if (decl_spec.storage_class == .typedef) {
            try p.scopes.append(.{ .typedef = .{
                .name = p.pp.tokSlice(p.tokens[init_d.d.name]),
                .node = node,
                .name_tok = init_d.d.name,
            } });
        } else {
            try p.scopes.append(.{ .symbol = .{
                .name = p.pp.tokSlice(p.tokens[init_d.d.name]),
                .node = node,
                .name_tok = init_d.d.name,
            } });
        }

        if (p.eatToken(.comma) == null) break;

        init_d = (try p.initDeclarator(&decl_spec)) orelse {
            try p.err(.expected_ident_or_l_paren);
            continue;
        };
    }
    _ = try p.expectToken(.semicolon);
    return true;
}

/// staticAssert : keyword_static_assert '(' constExpr ',' STRING_LITERAL ')' ';'
fn staticAssert(p: *Parser) Error!bool {
    const static_assert = p.eatToken(.keyword_static_assert) orelse return false;
    const l_paren = try p.expectToken(.l_paren);
    const start = p.tok_i;
    const res = try p.constExpr();
    const end = p.tok_i;
    _ = try p.expectToken(.comma);
    const str = try p.expectToken(.string_literal); // TODO resolve string literal
    try p.expectClosing(l_paren, .r_paren);

    if (!res.getBool()) {
        var msg = std.ArrayList(u8).init(p.pp.comp.gpa);
        defer msg.deinit();

        try msg.append('\'');
        for (p.tokens[start..end]) |tok, i| {
            if (i != 0) try msg.append(' ');
            try msg.appendSlice(p.pp.tokSlice(tok));
        }
        try msg.appendSlice("' ");
        try msg.appendSlice(p.pp.tokSlice(p.tokens[str]));
        try p.errStr(.static_assert_failure, static_assert, try p.arena.dupe(u8, msg.items));
    }
    return true;
}

pub const DeclSpec = struct {
    storage_class: union(enum) {
        auto: TokenIndex,
        @"extern": TokenIndex,
        register: TokenIndex,
        static: TokenIndex,
        typedef: TokenIndex,
        none,
    } = .none,
    thread_local: ?TokenIndex = null,
    @"inline": ?TokenIndex = null,
    @"noreturn": ?TokenIndex = null,
    ty: Type = .{ .specifier = undefined },

    fn validateParam(d: DeclSpec, p: *Parser, ty: Type) Error!Tree.Tag {
        switch (d.storage_class) {
            .none, .register => {},
            .auto, .@"extern", .static, .typedef => |tok_i| try p.errTok(.invalid_storage_on_param, tok_i),
        }
        if (d.thread_local) |tok_i| try p.errTok(.threadlocal_non_var, tok_i);
        if (d.@"inline") |tok_i| try p.errStr(.func_spec_non_func, tok_i, "inline");
        if (d.@"noreturn") |tok_i| try p.errStr(.func_spec_non_func, tok_i, "_Noreturn");
        return if (d.storage_class == .register) .register_param_decl else .param_decl;
    }

    fn validateFnDef(d: DeclSpec, p: *Parser) Error!Tree.Tag {
        switch (d.storage_class) {
            .none, .@"extern", .static => {},
            .auto, .register, .typedef => |tok_i| try p.errTok(.illegal_storage_on_func, tok_i),
        }
        if (d.thread_local) |tok_i| try p.errTok(.threadlocal_non_var, tok_i);

        const is_static = d.storage_class == .static;
        const is_inline = d.@"inline" != null;
        const is_noreturn = d.@"noreturn" != null;
        if (is_static) {
            if (is_inline and is_noreturn) return .noreturn_inline_static_fn_def;
            if (is_inline) return .inline_static_fn_def;
            if (is_noreturn) return .noreturn_static_fn_def;
            return .static_fn_def;
        } else {
            if (is_inline and is_noreturn) return .noreturn_inline_fn_def;
            if (is_inline) return .inline_fn_def;
            if (is_noreturn) return .noreturn_fn_def;
            return .fn_def;
        }
    }

    fn validate(d: DeclSpec, p: *Parser, ty: Type, has_init: bool) Error!Tree.Tag {
        const is_static = d.storage_class == .static;
        if (ty.isFunc() and d.storage_class != .typedef) {
            switch (d.storage_class) {
                .none, .@"extern" => {},
                .static => |tok_i| if (p.in_function) try p.errTok(.static_func_not_global, tok_i),
                .typedef => unreachable,
                .auto, .register => |tok_i| try p.errTok(.illegal_storage_on_func, tok_i),
            }
            if (d.thread_local) |tok_i| try p.errTok(.threadlocal_non_var, tok_i);

            const is_inline = d.@"inline" != null;
            const is_noreturn = d.@"noreturn" != null;
            if (is_static) {
                if (is_inline and is_noreturn) return .noreturn_inline_static_fn_proto;
                if (is_inline) return .inline_static_fn_proto;
                if (is_noreturn) return .noreturn_static_fn_proto;
                return .static_fn_proto;
            } else {
                if (is_inline and is_noreturn) return .noreturn_inline_fn_proto;
                if (is_inline) return .inline_fn_proto;
                if (is_noreturn) return .noreturn_fn_proto;
                return .fn_proto;
            }
        } else {
            if (d.@"inline") |tok_i| try p.errStr(.func_spec_non_func, tok_i, "inline");
            if (d.@"noreturn") |tok_i| try p.errStr(.func_spec_non_func, tok_i, "_Noreturn");
            switch (d.storage_class) {
                .auto, .register => if (!p.in_function) try p.err(.illegal_storage_on_global),
                .typedef => return .typedef,
                else => {},
            }

            const is_extern = d.storage_class == .@"extern" and !has_init;
            if (d.thread_local != null) {
                if (is_static) return .threadlocal_static_var;
                if (is_extern) return .threadlocal_extern_var;
                return .threadlocal_var;
            } else {
                if (is_static) return .static_var;
                if (is_extern) return .extern_var;
                return .@"var";
            }
        }
    }
};

/// declSpec: (storageClassSpec | typeSpec | typeQual | funcSpec | alignSpec)+
/// storageClassSpec:
///  : keyword_typedef
///  | keyword_extern
///  | keyword_static
///  | keyword_threadlocal
///  | keyword_auto
///  | keyword_register
/// funcSpec : keyword_inline | keyword_noreturn
fn declSpec(p: *Parser) Error!?DeclSpec {
    var d: DeclSpec = .{};
    var spec: Type.Builder = .{};

    const start = p.tok_i;
    while (true) {
        if (try p.typeSpec(&spec, &d.ty)) continue;
        const tok = p.tokens[p.tok_i];
        switch (tok.id) {
            .keyword_typedef,
            .keyword_extern,
            .keyword_static,
            .keyword_auto,
            .keyword_register,
            => {
                if (d.storage_class != .none) {
                    try p.errStr(.multiple_storage_class, p.tok_i, @tagName(d.storage_class));
                    return error.ParsingFailed;
                }
                if (d.thread_local != null) {
                    switch (tok.id) {
                        .keyword_typedef,
                        .keyword_auto,
                        .keyword_register,
                        => try p.errStr(.cannot_combine_spec, p.tok_i, tok.id.lexeme().?),
                        else => {},
                    }
                }
                switch (tok.id) {
                    .keyword_typedef => d.storage_class = .{ .typedef = p.tok_i },
                    .keyword_extern => d.storage_class = .{ .@"extern" = p.tok_i },
                    .keyword_static => d.storage_class = .{ .static = p.tok_i },
                    .keyword_auto => d.storage_class = .{ .auto = p.tok_i },
                    .keyword_register => d.storage_class = .{ .register = p.tok_i },
                    else => unreachable,
                }
            },
            .keyword_thread_local => {
                if (d.thread_local != null) {
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "_Thread_local");
                }
                switch (d.storage_class) {
                    .@"extern", .none, .static => {},
                    else => try p.errStr(.cannot_combine_spec, p.tok_i, @tagName(d.storage_class)),
                }
                d.thread_local = p.tok_i;
            },
            .keyword_inline => {
                if (d.@"inline" != null) {
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "inline");
                }
                d.@"inline" = p.tok_i;
            },
            .keyword_noreturn => {
                if (d.@"noreturn" != p.tok_i) {
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "_Noreturn");
                }
                d.@"noreturn" = null;
            },
            else => break,
        }
        p.tok_i += 1;
    }

    if (p.tok_i == start) return null;
    try spec.finish(p, &d.ty);
    return d;
}

const InitDeclarator = struct { d: Declarator, initializer: NodeIndex = 0 };

/// initDeclarator : declarator ('=' initializer)?
fn initDeclarator(p: *Parser, decl_spec: *DeclSpec) Error!?InitDeclarator {
    var init_d = InitDeclarator{
        .d = (try p.declarator(decl_spec.ty, .normal)) orelse return null,
    };
    if (p.eatToken(.equal)) |eq| {
        if (decl_spec.storage_class == .typedef or
            decl_spec.ty.isFunc()) try p.err(.illegal_initializer);
        if (decl_spec.storage_class == .@"extern") {
            try p.err(.extern_initializer);
            decl_spec.storage_class = .none;
        }
        const init = try p.initializer();
        const casted = try init.coerce(p, init_d.d.ty);
        init_d.initializer = try casted.toNode(p);
    }
    return init_d;
}

/// typeSpec
///  : keyword_void
///  | keyword_char
///  | keyword_short
///  | keyword_int
///  | keyword_long
///  | keyword_float
///  | keyword_double
///  | keyword_signed
///  | keyword_unsigned
///  | keyword_bool
///  | keyword_complex
///  | atomicTypeSpec
///  | recordSpec
///  | enumSpec
///  | typedef  // IDENTIFIER
/// atomicTypeSpec : keyword_atomic '(' typeName ')'
/// alignSpec : keyword_alignas '(' typeName ')'
fn typeSpec(p: *Parser, ty: *Type.Builder, complete_type: *Type) Error!bool {
    const start = p.tok_i;
    while (true) {
        if (try p.typeQual(complete_type)) continue;
        const tok = p.tokens[p.tok_i];
        switch (tok.id) {
            .keyword_void => try ty.combine(p, .void),
            .keyword_bool => try ty.combine(p, .bool),
            .keyword_char => try ty.combine(p, .char),
            .keyword_short => try ty.combine(p, .short),
            .keyword_int => try ty.combine(p, .int),
            .keyword_long => try ty.combine(p, .long),
            .keyword_signed => try ty.combine(p, .signed),
            .keyword_unsigned => try ty.combine(p, .unsigned),
            .keyword_float => try ty.combine(p, .float),
            .keyword_double => try ty.combine(p, .double),
            .keyword_complex => try ty.combine(p, .complex),
            .keyword_atomic => return p.todo("atomic types"),
            .keyword_enum => {
                try ty.combine(p, .{ .@"enum" = 0 });
                ty.kind.@"enum" = try p.enumSpec();
                continue;
            },
            .keyword_struct => {
                try ty.combine(p, .{ .@"struct" = 0 });
                ty.kind.@"struct" = try p.recordSpec();
                continue;
            },
            .keyword_union => {
                try ty.combine(p, .{ .@"union" = 0 });
                ty.kind.@"union" = try p.recordSpec();
                continue;
            },
            .keyword_alignas => {
                if (complete_type.alignment != 0) try p.errStr(.duplicate_decl_spec, p.tok_i, "alignment");
                const l_paren = try p.expectToken(.l_paren);
                const other_type = (try p.typeName()) orelse {
                    try p.err(.expected_type);
                    return error.ParsingFailed;
                };
                try p.expectClosing(l_paren, .r_paren);
                complete_type.alignment = other_type.alignment;
            },
            .identifier => {
                const typedef = p.findTypedef(p.pp.tokSlice(tok)) orelse break;
                const new_spec = Type.Builder.fromType(p.nodes.items(.ty)[typedef.node]);

                const err_start = p.pp.comp.diag.list.items.len;
                ty.combine(p, new_spec) catch {
                    // Remove new error messages
                    // TODO improve/make threadsafe?
                    p.pp.comp.diag.list.items.len = err_start;
                    break;
                };
                ty.typedef = .{
                    .tok = typedef.name_tok,
                    .spec = new_spec.str(),
                };
            },
            else => break,
        }
        p.tok_i += 1;
    }
    return p.tok_i != start;
}

/// recordSpec
///  : (keyword_struct | keyword_union) IDENTIFIER? { recordDecl* }
///  | (keyword_struct | keyword_union) IDENTIFIER
fn recordSpec(p: *Parser) Error!NodeIndex {
    const kind_tok = p.tokens[p.tok_i];
    p.tok_i += 1;
    return p.todo("recordSpec");
}

/// recordDecl
///  : specQual (recordDeclarator (',' recordDeclarator)*)? ;
///  | staticAssert
fn recordDecl(p: *Parser) Error!NodeIndex {
    return p.todo("recordDecl");
}

/// recordDeclarator : declarator (':' constExpr)?
fn recordDeclarator(p: *Parser) Error!NodeIndex {
    return p.todo("recordDeclarator");
}

/// specQual : (typeSpec | typeQual | alignSpec)+
fn specQual(p: *Parser) Error!?Type {
    var spec: Type.Builder = .{};
    var ty: Type = .{ .specifier = undefined };
    if (try p.typeSpec(&spec, &ty)) {
        try spec.finish(p, &ty);
        return ty;
    }
    return null;
}

/// enumSpec
///  : keyword_enum IDENTIFIER? { enumerator (',' enumerator)? ',') }
///  | keyword_enum IDENTIFIER
fn enumSpec(p: *Parser) Error!NodeIndex {
    const enum_tok = p.tokens[p.tok_i];
    p.tok_i += 1;
    return p.todo("enumSpec");
}

/// enumerator : IDENTIFIER ('=' constExpr)
fn enumerator(p: *Parser) Error!NodeIndex {
    return p.todo("enumerator");
}

/// typeQual : keyword_const | keyword_restrict | keyword_volatile | keyword_atomic
fn typeQual(p: *Parser, ty: *Type) Error!bool {
    var any = false;
    while (true) {
        const tok = p.tokens[p.tok_i];
        switch (tok.id) {
            .keyword_restrict => {
                if (ty.specifier != .pointer)
                    try p.pp.comp.diag.add(.{
                        .tag = .restrict_non_pointer,
                        .source_id = tok.source,
                        .loc_start = tok.loc.start,
                        .extra = .{ .str = Type.Builder.fromType(ty.*).str() },
                    })
                else if (ty.qual.restrict)
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "restrict")
                else
                    ty.qual.restrict = true;
            },
            .keyword_const => {
                if (ty.qual.@"const")
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "const")
                else
                    ty.qual.@"const" = true;
            },
            .keyword_volatile => {
                if (ty.qual.@"volatile")
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "volatile")
                else
                    ty.qual.@"volatile" = true;
            },
            .keyword_atomic => {
                if (ty.qual.atomic)
                    try p.errStr(.duplicate_decl_spec, p.tok_i, "atomic")
                else
                    ty.qual.atomic = true;
            },
            else => break,
        }
        p.tok_i += 1;
        any = true;
    }
    return any;
}

const Declarator = struct {
    name: TokenIndex,
    ty: Type,
    func_declarator: ?TokenIndex = null,
    old_style_func: ?TokenIndex = null,
};
const DeclaratorKind = enum { normal, abstract, param };

/// declarator : pointer? (IDENTIFIER | '(' declarator ')') directDeclarator*
/// abstractDeclarator
/// : pointer? ('(' abstractDeclarator ')')? directAbstractDeclarator*
fn declarator(
    p: *Parser,
    base_type: Type,
    kind: DeclaratorKind,
) Error!?Declarator {
    const start = p.tok_i;
    var d = Declarator{ .name = 0, .ty = try p.pointer(base_type) };

    if (kind != .abstract and p.tokens[p.tok_i].id == .identifier) {
        d.name = p.tok_i;
        p.tok_i += 1;
        d.ty = try p.directDeclarator(d.ty, &d, kind);
        return d;
    } else if (p.eatToken(.l_paren)) |l_paren| blk: {
        var res = (try p.declarator(.{ .specifier = .void }, kind)) orelse {
            p.tok_i = l_paren;
            break :blk;
        };
        try p.expectClosing(l_paren, .r_paren);
        const suffix_start = p.tok_i;
        const outer = try p.directDeclarator(d.ty, &d, kind);
        try res.ty.combine(outer, p, res.func_declarator orelse suffix_start);
        res.old_style_func = d.old_style_func;
        return res;
    }

    if (kind == .normal) {
        try p.err(.expected_ident_or_l_paren);
    }

    d.ty = try p.directDeclarator(d.ty, &d, kind);
    if (start == p.tok_i) return null;
    return d;
}

/// directDeclarator
///  : '[' typeQual* assignExpr? ']' directDeclarator?
///  | '[' keyword_static typeQual* assignExpr ']' directDeclarator?
///  | '[' typeQual+ keyword_static assignExpr ']' directDeclarator?
///  | '[' typeQual* '*' ']' directDeclarator?
///  | '(' paramDecls ')' directDeclarator?
///  | '(' (IDENTIFIER (',' IDENTIFIER))? ')' directDeclarator?
/// directAbstractDeclarator
///  : '[' typeQual* assignExpr? ']'
///  | '[' keyword_static typeQual* assignExpr ']'
///  | '[' typeQual+ keyword_static assignExpr ']'
///  | '[' '*' ']'
///  | '(' paramDecls? ')'
fn directDeclarator(p: *Parser, base_type: Type, d: *Declarator, kind: DeclaratorKind) Error!Type {
    if (p.eatToken(.l_bracket)) |l_bracket| {
        var res_ty = Type{
            // so that we can get any restrict type that might be present
            .specifier = .pointer,
        };

        var got_quals = try p.typeQual(&res_ty);
        var static = p.eatToken(.keyword_static);
        if (static != null and !got_quals) got_quals = try p.typeQual(&res_ty);
        var star = p.eatToken(.asterisk);
        const size = if (star) |_| Result{ .none = {} } else try p.assignExpr();
        try p.expectClosing(l_bracket, .r_bracket);

        if (star != null and static != null) {
            try p.errTok(.invalid_static_star, static.?);
            static = null;
        }
        if (kind != .param) {
            if (static != null)
                try p.errTok(.static_non_param, l_bracket)
            else if (got_quals)
                try p.errTok(.array_qualifiers, l_bracket);
            if (star) |some| try p.errTok(.star_non_param, some);
            static = null;
            res_ty.qual = .{};
            star = null;
        }
        if (static) |_| try size.expect(p);

        switch (size) {
            .none => if (star) |_| {
                const elem_ty = try p.arena.create(Type);
                res_ty.data = .{ .sub_type = elem_ty };
                res_ty.specifier = .unspecified_variable_len_array;
            } else {
                const arr_ty = try p.arena.create(Type.Array);
                arr_ty.len = 0;
                res_ty.data = .{ .array = arr_ty };
                res_ty.specifier = .incomplete_array;
            },
            .lval, .node => |n| {
                if (!p.in_function and kind != .param) try p.errTok(.variable_len_array_file_scope, l_bracket);
                const vla_ty = try p.arena.create(Type.VLA);
                vla_ty.expr = n;
                res_ty.data = .{ .vla = vla_ty };
                res_ty.specifier = .variable_len_array;

                if (static) |some| try p.errTok(.useless_static, some);
            },
            else => {
                const arr_ty = try p.arena.create(Type.Array);
                res_ty.data = .{ .array = arr_ty };
                res_ty.specifier = if (static != null) .static_array else .array;

                var negative = false;
                switch (size) {
                    .u8 => |v| arr_ty.len = v,
                    .u16 => |v| arr_ty.len = v,
                    .u32 => |v| arr_ty.len = v,
                    .u64 => |v| arr_ty.len = v,
                    .i8 => |v| {
                        if (v < 0) negative = true;
                        arr_ty.len = @bitCast(u8, v);
                    },
                    .i16, .char => |v| {
                        if (v < 0) negative = true;
                        arr_ty.len = @bitCast(u16, v);
                    },
                    .i32 => |v| {
                        if (v < 0) negative = true;
                        arr_ty.len = @bitCast(u32, v);
                    },
                    .i64 => |v| {
                        if (v < 0) negative = true;
                        arr_ty.len = @bitCast(u64, v);
                    },
                    else => unreachable,
                }
                if (negative) try p.errTok(.negative_array_size, l_bracket);
            },
        }

        const outer = try p.directDeclarator(base_type, d, kind);
        try res_ty.combine(outer, p, l_bracket);
        return res_ty;
    } else if (p.eatToken(.l_paren)) |l_paren| {
        d.func_declarator = l_paren;
        if (p.tokens[p.tok_i].id == .ellipsis) {
            try p.err(.param_before_var_args);
            p.tok_i += 1;
        }

        const func_ty = try p.arena.create(Type.Func);
        func_ty.param_types = &.{};
        var specifier: Type.Specifier = .func;

        if (try p.paramDecls()) |params| {
            func_ty.param_types = params;
            if (p.eatToken(.ellipsis)) |_| specifier = .var_args_func;
        } else if (p.tokens[p.tok_i].id == .r_paren) {
            specifier = .old_style_func;
        } else if (p.tokens[p.tok_i].id == .identifier) {
            d.old_style_func = p.tok_i;
            var params = NodeList.init(p.pp.comp.gpa);
            defer params.deinit();

            specifier = .old_style_func;
            while (true) {
                const param = try p.addNode(.{
                    .tag = .param_decl,
                    .ty = .{ .specifier = .int },
                    .first = try p.expectToken(.identifier),
                });
                try params.append(param);
                if (p.eatToken(.comma) == null) break;
            }
            func_ty.param_types = try p.arena.dupe(NodeIndex, params.items);
        } else {
            try p.err(.expected_param_decl);
        }

        try p.expectClosing(l_paren, .r_paren);
        var res_ty = Type{
            .specifier = specifier,
            .data = .{ .func = func_ty },
        };

        const outer = try p.directDeclarator(base_type, d, kind);
        try res_ty.combine(outer, p, l_paren);
        return res_ty;
    } else return base_type;
}

/// pointer : '*' typeQual* pointer?
fn pointer(p: *Parser, base_ty: Type) Error!Type {
    var ty = base_ty;
    while (p.eatToken(.asterisk)) |_| {
        const elem_ty = try p.arena.create(Type);
        elem_ty.* = ty;
        ty = Type{
            .specifier = .pointer,
            .data = .{ .sub_type = elem_ty },
        };
        _ = try p.typeQual(&ty);
    }
    return ty;
}

/// paramDecls : paramDecl (',' paramDecl)* (',' '...')
/// paramDecl : declSpec (declarator | abstractDeclarator)
fn paramDecls(p: *Parser) Error!?[]NodeIndex {
    var params = NodeList.init(p.pp.comp.gpa);
    defer params.deinit();

    while (true) {
        const param_decl_spec = if (try p.declSpec()) |some|
            some
        else if (params.items.len == 0)
            return null
        else blk: {
            var d: DeclSpec = .{};
            var spec: Type.Builder = .{};
            try spec.finish(p, &d.ty);
            break :blk d;
        };

        var name_tok = p.tok_i;
        var param_ty = param_decl_spec.ty;
        if (try p.declarator(param_decl_spec.ty, .param)) |some| {
            if (some.old_style_func) |tok_i| try p.errTok(.invalid_old_style_params, tok_i);
            // TODO declare();
            name_tok = some.name;
            param_ty = some.ty;
        }

        if (param_ty.isFunc()) {
            // params declared as functions are converted to function pointers
            const elem_ty = try p.arena.create(Type);
            elem_ty.* = param_ty;
            param_ty = Type{
                .specifier = .pointer,
                .data = .{ .sub_type = elem_ty },
            };
        } else if (param_ty.specifier == .void) {
            // validate void parameters
            if (params.items.len == 0) {
                if (p.tokens[p.tok_i].id != .r_paren) {
                    try p.err(.void_only_param);
                    if (param_ty.qual.any()) try p.err(.void_param_qualified);
                    return error.ParsingFailed;
                }
                return &[0]NodeIndex{};
            }
            try p.err(.void_must_be_first_param);
            return error.ParsingFailed;
        } else if (param_ty.isArray()) {
            // TODO convert to pointer
        }

        const param = try p.addNode(.{
            .tag = try param_decl_spec.validateParam(p, param_ty),
            .ty = param_ty,
            .first = name_tok,
        });
        try params.append(param);

        if (p.eatToken(.comma) == null) break;
        if (p.tokens[p.tok_i].id == .ellipsis) break;
    }
    return try p.arena.dupe(NodeIndex, params.items);
}

/// typeName : specQual abstractDeclarator
fn typeName(p: *Parser) Error!?Type {
    var ty = (try p.specQual()) orelse return null;
    if (try p.declarator(ty, .abstract)) |some| {
        if (some.old_style_func) |tok_i| try p.errTok(.invalid_old_style_params, tok_i);
        return some.ty;
    } else return ty;
}

/// initializer
///  : assignExpr
///  | '{' initializerItems '}'
fn initializer(p: *Parser) Error!Result {
    if (p.eatToken(.l_brace)) |l_brace| {
        return p.todo("compound initializer");
    }
    const res = try p.assignExpr();
    try res.expect(p);
    return res;
}

/// initializerItems : designation? initializer  (',' designation? initializer)? ','?
fn initializerItems(p: *Parser) Error!NodeIndex {
    return p.todo("initializerItems");
}
/// designation : designator+ '='
fn designation(p: *Parser) Error!NodeIndex {
    return p.todo("designation");
}

/// designator
///  : '[' constExpr ']'
///  | '.' identifier
fn designator(p: *Parser) Error!NodeIndex {
    return p.todo("designator");
}

// ====== statements ======

/// stmt
///  : labeledStmt
///  | compoundStmt
///  | keyword_if '(' expr ')' stmt (keyword_else stmt)?
///  | keyword_switch '(' expr ')' stmt
///  | keyword_while '(' expr ')' stmt
///  | keyword_do stmt while '(' expr ')' ';'
///  | keyword_for '(' (decl | expr? ';') expr? ';' expr? ')' stmt
///  | keyword_goto IDENTIFIER ';'
///  | keyword_continue ';'
///  | keyword_break ';'
///  | keyword_return expr? ';'
///  | expr? ';'
fn stmt(p: *Parser) Error!NodeIndex {
    if (try p.labeledStmt()) |some| return some;
    if (try p.compoundStmt()) |some| return some;
    if (p.eatToken(.keyword_if)) |_| {
        const start_scopes_len = p.scopes.items.len;
        defer p.scopes.items.len = start_scopes_len;

        const l_paren = try p.expectToken(.l_paren);
        const cond = try p.expr();
        // TODO validate type
        try cond.expect(p);
        const cond_node = try cond.toNode(p);
        try p.expectClosing(l_paren, .r_paren);

        const then = try p.stmt();
        const @"else" = if (p.eatToken(.keyword_else)) |_| try p.stmt() else 0;

        if (then != 0 and @"else" != 0)
            return try p.addNode(.{
                .tag = .if_then_else_stmt,
                .first = cond_node,
                .second = (try p.addList(&.{ then, @"else" })).start,
            })
        else if (then == 0 and @"else" != 0)
            return try p.addNode(.{
                .tag = .if_else_stmt,
                .first = cond_node,
                .second = @"else",
            })
        else
            return try p.addNode(.{
                .tag = .if_then_stmt,
                .first = cond_node,
                .second = then,
            });
    }
    if (p.eatToken(.keyword_switch)) |_| {
        const start_scopes_len = p.scopes.items.len;
        defer p.scopes.items.len = start_scopes_len;

        const l_paren = try p.expectToken(.l_paren);
        const cond = try p.expr();
        // TODO validate type
        try cond.expect(p);
        const cond_node = try cond.toNode(p);
        try p.expectClosing(l_paren, .r_paren);

        var switch_scope = Scope.Switch{
            .cases = Scope.Switch.CaseMap.init(p.pp.comp.gpa),
        };
        defer switch_scope.cases.deinit();
        try p.scopes.append(.{ .@"switch" = &switch_scope });
        const body = try p.stmt();

        return try p.addNode(.{
            .tag = .switch_stmt,
            .first = cond_node,
            .second = body,
        });
    }
    if (p.eatToken(.keyword_while)) |_| {
        const start_scopes_len = p.scopes.items.len;
        defer p.scopes.items.len = start_scopes_len;

        const l_paren = try p.expectToken(.l_paren);
        const cond = try p.expr();
        // TODO validate type
        try cond.expect(p);
        const cond_node = try cond.toNode(p);
        try p.expectClosing(l_paren, .r_paren);

        try p.scopes.append(.loop);
        const body = try p.stmt();

        return try p.addNode(.{
            .tag = .while_stmt,
            .first = cond_node,
            .second = body,
        });
    }
    if (p.eatToken(.keyword_do)) |_| {
        const start_scopes_len = p.scopes.items.len;
        defer p.scopes.items.len = start_scopes_len;

        try p.scopes.append(.loop);
        const body = try p.stmt();
        p.scopes.items.len = start_scopes_len;

        _ = try p.expectToken(.keyword_while);
        const l_paren = try p.expectToken(.l_paren);
        const cond = try p.expr();
        // TODO validate type
        try cond.expect(p);
        const cond_node = try cond.toNode(p);
        try p.expectClosing(l_paren, .r_paren);

        _ = try p.expectToken(.semicolon);
        return try p.addNode(.{
            .tag = .do_while_stmt,
            .first = cond_node,
            .second = body,
        });
    }
    if (p.eatToken(.keyword_for)) |_| {
        const start_scopes_len = p.scopes.items.len;
        defer p.scopes.items.len = start_scopes_len;

        var decls = NodeList.init(p.pp.comp.gpa);
        defer decls.deinit();

        const saved_decls = p.cur_decl_list;
        defer p.cur_decl_list = saved_decls;
        p.cur_decl_list = &decls;

        const l_paren = try p.expectToken(.l_paren);
        const got_decl = try p.decl();

        // for (init
        const init_start = p.tok_i;
        const init = if (!got_decl) try p.expr() else Result{ .none = {} };
        const init_node = try init.toNode(p);
        try p.maybeWarnUnused(init_node, init_start);
        if (!got_decl) _ = try p.expectToken(.semicolon);

        // for (init; cond
        const cond = try p.expr();
        const cond_node = try cond.toNode(p);
        _ = try p.expectToken(.semicolon);

        // for (init; cond; incr
        const incr_start = p.tok_i;
        const incr = try p.expr();
        const incr_node = try incr.toNode(p);
        try p.maybeWarnUnused(incr_node, incr_start);
        try p.expectClosing(l_paren, .r_paren);

        try p.scopes.append(.loop);
        const body = try p.stmt();

        if (got_decl) {
            const start = (try p.addList(decls.items)).start;
            const end = (try p.addList(&.{ cond_node, incr_node, body })).end;

            return try p.addNode(.{
                .tag = .for_decl_stmt,
                .first = start,
                .second = end,
            });
        } else if (init == .none and cond == .none and incr == .none) {
            return try p.addNode(.{
                .tag = .forever_stmt,
                .first = body,
            });
        } else {
            const range = try p.addList(&.{ init_node, cond_node, incr_node });
            return try p.addNode(.{
                .tag = .for_stmt,
                .first = range.start,
                .second = body,
            });
        }
    }
    if (p.eatToken(.keyword_goto)) |goto| {
        const name_tok = try p.expectToken(.identifier);
        const str = p.pp.tokSlice(p.tokens[name_tok]);
        if (p.findLabel(str) == null) {
            try p.labels.append(.{ .unresolved_goto = name_tok });
        }
        _ = try p.expectToken(.semicolon);
        return try p.addNode(.{
            .tag = .goto_stmt,
            .first = name_tok,
        });
    }
    if (p.eatToken(.keyword_continue)) |cont| {
        if (!p.inLoop()) try p.errTok(.continue_not_in_loop, cont);
        _ = try p.expectToken(.semicolon);
        return try p.addNode(.{ .tag = .continue_stmt });
    }
    if (p.eatToken(.keyword_break)) |br| {
        if (!p.inLoopOrSwitch()) try p.errTok(.break_not_in_loop_or_switch, br);
        _ = try p.expectToken(.semicolon);
        return try p.addNode(.{ .tag = .break_stmt });
    }
    if (p.eatToken(.keyword_return)) |_| {
        const e = try p.expr();
        _ = try p.expectToken(.semicolon);
        // TODO cast to return type
        const first = if (e == .none) 0 else try e.toNode(p);
        return try p.addNode(.{
            .tag = .return_stmt,
            .first = first,
        });
    }

    const expr_start = p.tok_i;
    const e = try p.expr();
    if (e != .none) {
        _ = try p.expectToken(.semicolon);
        const expr_node = try e.toNode(p);
        try p.maybeWarnUnused(expr_node, expr_start);
        return expr_node;
    }
    if (p.eatToken(.semicolon)) |_| return @as(NodeIndex, 0);

    try p.err(.expected_stmt);
    return error.ParsingFailed;
}

fn maybeWarnUnused(p: *Parser, node: NodeIndex, expr_start: TokenIndex) Error!void {
    switch (p.nodes.items(.tag)[node]) {
        .invalid, // So that we don't need to check for node == 0
        .assign_expr,
        .mul_assign_expr,
        .div_assign_expr,
        .mod_assign_expr,
        .add_assign_expr,
        .sub_assign_expr,
        .shl_assign_expr,
        .shr_assign_expr,
        .and_assign_expr,
        .xor_assign_expr,
        .or_assign_expr,
        .call_expr,
        .call_expr_one,
        => {},
        else => try p.errTok(.unused_value, expr_start),
    }
}

/// labeledStmt
/// : IDENTIFIER ':' stmt
/// | keyword_case constExpr ':' stmt
/// | keyword_default ':' stmt
fn labeledStmt(p: *Parser) Error!?NodeIndex {
    if (p.tokens[p.tok_i].id == .identifier and p.tokens[p.tok_i + 1].id == .colon) {
        const name_tok = p.tok_i;
        const str = p.pp.tokSlice(p.tokens[name_tok]);
        if (p.findLabel(str)) |some| {
            try p.errStr(.duplicate_label, name_tok, str);
            try p.errStr(.previous_label, some, str);
        } else {
            p.label_count += 1;
            try p.labels.append(.{ .label = name_tok });
            var i: usize = 0;
            while (i < p.labels.items.len) : (i += 1) {
                if (p.labels.items[i] == .unresolved_goto and
                    mem.eql(u8, p.pp.tokSlice(p.tokens[p.labels.items[i].unresolved_goto]), str))
                {
                    _ = p.labels.swapRemove(i);
                }
            }
        }

        p.tok_i += 2;
        return try p.addNode(.{
            .tag = .labeled_stmt,
            .first = name_tok,
            .second = try p.stmt(),
        });
    } else if (p.eatToken(.keyword_case)) |case| {
        const val = try p.constExpr();
        _ = try p.expectToken(.colon);
        const s = try p.stmt();
        const node = try p.addNode(.{
            .tag = .case_stmt,
            .first = try val.toNode(p),
            .second = s,
        });
        if (p.findSwitch()) |some| {
            const gop = try some.cases.getOrPut(val);
            if (gop.found_existing) {
                try p.errTok(.duplicate_switch_case, case);
                try p.errTok(.previous_case, gop.entry.value.tok);
            } else {
                gop.entry.value = .{
                    .tok = case,
                    .node = node,
                };
            }
        } else {
            try p.errStr(.case_not_in_switch, case, "case");
        }
        return node;
    } else if (p.eatToken(.keyword_default)) |default| {
        _ = try p.expectToken(.colon);
        const s = try p.stmt();
        const node = try p.addNode(.{
            .tag = .default_stmt,
            .first = s,
        });
        if (p.findSwitch()) |some| {
            if (some.default) |previous| {
                try p.errTok(.multiple_default, default);
                try p.errTok(.previous_case, previous.tok);
            } else {
                some.default = .{
                    .tok = default,
                    .node = node,
                };
            }
        } else {
            try p.errStr(.case_not_in_switch, default, "default");
        }
        return node;
    } else return null;
}

/// compoundStmt : '{' ( decl| staticAssert | stmt)* '}'
fn compoundStmt(p: *Parser) Error!?NodeIndex {
    const l_brace = p.eatToken(.l_brace) orelse return null;
    var statements = NodeList.init(p.pp.comp.gpa);
    defer statements.deinit();

    const saved_decls = p.cur_decl_list;
    defer p.cur_decl_list = saved_decls;
    p.cur_decl_list = &statements;

    var noreturn_index: ?TokenIndex = null;
    var noreturn_label_count: u32 = 0;

    while (p.eatToken(.r_brace) == null) {
        if (p.staticAssert() catch |er| switch (er) {
            error.ParsingFailed => {
                try p.nextStmt(l_brace);
                continue;
            },
            else => |e| return e,
        }) continue;
        if (p.decl() catch |er| switch (er) {
            error.ParsingFailed => {
                try p.nextStmt(l_brace);
                continue;
            },
            else => |e| return e,
        }) continue;
        const s = p.stmt() catch |er| switch (er) {
            error.ParsingFailed => {
                try p.nextStmt(l_brace);
                continue;
            },
            else => |e| return e,
        };
        if (s == 0) continue;
        try statements.append(s);

        if (noreturn_index == null and p.nodeIsNoreturn(s)) {
            noreturn_index = p.tok_i;
            noreturn_label_count = p.label_count;
        }
    }

    if (noreturn_index) |some| {
        // if new labels were defined we cannot be certain that the code is unreachable
        if (some != p.tok_i - 1 and noreturn_label_count == p.label_count) try p.errTok(.unreachable_code, some);
    }

    switch (statements.items.len) {
        0 => return try p.addNode(.{ .tag = .compound_stmt_two }),
        1 => return try p.addNode(.{
            .tag = .compound_stmt_two,
            .first = statements.items[0],
        }),
        2 => return try p.addNode(.{
            .tag = .compound_stmt_two,
            .first = statements.items[0],
            .second = statements.items[1],
        }),
        else => {
            const range = try p.addList(statements.items);
            return try p.addNode(.{
                .tag = .compound_stmt,
                .first = range.start,
                .second = range.end,
            });
        },
    }
}

fn nodeIsNoreturn(p: *Parser, node: NodeIndex) bool {
    switch (p.nodes.items(.tag)[node]) {
        .break_stmt, .continue_stmt, .return_stmt => return true,
        .if_then_else_stmt => {
            const data = p.data.items[p.nodes.items(.second)[node]..];
            return p.nodeIsNoreturn(data[0]) and p.nodeIsNoreturn(data[1]);
        },
        else => return false,
    }
}

fn nextStmt(p: *Parser, l_brace: TokenIndex) !void {
    var parens: u32 = 0;
    while (p.tok_i < p.tokens.len) : (p.tok_i += 1) {
        switch (p.tokens[p.tok_i].id) {
            .l_paren, .l_brace, .l_bracket => parens += 1,
            .r_paren, .r_bracket => if (parens != 0) {
                parens -= 1;
            },
            .r_brace => if (parens == 0)
                return
            else {
                parens -= 1;
            },
            .keyword_for,
            .keyword_while,
            .keyword_do,
            .keyword_if,
            .keyword_goto,
            .keyword_switch,
            .keyword_case,
            .keyword_default,
            .keyword_continue,
            .keyword_break,
            .keyword_return,
            .keyword_typedef,
            .keyword_extern,
            .keyword_static,
            .keyword_auto,
            .keyword_register,
            .keyword_thread_local,
            .keyword_inline,
            .keyword_noreturn,
            .keyword_void,
            .keyword_bool,
            .keyword_char,
            .keyword_short,
            .keyword_int,
            .keyword_long,
            .keyword_signed,
            .keyword_unsigned,
            .keyword_float,
            .keyword_double,
            .keyword_complex,
            .keyword_atomic,
            .keyword_enum,
            .keyword_struct,
            .keyword_union,
            .keyword_alignas,
            => if (parens == 0) return,
            else => {},
        }
    }
    p.tok_i -= 1; // So we can consume EOF
    try p.expectClosing(l_brace, .r_brace);
    unreachable;
}

// ====== expressions ======

/// expr : assignExpr (',' assignExpr)*
fn expr(p: *Parser) Error!Result {
    var lhs = try p.assignExpr();
    while (p.eatToken(.comma)) |op| {
        return p.todo("comma operator");
    }
    return lhs;
}

/// assignExpr
///  : condExpr
///  | unExpr ('=' | '*=' | '/=' | '%=' | '+=' | '-=' | '<<=' | '>>=' | '&=' | '^=' | '|=') assignExpr
fn assignExpr(p: *Parser) Error!Result {
    return p.condExpr(); // TODO
}

/// constExpr : condExpr
pub fn constExpr(p: *Parser) Error!Result {
    const saved_const = p.want_const;
    defer p.want_const = saved_const;
    p.want_const = true;
    const res = try p.condExpr();
    try res.expect(p);
    return res;
}

/// condExpr : lorExpr ('?' expression? ':' condExpr)?
fn condExpr(p: *Parser) Error!Result {
    const cond = try p.lorExpr();
    if (p.eatToken(.question_mark) == null) return cond;
    const then_expr = try p.expr();
    _ = try p.expectToken(.colon);
    const else_expr = try p.condExpr();

    if (p.want_const or cond != .node) {
        return if (cond.getBool()) then_expr else else_expr;
    }
    return p.todo("ast");
}

/// lorExpr : landExpr ('||' landExpr)*
fn lorExpr(p: *Parser) Error!Result {
    var lhs = try p.landExpr();
    while (p.eatToken(.pipe_pipe)) |_| {
        const rhs = try p.landExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            lhs = Result{ .i32 = @boolToInt(lhs.getBool() or rhs.getBool()) }; // TODO result has int type
        } else return p.todo("ast");
    }
    return lhs;
}

/// landExpr : orExpr ('&&' orExpr)*
fn landExpr(p: *Parser) Error!Result {
    var lhs = try p.orExpr();
    while (p.eatToken(.ampersand_ampersand)) |_| {
        const rhs = try p.orExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            lhs = Result{ .i32 = @boolToInt(lhs.getBool() and rhs.getBool()) }; // TODO result has int type
        } else return p.todo("ast");
    }
    return lhs;
}

/// orExpr : xorExpr ('|' xorExpr)*
fn orExpr(p: *Parser) Error!Result {
    var lhs = try p.xorExpr();
    while (p.eatToken(.pipe)) |_| {
        const rhs = try p.xorExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("or constExpr");
        } else return p.todo("ast");
    }
    return lhs;
}

/// xorExpr : andExpr ('^' andExpr)*
fn xorExpr(p: *Parser) Error!Result {
    var lhs = try p.andExpr();
    while (p.eatToken(.caret)) |_| {
        const rhs = try p.andExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("xor constExpr");
        } else return p.todo("ast");
    }
    return lhs;
}

/// andExpr : eqExpr ('&' eqExpr)*
fn andExpr(p: *Parser) Error!Result {
    var lhs = try p.eqExpr();
    while (p.eatToken(.ampersand)) |_| {
        const rhs = try p.eqExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("and constExpr");
        } else return p.todo("ast");
    }
    return lhs;
}

/// eqExpr : compExpr (('==' | '!=') compExpr)*
fn eqExpr(p: *Parser) Error!Result {
    var lhs = try p.compExpr();
    while (true) {
        const eq = p.eatToken(.equal_equal);
        const ne = eq orelse p.eatToken(.bang_equal);
        if (ne == null) break;
        const rhs = try p.compExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("equality constExpr");
        }
        return p.todo("ast");
    }
    return lhs;
}

/// compExpr : shiftExpr (('<' | '<=' | '>' | '>=') shiftExpr)*
fn compExpr(p: *Parser) Error!Result {
    const lhs = try p.shiftExpr();
    while (true) {
        const lt = p.eatToken(.angle_bracket_left);
        const le = lt orelse p.eatToken(.angle_bracket_left_equal);
        const gt = le orelse p.eatToken(.angle_bracket_right);
        const ge = gt orelse p.eatToken(.angle_bracket_right_equal);
        if (ge == null) break;
        const rhs = try p.shiftExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("comp constExpr");
        }
        return p.todo("ast");
    }
    return lhs;
}

/// shiftExpr : addExpr (('<<' | '>>') addExpr)*
fn shiftExpr(p: *Parser) Error!Result {
    const lhs = try p.addExpr();
    while (true) {
        const shl = p.eatToken(.angle_bracket_angle_bracket_left);
        const shr = shl orelse p.eatToken(.angle_bracket_angle_bracket_right);
        if (shr == null) break;
        const rhs = try p.addExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("shift constExpr");
        }
        return p.todo("ast");
    }
    return lhs;
}

/// addExpr : mulExpr (('+' | '-') mulExpr)*
fn addExpr(p: *Parser) Error!Result {
    const lhs = try p.mulExpr();
    while (true) {
        const plus = p.eatToken(.plus);
        const minus = plus orelse p.eatToken(.minus);
        if (minus == null) break;
        const rhs = try p.mulExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("shift constExpr");
        }
        return p.todo("ast");
    }
    return lhs;
}

/// mulExpr : castExpr (('*' | '/' | '%') castExpr)*´
fn mulExpr(p: *Parser) Error!Result {
    const lhs = try p.castExpr();
    while (true) {
        const mul = p.eatToken(.plus);
        const div = mul orelse p.eatToken(.slash);
        const percent = div orelse p.eatToken(.percent);
        if (percent == null) break;
        const rhs = try p.castExpr();

        if (p.want_const or (lhs != .node and rhs != .node)) {
            return p.todo("mul constExpr");
        }
        return p.todo("ast");
    }
    return lhs;
}

/// castExpr :  ( '(' typeName ')' )* unExpr
fn castExpr(p: *Parser) Error!Result {
    while (p.eatToken(.l_paren)) |l_paren| {
        const ty = (try p.typeName()) orelse {
            p.tok_i -= 1;
            break;
        };
        try p.expectClosing(l_paren, .r_paren);
        return p.todo("cast");
    }
    return p.unExpr();
}

/// unExpr
///  : primaryExpr suffixExpr*
///  | ('&' | '*' | '+' | '-' | '~' | '!' | '++' | '--') castExpr
///  | keyword_sizeof unExpr
///  | keyword_sizeof '(' typeName ')'
///  | keyword_alignof '(' typeName ')'
fn unExpr(p: *Parser) Error!Result {
    switch (p.tokens[p.tok_i].id) {
        .ampersand => return p.todo("unExpr ampersand"),
        .asterisk => return p.todo("unExpr asterisk"),
        .plus => return p.todo("unExpr plus"),
        .minus => return p.todo("unExpr minus"),
        .plus_plus => return p.todo("unary inc"),
        .minus_minus => return p.todo("unary dec"),
        .tilde => return p.todo("unExpr tilde"),
        .bang => {
            p.tok_i += 1;
            const lhs = try p.unExpr();
            if (p.want_const or lhs != .node) {
                return Result{ .bool = !lhs.getBool() };
            }
            return p.todo("ast");
        },
        .keyword_sizeof => return p.todo("unExpr sizeof"),
        else => {
            var lhs = try p.primaryExpr();
            while (true) {
                const suffix = try p.suffixExpr(lhs);
                if (suffix == .none) break;
                lhs = suffix;
            }
            return lhs;
        },
    }
}

/// suffixExpr
///  : '[' expr ']'
///  | '(' argumentExprList? ')'
///  | '.' IDENTIFIER
///  | '->' IDENTIFIER
///  | '++'
///  | '--'
/// argumentExprList : assignExpr (',' assignExpr)*
fn suffixExpr(p: *Parser, lhs: Result) Error!Result {
    switch (p.tokens[p.tok_i].id) {
        .l_paren => {
            const l_paren = p.tok_i;
            p.tok_i += 1;
            const lhs_ty = lhs.ty(p);
            const ty = lhs_ty.isCallable() orelse {
                try p.errStr(.not_callable, l_paren, Type.Builder.fromType(lhs_ty).str());
                return error.ParsingFailed;
            };
            const param_types = ty.data.func.param_types;

            var args = NodeList.init(p.pp.comp.gpa);
            defer args.deinit();

            var first_after = l_paren;
            if (p.eatToken(.r_paren) == null) {
                while (true) {
                    if (args.items.len == param_types.len) first_after = p.tok_i;
                    const arg = try p.assignExpr();
                    try arg.expect(p);

                    if (args.items.len < param_types.len) {
                        const param_ty = p.nodes.items(.ty)[param_types[args.items.len]];
                        const casted = try arg.coerce(p, param_ty);
                        try args.append(try casted.toNode(p));
                    } else {
                        // TODO coerce to var args passable type
                        try args.append(try arg.toNode(p));
                    }

                    _ = p.eatToken(.comma) orelse break;
                }
                try p.expectClosing(l_paren, .r_paren);
            }

            const extra = Diagnostics.Message.Extra{ .arguments = .{ .expected = @intCast(u32, param_types.len), .actual = @intCast(u32, args.items.len) } };
            if (ty.specifier == .func and param_types.len != args.items.len) {
                try p.errExtra(.expected_arguments, first_after, extra);
            }
            if (ty.specifier == .old_style_func and param_types.len != args.items.len) {
                try p.errExtra(.expected_arguments_old, first_after, extra);
            }
            if (ty.specifier == .var_args_func and args.items.len < param_types.len) {
                try p.errExtra(.expected_at_least_arguments, first_after, extra);
            }

            switch (args.items.len) {
                0 => return try Result.node(p, .{
                    .tag = .call_expr_one,
                    .ty = ty.data.func.return_type,
                    .first = try lhs.toNode(p),
                }),
                1 => return try Result.node(p, .{
                    .tag = .call_expr_one,
                    .ty = ty.data.func.return_type,
                    .first = try lhs.toNode(p),
                    .second = args.items[0],
                }),
                else => {
                    try p.data.append(try lhs.toNode(p));
                    const range = try p.addList(args.items);
                    return try Result.node(p, .{
                        .tag = .call_expr,
                        .ty = ty.data.func.return_type,
                        .first = range.start - 1,
                        .second = range.end,
                    });
                },
            }
        },
        .l_bracket => return p.todo("array access"),
        .period => return p.todo("member access"),
        .arrow => return p.todo("member access pointer"),
        .plus_plus => return p.todo("post inc"),
        .minus_minus => return p.todo("post dec"),
        else => return Result.none,
    }
}

/// primaryExpr
///  : IDENTIFIER
///  | INTEGER_LITERAL
///  | FLOAT_LITERAL
///  | CHAR_LITERAL
///  | STRING_LITERAL
///  | '(' expr ')'
///  | '(' typeName ')' '{' initializerItems '}'
///  | keyword_generic '(' assignExpr ',' genericAssoc (',' genericAssoc)* ')'
///
/// genericAssoc
///  : typeName ':' assignExpr
///  | keyword_default ':' assignExpr
fn primaryExpr(p: *Parser) Error!Result {
    if (p.eatToken(.l_paren)) |l_paren| {
        const e = try p.expr();
        try p.expectClosing(l_paren, .r_paren);
        return e;
    }
    switch (p.tokens[p.tok_i].id) {
        .identifier => {
            const name_tok = p.tok_i;
            p.tok_i += 1;
            const sym = p.findSymbol(name_tok) orelse {
                if (p.tokens[p.tok_i].id == .l_paren) {
                    // implicitly declare simple functions as like `puts("foo")`;
                    const name = p.pp.tokSlice(p.tokens[name_tok]);
                    try p.errStr(.implicit_func_decl, name_tok, name);

                    const func_ty = try p.arena.create(Type.Func);
                    func_ty.* = .{ .return_type = .{ .specifier = .int }, .param_types = &.{} };
                    const ty: Type = .{ .specifier = .old_style_func, .data = .{ .func = func_ty } };
                    const node = try p.addNode(.{
                        .ty = ty,
                        .tag = .fn_proto,
                        .first = name_tok,
                    });

                    try p.cur_decl_list.append(node);
                    try p.scopes.append(.{ .symbol = .{
                        .name = name,
                        .node = node,
                        .name_tok = name_tok,
                    } });

                    return try Result.lval(p, .{
                        .tag = .decl_ref_expr,
                        .ty = ty,
                        .first = name_tok,
                        .second = node,
                    });
                }
                try p.errTok(.undeclared_identifier, name_tok);
                return error.ParsingFailed;
            };
            switch (sym) {
                .enumeration => |e| return e.value,
                .symbol => |s| {
                    // TODO actually check type
                    if (p.want_const) {
                        try p.err(.expected_integer_constant_expr);
                        return error.ParsingFailed;
                    }

                    return try Result.lval(p, .{
                        .tag = .decl_ref_expr,
                        .ty = p.nodes.items(.ty)[s.node],
                        .first = name_tok,
                        .second = s.node,
                    });
                },
                else => unreachable,
            }
        },
        .string_literal,
        .string_literal_utf_16,
        .string_literal_utf_8,
        .string_literal_utf_32,
        .string_literal_wide,
        => {
            if (p.want_const) {
                try p.err(.expected_integer_constant_expr);
                return error.ParsingFailed;
            }
            const start = p.tok_i;
            // use 1 for wchar_t
            var width: ?u8 = null;
            while (true) {
                switch (p.tokens[p.tok_i].id) {
                    .string_literal => {},
                    .string_literal_utf_16 => if (width) |some| {
                        if (some != 16) try p.err(.unsupported_str_cat);
                    } else {
                        width = 16;
                    },
                    .string_literal_utf_8 => if (width) |some| {
                        if (some != 8) try p.err(.unsupported_str_cat);
                    } else {
                        width = 8;
                    },
                    .string_literal_utf_32 => if (width) |some| {
                        if (some != 32) try p.err(.unsupported_str_cat);
                    } else {
                        width = 32;
                    },
                    .string_literal_wide => if (width) |some| {
                        if (some != 1) try p.err(.unsupported_str_cat);
                    } else {
                        width = 1;
                    },
                    else => break,
                }
                p.tok_i += 1;
            }
            if (width == null) width = 8;
            if (width.? != 8) return p.todo("non-utf8 strings");
            var builder = std.ArrayList(u8).init(p.pp.comp.gpa);
            defer builder.deinit();
            for (p.tokens[start..p.tok_i]) |tok| {
                var slice = p.pp.tokSlice(tok);
                slice = slice[mem.indexOf(u8, slice, "\"").? + 1 .. slice.len - 1];
                var i: u32 = 0;
                try builder.ensureCapacity(slice.len);
                while (i < slice.len) : (i += 1) {
                    switch (slice[i]) {
                        '\\' => {
                            i += 1;
                            switch (slice[i]) {
                                '\n' => i += 1,
                                '\r' => i += 2,
                                '\'', '\"', '\\', '?' => |c| builder.appendAssumeCapacity(c),
                                'n' => builder.appendAssumeCapacity('\n'),
                                'r' => builder.appendAssumeCapacity('\r'),
                                't' => builder.appendAssumeCapacity('\t'),
                                'a' => builder.appendAssumeCapacity(0x07),
                                'b' => builder.appendAssumeCapacity(0x08),
                                'e' => builder.appendAssumeCapacity(0x1B),
                                'f' => builder.appendAssumeCapacity(0x0C),
                                'v' => builder.appendAssumeCapacity(0x0B),
                                'x' => return p.todo("hex escape"),
                                'u' => return p.todo("u escape"),
                                'U' => return p.todo("U escape"),
                                '0'...'7' => return p.todo("octal escape"),
                                else => unreachable,
                            }
                        },
                        else => |c| builder.appendAssumeCapacity(c),
                    }
                }
            }
            try builder.append(0);
            const str = try p.arena.dupe(u8, builder.items);
            const ptr_loc = @intCast(u32, p.data.items.len);
            try p.data.appendSlice(&@bitCast([2]u32, @ptrToInt(str.ptr)));

            const arr_ty = try p.arena.create(Type.Array);
            arr_ty.* = .{ .elem = .{ .specifier = .char }, .len = str.len };
            return try Result.node(p, .{
                .tag = .string_literal_expr,
                .ty = .{
                    .specifier = .array,
                    .data = .{ .array = arr_ty },
                },
                .first = ptr_loc,
                .second = @intCast(u32, str.len),
            });
        },
        .char_literal,
        .char_literal_utf_16,
        .char_literal_utf_32,
        .char_literal_wide,
        => {
            if (p.want_const) {
                return p.todo("char literals");
            }
            return p.todo("ast");
        },
        .float_literal,
        .float_literal_f,
        .float_literal_l,
        => {
            if (p.want_const) {
                try p.err(.expected_integer_constant_expr);
                return error.ParsingFailed;
            }
            return p.todo("ast");
        },
        .zero => {
            p.tok_i += 1;
            return Result{ .i32 = 0 }; // TODO int type
        },
        .one => {
            p.tok_i += 1;
            return Result{ .i32 = 1 }; // TODO int type
        },
        .integer_literal,
        .integer_literal_u,
        .integer_literal_l,
        .integer_literal_lu,
        .integer_literal_ll,
        .integer_literal_llu,
        => {
            const tok = p.tokens[p.tok_i];
            var slice = p.pp.tokSlice(tok);
            p.tok_i += 1;
            var base: u8 = 10;
            if (mem.startsWith(u8, slice, "0x")) {
                slice = slice[2..];
                base = 10;
            } else if (slice[0] == '0') {
                base = 8;
            }
            switch (tok.id) {
                .integer_literal_u, .integer_literal_l => slice = slice[0 .. slice.len - 1],
                .integer_literal_lu, .integer_literal_ll => slice = slice[0 .. slice.len - 2],
                .integer_literal_llu => slice = slice[0 .. slice.len - 3],
                else => {},
            }

            if (base == 10) {
                switch (tok.id) {
                    .integer_literal => return p.parseInt(base, slice, &.{ .int, .long, .long_long }),
                    .integer_literal_u => return p.parseInt(base, slice, &.{ .uint, .ulong, .ulong_long }),
                    .integer_literal_l => return p.parseInt(base, slice, &.{ .long, .long_long }),
                    .integer_literal_lu => return p.parseInt(base, slice, &.{ .ulong, .ulong_long }),
                    .integer_literal_ll => return p.parseInt(base, slice, &.{.long_long}),
                    .integer_literal_llu => return p.parseInt(base, slice, &.{.ulong_long}),
                    else => unreachable,
                }
            } else {
                switch (tok.id) {
                    .integer_literal => return p.parseInt(base, slice, &.{ .int, .uint, .long, .ulong, .long_long, .ulong_long }),
                    .integer_literal_u => return p.parseInt(base, slice, &.{ .uint, .ulong, .ulong_long }),
                    .integer_literal_l => return p.parseInt(base, slice, &.{ .long, .ulong, .long_long, .ulong_long }),
                    .integer_literal_lu => return p.parseInt(base, slice, &.{ .ulong, .ulong_long }),
                    .integer_literal_ll => return p.parseInt(base, slice, &.{ .long_long, .ulong_long }),
                    .integer_literal_llu => return p.parseInt(base, slice, &.{.ulong_long}),
                    else => unreachable,
                }
            }
        },
        .keyword_generic => {
            return p.todo("generic");
        },
        else => return Result{ .none = {} },
    }
}

fn parseInt(p: *Parser, base: u8, slice: []const u8, specs: []const Type.Specifier) Error!Result {
    const wrappedParse = struct {
        fn func(comptime T: type, b: u8, s: []const u8) ?T {
            return std.fmt.parseInt(T, s, b) catch return null;
        }
    }.func;

    for (specs) |spec| {
        const ty = Type{ .specifier = spec };
        const unsigned = ty.isUnsignedInt(p.pp.comp);
        const size = ty.sizeof(p.pp.comp);

        if (unsigned) {
            switch (size) {
                2 => if (wrappedParse(u16, base, slice)) |r| return Result{ .u16 = r },
                4 => if (wrappedParse(u32, base, slice)) |r| return Result{ .u32 = r },
                8 => if (wrappedParse(u64, base, slice)) |r| return Result{ .u64 = r },
                else => unreachable,
            }
        } else {
            switch (size) {
                2 => if (wrappedParse(i8, base, slice)) |r| return Result{ .i16 = r },
                4 => if (wrappedParse(i32, base, slice)) |r| return Result{ .i32 = r },
                8 => if (wrappedParse(i64, base, slice)) |r| return Result{ .i64 = r },
                else => unreachable,
            }
        }
    }
    return p.todo("huge integer constants");
}
