const std = @import("std");
const root = @import("addon_root");
const napi = @import("napi");
const StringBuilder = std.array_list.Managed(u8);

fn shortTypeName(comptime T: type) []const u8 {
    var iter = std.mem.splitBackwardsScalar(u8, @typeName(T), '.');
    return iter.first();
}

fn append(writer: *StringBuilder, text: []const u8) !void {
    try writer.appendSlice(text);
}

fn appendFmt(writer: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(writer.allocator, fmt, args);
    defer writer.allocator.free(text);
    try writer.appendSlice(text);
}

fn appendLine(writer: *StringBuilder, text: []const u8) !void {
    try append(writer, text);
    try append(writer, "\n");
}

fn isNumeric(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

fn isStringLike(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .array => |arr| arr.child == u8 or arr.child == u16,
            .int => |int| int.bits == 8 or int.bits == 16,
            else => false,
        },
        .array => |arr| arr.child == u8 or arr.child == u16,
        else => false,
    };
}

fn isTuple(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".is_tuple;
}

fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

fn isTypedArrayType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_typedarray");
}

fn isClassType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "WrappedType") and @typeInfo(T) == .@"struct";
}

fn isPromiseType(comptime T: type) bool {
    return T == napi.Promise;
}

fn typedArrayName(comptime T: type) ?[]const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return null,
    }
    if (!@hasDecl(T, "is_napi_typedarray")) return null;
    return switch (T.element_type) {
        i8 => "Int8Array",
        u8 => "Uint8Array",
        i16 => "Int16Array",
        u16 => "Uint16Array",
        i32 => "Int32Array",
        u32 => "Uint32Array",
        f32 => "Float32Array",
        f64 => "Float64Array",
        i64 => "BigInt64Array",
        u64 => "BigUint64Array",
        else => null,
    };
}

fn tsArgName(comptime idx: usize, comptime total: usize) []const u8 {
    if (total == 1) return "arg";
    return std.fmt.comptimePrint("arg{d}", .{idx});
}

fn resolvedArgName(param_names: ?[]const []const u8, comptime idx: usize, comptime total: usize) []const u8 {
    if (param_names) |names| {
        if (idx < names.len) return names[idx];
    }
    return tsArgName(idx, total);
}

fn isFunctionType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "inner_fn")) return true;
    }
    return false;
}

fn isThreadsafeFunctionType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "tsfn_raw")) return true;
    }
    return false;
}

fn isReferenceType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_reference");
}

fn isDataViewType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    return @hasDecl(T, "is_napi_dataview");
}

fn isStringEnumType(comptime T: type) bool {
    if (@typeInfo(T) != .@"enum") return false;
    return @hasDecl(T, "napi_string_enum") and @TypeOf(@field(T, "napi_string_enum")) == bool and @field(T, "napi_string_enum");
}

fn isArrayList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    var has_items = false;
    var has_capacity = false;
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) has_items = true;
        if (std.mem.eql(u8, field.name, "capacity")) has_capacity = true;
    }
    return has_items and has_capacity;
}

fn arrayListElementType(comptime T: type) type {
    const info = @typeInfo(T);
    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) {
            const items_info = @typeInfo(field.type);
            if (items_info == .pointer and items_info.pointer.size == .slice) {
                return items_info.pointer.child;
            }
        }
    }
    @compileError("Could not extract element type from ArrayList: " ++ @typeName(T));
}

fn isObjectLikeStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (isTuple(T)) return false;
    if (isArrayList(T)) return false;
    if (isFunctionType(T)) return false;
    if (isThreadsafeFunctionType(T)) return false;
    if (isTypedArrayType(T)) return false;
    if (isDataViewType(T)) return false;
    if (isReferenceType(T)) return false;
    if (isClassType(T)) return false;
    return true;
}

const State = struct {
    allocator: std.mem.Allocator,
    declarations: StringBuilder,
    exports: StringBuilder,
    emitted: std.StringHashMap(void),
    exported: std.StringHashMap(void),
    source: *SourceResolver,

    fn init(allocator: std.mem.Allocator, source: *SourceResolver) State {
        return .{
            .allocator = allocator,
            .declarations = StringBuilder.init(allocator),
            .exports = StringBuilder.init(allocator),
            .emitted = std.StringHashMap(void).init(allocator),
            .exported = std.StringHashMap(void).init(allocator),
            .source = source,
        };
    }

    fn deinit(self: *State) void {
        self.declarations.deinit();
        self.exports.deinit();
        self.emitted.deinit();
        self.exported.deinit();
    }
};

const FunctionSource = struct {
    file_path: []const u8,
    fn_name: []const u8,
};

const ClassSource = struct {
    file_path: []const u8,
    wrapped_type: []const u8,
};

const ResolvedSymbol = union(enum) {
    function: FunctionSource,
    class: ClassSource,
    unresolved,
};

const InitExport = struct {
    name: []const u8,
    declaration: []const u8,
};

const InitExportSpec = struct {
    name: []const u8,
    value_expr: []const u8,
    file_path: []const u8,
    init_body: []const u8,
};

const SourceParam = struct {
    name: []const u8,
    type_expr: []const u8,
};

const SourceFunctionSignature = struct {
    params: []const SourceParam,
    return_type_expr: []const u8,
};

const ParsedTextList = struct {
    items: []const []const u8,
    end_index: usize,
};

const ParsedSourceParams = struct {
    items: []const SourceParam,
    end_index: usize,
};

const SourceResolver = struct {
    allocator: std.mem.Allocator,
    root_source_path: []const u8,

    fn init(allocator: std.mem.Allocator, root_source_path: []const u8) SourceResolver {
        return .{
            .allocator = allocator,
            .root_source_path = root_source_path,
        };
    }

    fn getExportFunctionParamNames(self: *SourceResolver, export_name: []const u8) !?[]const []const u8 {
        return switch (try self.resolveSymbol(self.root_source_path, export_name, 0)) {
            .function => |function_source| try self.findFnParamNamesInFile(function_source.file_path, function_source.fn_name, true),
            else => null,
        };
    }

    fn getReturnedFunctionParamNames(self: *SourceResolver, export_name: []const u8) !?[]const []const u8 {
        return switch (try self.resolveSymbol(self.root_source_path, export_name, 0)) {
            .function => |function_source| try self.findReturnedFunctionParamNames(function_source.file_path, function_source.fn_name),
            else => null,
        };
    }

    fn getClassConstructorParamNames(self: *SourceResolver, export_name: []const u8) !?[]const []const u8 {
        return switch (try self.resolveSymbol(self.root_source_path, export_name, 0)) {
            .class => |class_source| try self.findStructMethodParamNames(class_source.file_path, class_source.wrapped_type, "init"),
            else => null,
        };
    }

    fn getClassMethodParamNames(self: *SourceResolver, export_name: []const u8, method_name: []const u8) !?[]const []const u8 {
        return switch (try self.resolveSymbol(self.root_source_path, export_name, 0)) {
            .class => |class_source| try self.findStructMethodParamNames(class_source.file_path, class_source.wrapped_type, method_name),
            else => null,
        };
    }

    fn resolveSymbol(self: *SourceResolver, file_path: []const u8, symbol: []const u8, depth: usize) !ResolvedSymbol {
        if (depth > 8) return .unresolved;

        const content = try self.readFile(file_path);
        if (try self.findFnParamNamesInContent(content, symbol, true)) |_| {
            return .{ .function = .{ .file_path = file_path, .fn_name = try self.allocator.dupe(u8, symbol) } };
        }

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = trimLine(line);
            const rhs = matchConstAssignment(trimmed, symbol) orelse continue;

            if (matchClassAssignment(rhs)) |wrapped_type| {
                return .{
                    .class = .{
                        .file_path = file_path,
                        .wrapped_type = try self.allocator.dupe(u8, wrapped_type),
                    },
                };
            }

            if (parseAliasRef(rhs)) |alias_ref| {
                if (try self.resolveImportPath(file_path, alias_ref.left)) |import_path| {
                    return try self.resolveSymbol(import_path, alias_ref.right, depth + 1);
                }

                return try self.resolveSymbol(file_path, alias_ref.right, depth + 1);
            }
        }

        return .unresolved;
    }

    fn findStructMethodParamNames(self: *SourceResolver, file_path: []const u8, struct_name: []const u8, method_name: []const u8) !?[]const []const u8 {
        const content = try self.readFile(file_path);
        const body = findStructBody(content, struct_name) orelse return null;
        return try self.findFnParamNamesInContent(body, method_name, false);
    }

    fn findFnParamNamesInFile(self: *SourceResolver, file_path: []const u8, fn_name: []const u8, require_pub: bool) !?[]const []const u8 {
        const content = try self.readFile(file_path);
        return try self.findFnParamNamesInContent(content, fn_name, require_pub);
    }

    fn findReturnedFunctionParamNames(self: *SourceResolver, file_path: []const u8, fn_name: []const u8) !?[]const []const u8 {
        const content = try self.readFile(file_path);
        const body = findFunctionBody(content, fn_name, true) orelse return null;
        const target = findReturnedFunctionTarget(body) orelse return null;
        return switch (try self.resolveSymbol(file_path, target, 0)) {
            .function => |function_source| try self.findFnParamNamesInFile(function_source.file_path, function_source.fn_name, true),
            else => null,
        };
    }

    fn findSourceFunctionSignature(self: *SourceResolver, file_path: []const u8, fn_name: []const u8, require_pub: bool) !?SourceFunctionSignature {
        const content = try self.readFile(file_path);
        const lparen_index = findFunctionStart(content, fn_name, require_pub) orelse return null;
        return try self.parseSourceFunctionSignature(content, lparen_index);
    }

    fn findConstAssignmentInFile(self: *SourceResolver, file_path: []const u8, symbol: []const u8) !?[]const u8 {
        const content = try self.readFile(file_path);
        return findConstAssignmentInContent(content, symbol);
    }

    fn collectInitExportSpecs(self: *SourceResolver) ![]const InitExportSpec {
        const content = try self.readFile(self.root_source_path);
        const init_name = try self.findInitFunctionName(content) orelse return &[_]InitExportSpec{};
        const init_body = findFunctionBody(content, init_name, false) orelse return &[_]InitExportSpec{};

        var specs = std.array_list.Managed(InitExportSpec).init(self.allocator);
        errdefer specs.deinit();

        var iter = std.mem.splitScalar(u8, init_body, '\n');
        while (iter.next()) |line| {
            const trimmed = trimLine(line);
            const set_call = matchObjectSetCall(trimmed, "exports") orelse continue;
            try specs.append(.{
                .name = try self.allocator.dupe(u8, set_call.name),
                .value_expr = try self.allocator.dupe(u8, set_call.value_expr),
                .file_path = self.root_source_path,
                .init_body = init_body,
            });
        }

        return try specs.toOwnedSlice();
    }

    fn findInitFunctionName(self: *SourceResolver, content: []const u8) !?[]const u8 {
        const marker = "NODE_API_MODULE_WITH_INIT(";
        const marker_index = std.mem.indexOf(u8, content, marker) orelse return null;
        const args = try parseCallArguments(self.allocator, content, marker_index + marker.len - 1);
        if (args.items.len < 3) return null;

        const init_expr = std.mem.trim(u8, args.items[2], " \t\r\n");
        if (init_expr.len == 0 or std.mem.eql(u8, init_expr, "null")) return null;
        return try self.allocator.dupe(u8, init_expr);
    }

    fn findFnParamNamesInContent(self: *SourceResolver, content: []const u8, fn_name: []const u8, require_pub: bool) !?[]const []const u8 {
        const pub_pattern = try std.fmt.allocPrint(self.allocator, "pub fn {s}(", .{fn_name});
        const any_pattern = try std.fmt.allocPrint(self.allocator, "fn {s}(", .{fn_name});

        if (std.mem.indexOf(u8, content, pub_pattern)) |start| {
            return try self.parseParamNames(content, start + pub_pattern.len - 1);
        }
        if (!require_pub) {
            if (std.mem.indexOf(u8, content, any_pattern)) |start| {
                return try self.parseParamNames(content, start + any_pattern.len - 1);
            }
        }
        return null;
    }

    fn parseParamNames(self: *SourceResolver, content: []const u8, lparen_index: usize) ![]const []const u8 {
        var depth_paren: usize = 0;
        var depth_brace: usize = 0;
        var depth_bracket: usize = 0;
        var start = lparen_index + 1;
        var i = lparen_index + 1;
        var names = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer names.deinit();

        while (i < content.len) : (i += 1) {
            const ch = content[i];
            switch (ch) {
                '(' => depth_paren += 1,
                ')' => {
                    if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                        try self.appendParamName(&names, content[start..i]);
                        return try names.toOwnedSlice();
                    }
                    depth_paren -= 1;
                },
                '{' => depth_brace += 1,
                '}' => depth_brace -= 1,
                '[' => depth_bracket += 1,
                ']' => depth_bracket -= 1,
                ',' => {
                    if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                        try self.appendParamName(&names, content[start..i]);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }

        return try names.toOwnedSlice();
    }

    fn parseSourceFunctionSignature(self: *SourceResolver, content: []const u8, lparen_index: usize) !SourceFunctionSignature {
        const params = try self.parseSourceParams(content, lparen_index);

        var body_index = params.end_index + 1;
        while (body_index < content.len and content[body_index] != '{') : (body_index += 1) {}

        const raw_return_type = if (body_index <= content.len)
            std.mem.trim(u8, content[params.end_index + 1 .. @min(body_index, content.len)], " \t\r\n")
        else
            "";

        return .{
            .params = params.items,
            .return_type_expr = stripFunctionQualifiers(raw_return_type),
        };
    }

    fn parseSourceParams(self: *SourceResolver, content: []const u8, lparen_index: usize) !ParsedSourceParams {
        var depth_paren: usize = 0;
        var depth_brace: usize = 0;
        var depth_bracket: usize = 0;
        var start = lparen_index + 1;
        var i = lparen_index + 1;
        var params = std.array_list.Managed(SourceParam).init(self.allocator);
        errdefer params.deinit();

        while (i < content.len) : (i += 1) {
            const ch = content[i];
            switch (ch) {
                '(' => depth_paren += 1,
                ')' => {
                    if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                        try self.appendSourceParam(&params, content[start..i]);
                        return .{
                            .items = try params.toOwnedSlice(),
                            .end_index = i,
                        };
                    }
                    depth_paren -= 1;
                },
                '{' => depth_brace += 1,
                '}' => depth_brace -= 1,
                '[' => depth_bracket += 1,
                ']' => depth_bracket -= 1,
                ',' => {
                    if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                        try self.appendSourceParam(&params, content[start..i]);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }

        return .{
            .items = try params.toOwnedSlice(),
            .end_index = content.len,
        };
    }

    fn appendSourceParam(self: *SourceResolver, params: *std.array_list.Managed(SourceParam), param_text: []const u8) !void {
        var param = std.mem.trim(u8, param_text, " \t\r\n");
        if (param.len == 0 or std.mem.eql(u8, param, "...")) return;

        if (std.mem.startsWith(u8, param, "comptime ")) {
            param = std.mem.trimLeft(u8, param["comptime ".len..], " \t");
        }
        if (std.mem.startsWith(u8, param, "noalias ")) {
            param = std.mem.trimLeft(u8, param["noalias ".len..], " \t");
        }

        const colon = std.mem.indexOfScalar(u8, param, ':') orelse return;
        const name = std.mem.trim(u8, param[0..colon], " \t");
        const type_expr = std.mem.trim(u8, param[colon + 1 ..], " \t");
        if (name.len == 0 or type_expr.len == 0) return;

        try params.append(.{
            .name = try self.allocator.dupe(u8, name),
            .type_expr = try self.allocator.dupe(u8, type_expr),
        });
    }

    fn appendParamName(self: *SourceResolver, names: *std.array_list.Managed([]const u8), param_text: []const u8) !void {
        var param = std.mem.trim(u8, param_text, " \t\r\n");
        if (param.len == 0) return;
        if (std.mem.eql(u8, param, "...")) return;

        if (std.mem.startsWith(u8, param, "comptime ")) {
            param = std.mem.trimLeft(u8, param["comptime ".len..], " \t");
        }
        if (std.mem.startsWith(u8, param, "noalias ")) {
            param = std.mem.trimLeft(u8, param["noalias ".len..], " \t");
        }

        const colon = std.mem.indexOfScalar(u8, param, ':') orelse return;
        const name = std.mem.trim(u8, param[0..colon], " \t");
        if (name.len == 0) return;
        try names.append(try self.allocator.dupe(u8, name));
    }

    fn readFile(self: *SourceResolver, file_path: []const u8) ![]const u8 {
        return try std.fs.cwd().readFileAlloc(file_path, self.allocator, .unlimited);
    }

    fn resolveImportPath(self: *SourceResolver, file_path: []const u8, alias: []const u8) !?[]const u8 {
        const content = try self.readFile(file_path);
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = trimLine(line);
            if (matchImport(trimmed, alias)) |import_rel| {
                if (!std.mem.endsWith(u8, import_rel, ".zig")) return null;
                const base_dir = std.fs.path.dirname(file_path) orelse ".";
                return try std.fs.path.join(self.allocator, &.{ base_dir, import_rel });
            }
        }
        return null;
    }
};

fn trimLine(line: []const u8) []const u8 {
    var parts = std.mem.splitSequence(u8, line, "//");
    return std.mem.trim(u8, parts.first(), " \t\r\n");
}

fn stripFunctionQualifiers(text: []const u8) []const u8 {
    var rest = std.mem.trim(u8, text, " \t\r\n");
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "callconv(")) {
            rest = trimAfterBalancedCall(rest["callconv".len..]) orelse break;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "addrspace(")) {
            rest = trimAfterBalancedCall(rest["addrspace".len..]) orelse break;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "linksection(")) {
            rest = trimAfterBalancedCall(rest["linksection".len..]) orelse break;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "align(")) {
            rest = trimAfterBalancedCall(rest["align".len..]) orelse break;
            continue;
        }
        break;
    }
    return std.mem.trim(u8, rest, " \t\r\n");
}

fn trimAfterBalancedCall(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text[0] != '(') return null;
    var depth: usize = 1;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return std.mem.trimLeft(u8, text[i + 1 ..], " \t\r\n");
                }
            },
            else => {},
        }
    }
    return null;
}

fn matchImport(line: []const u8, alias: []const u8) ?[]const u8 {
    const prefix = "const ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const eq_index = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const lhs = std.mem.trim(u8, rest[0..eq_index], " \t");
    if (!std.mem.eql(u8, lhs, alias)) return null;

    const import_marker = "@import(\"";
    const import_start = std.mem.indexOf(u8, rest, import_marker) orelse return null;
    const after_marker = import_start + import_marker.len;
    const import_end_rel = std.mem.indexOfScalarPos(u8, rest, after_marker, '"') orelse return null;
    return rest[after_marker..import_end_rel];
}

fn matchConstAssignment(line: []const u8, symbol: []const u8) ?[]const u8 {
    const prefix = tryMatchConstPrefix(line) orelse return null;
    const rest = line[prefix..];
    const eq_index = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const lhs = std.mem.trim(u8, rest[0..eq_index], " \t");
    if (!std.mem.eql(u8, lhs, symbol)) return null;

    const rhs_full = std.mem.trim(u8, rest[eq_index + 1 ..], " \t");
    return std.mem.trimRight(u8, rhs_full, ";");
}

fn tryMatchConstPrefix(line: []const u8) ?usize {
    if (std.mem.startsWith(u8, line, "pub const ")) return "pub const ".len;
    if (std.mem.startsWith(u8, line, "const ")) return "const ".len;
    return null;
}

fn findConstAssignmentInContent(content: []const u8, symbol: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = trimLine(line);
        if (matchConstAssignment(trimmed, symbol)) |rhs| return rhs;
    }
    return null;
}

const ObjectSetCall = struct {
    name: []const u8,
    value_expr: []const u8,
};

fn matchObjectSetCall(line: []const u8, object_name: []const u8) ?ObjectSetCall {
    var rest = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.startsWith(u8, rest, "try ")) {
        rest = std.mem.trimLeft(u8, rest["try ".len..], " \t");
    }

    if (!std.mem.startsWith(u8, rest, object_name)) return null;
    rest = rest[object_name.len..];
    if (!std.mem.startsWith(u8, rest, ".Set(\"")) return null;
    rest = rest[".Set(\"".len..];

    const name_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..name_end];

    rest = std.mem.trimLeft(u8, rest[name_end + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != ',') return null;
    rest = std.mem.trimLeft(u8, rest[1..], " \t");

    const call_end = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return null;
    const value_expr = std.mem.trim(u8, rest[0..call_end], " \t");
    if (name.len == 0 or value_expr.len == 0) return null;

    return .{
        .name = name,
        .value_expr = value_expr,
    };
}

fn matchClassAssignment(rhs: []const u8) ?[]const u8 {
    const class_prefix = "napi.Class(";
    const class_without_init_prefix = "napi.ClassWithoutInit(";

    if (std.mem.startsWith(u8, rhs, class_prefix) and std.mem.endsWith(u8, rhs, ")")) {
        return std.mem.trim(u8, rhs[class_prefix.len .. rhs.len - 1], " \t");
    }
    if (std.mem.startsWith(u8, rhs, class_without_init_prefix) and std.mem.endsWith(u8, rhs, ")")) {
        return std.mem.trim(u8, rhs[class_without_init_prefix.len .. rhs.len - 1], " \t");
    }
    return null;
}

const AliasRef = struct {
    left: []const u8,
    right: []const u8,
};

fn parseAliasRef(rhs: []const u8) ?AliasRef {
    const dot_index = std.mem.indexOfScalar(u8, rhs, '.') orelse return null;
    return .{
        .left = std.mem.trim(u8, rhs[0..dot_index], " \t"),
        .right = std.mem.trim(u8, rhs[dot_index + 1 ..], " \t"),
    };
}

fn findFunctionStart(content: []const u8, fn_name: []const u8, require_pub: bool) ?usize {
    const pub_pattern = std.fmt.allocPrint(std.heap.page_allocator, "pub fn {s}(", .{fn_name}) catch @panic("OOM");
    defer std.heap.page_allocator.free(pub_pattern);
    if (std.mem.indexOf(u8, content, pub_pattern)) |start| {
        return start + pub_pattern.len - 1;
    }

    if (!require_pub) {
        const any_pattern = std.fmt.allocPrint(std.heap.page_allocator, "fn {s}(", .{fn_name}) catch @panic("OOM");
        defer std.heap.page_allocator.free(any_pattern);
        if (std.mem.indexOf(u8, content, any_pattern)) |start| {
            return start + any_pattern.len - 1;
        }
    }

    return null;
}

fn parseCallArguments(allocator: std.mem.Allocator, content: []const u8, lparen_index: usize) !ParsedTextList {
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var start = lparen_index + 1;
    var i = lparen_index + 1;
    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer args.deinit();

    while (i < content.len) : (i += 1) {
        const ch = content[i];
        switch (ch) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    const item = std.mem.trim(u8, content[start..i], " \t\r\n");
                    if (item.len > 0) try args.append(item);
                    return .{
                        .items = try args.toOwnedSlice(),
                        .end_index = i,
                    };
                }
                depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -= 1,
            ',' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    const item = std.mem.trim(u8, content[start..i], " \t\r\n");
                    if (item.len > 0) try args.append(item);
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    return .{
        .items = try args.toOwnedSlice(),
        .end_index = content.len,
    };
}

fn findStructBody(content: []const u8, struct_name: []const u8) ?[]const u8 {
    const const_pattern = std.fmt.allocPrint(std.heap.page_allocator, "const {s} = struct {{", .{struct_name}) catch @panic("OOM");
    defer std.heap.page_allocator.free(const_pattern);
    if (std.mem.indexOf(u8, content, const_pattern)) |start| {
        const body_start = start + const_pattern.len;
        var depth: usize = 1;
        var i = body_start;
        while (i < content.len) : (i += 1) {
            switch (content[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return content[body_start..i];
                },
                else => {},
            }
        }
    }

    const pub_const_pattern = std.fmt.allocPrint(std.heap.page_allocator, "pub const {s} = struct {{", .{struct_name}) catch @panic("OOM");
    defer std.heap.page_allocator.free(pub_const_pattern);
    if (std.mem.indexOf(u8, content, pub_const_pattern)) |start| {
        const body_start = start + pub_const_pattern.len;
        var depth: usize = 1;
        var i = body_start;
        while (i < content.len) : (i += 1) {
            switch (content[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return content[body_start..i];
                },
                else => {},
            }
        }
    }

    return null;
}

fn findFunctionBody(content: []const u8, fn_name: []const u8, require_pub: bool) ?[]const u8 {
    const pub_pattern = std.fmt.allocPrint(std.heap.page_allocator, "pub fn {s}(", .{fn_name}) catch @panic("OOM");
    defer std.heap.page_allocator.free(pub_pattern);
    if (std.mem.indexOf(u8, content, pub_pattern)) |start| {
        return bodyFromFnStart(content, start + pub_pattern.len - 1);
    }

    if (!require_pub) {
        const any_pattern = std.fmt.allocPrint(std.heap.page_allocator, "fn {s}(", .{fn_name}) catch @panic("OOM");
        defer std.heap.page_allocator.free(any_pattern);
        if (std.mem.indexOf(u8, content, any_pattern)) |start| {
            return bodyFromFnStart(content, start + any_pattern.len - 1);
        }
    }

    return null;
}

fn bodyFromFnStart(content: []const u8, lparen_index: usize) ?[]const u8 {
    var depth_paren: usize = 0;
    var i = lparen_index;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '(' => depth_paren += 1,
            ')' => {
                depth_paren -= 1;
                if (depth_paren == 0) break;
            },
            else => {},
        }
    }

    while (i < content.len and content[i] != '{') : (i += 1) {}
    if (i >= content.len or content[i] != '{') return null;

    const body_start = i + 1;
    var depth_brace: usize = 1;
    i = body_start;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '{' => depth_brace += 1,
            '}' => {
                depth_brace -= 1;
                if (depth_brace == 0) return content[body_start..i];
            },
            else => {},
        }
    }

    return null;
}

fn findReturnedFunctionTarget(body: []const u8) ?[]const u8 {
    const new_idx = std.mem.indexOf(u8, body, ".New(") orelse return null;
    const call_start = new_idx + ".New(".len;

    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var last_segment_start = call_start;
    var i = call_start;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        switch (ch) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    const last_segment = std.mem.trim(u8, body[last_segment_start..i], " \t\r\n");
                    return trimIdentifier(last_segment);
                }
                depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -= 1,
            ',' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    last_segment_start = i + 1;
                }
            },
            else => {},
        }
    }

    return null;
}

fn trimIdentifier(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var end = trimmed.len;
    while (end > 0 and isIdentifierChar(trimmed[end - 1])) : (end -= 1) {}
    if (end == trimmed.len) return trimmed;
    const tail = trimmed[end..];
    if (tail.len == 0) return null;
    return tail;
}

fn isIdentifierChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

fn emitType(state: *State, comptime T: type) ![]const u8 {
    switch (T) {
        void => return "void",
        bool => return "boolean",
        napi.Null => return "null",
        napi.Undefined => return "undefined",
        else => {},
    }

    if (isNumeric(T)) return "number";
    if (isStringLike(T)) return "string";
    if (isPromiseType(T)) return "Promise<void>";

    if (T == napi.Buffer) return "Buffer";
    if (T == napi.ArrayBuffer) return "ArrayBuffer";
    if (T == napi.DataView) return "DataView";

    if (typedArrayName(T)) |name| return name;

    const info = @typeInfo(T);
    switch (info) {
        .optional => {
            const child = info.optional.child;
            const child_name = try emitType(state, child);
            return try std.fmt.allocPrint(state.allocator, "{s} | undefined | null", .{child_name});
        },
        .array => {
            const child_name = try emitType(state, info.array.child);
            return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_name});
        },
        .pointer => {
            if (info.pointer.size == .one) {
                if (comptime isThreadsafeFunctionType(info.pointer.child)) {
                    return try emitFunctionLike(state, info.pointer.child, true);
                }
                if (comptime isFunctionType(info.pointer.child)) {
                    return try emitFunctionLike(state, info.pointer.child, false);
                }
            }
            if (isSlice(T)) {
                const child_name = try emitType(state, info.pointer.child);
                return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_name});
            }
        },
        .@"struct" => {
            if (comptime isTuple(T)) {
                var parts = StringBuilder.init(state.allocator);
                defer parts.deinit();
                try append(&parts, "[");
                inline for (info.@"struct".fields, 0..) |field, idx| {
                    if (idx > 0) try append(&parts, ", ");
                    try append(&parts, try emitType(state, field.type));
                }
                try append(&parts, "]");
                return try parts.toOwnedSlice();
            }

            if (comptime isArrayList(T)) {
                const child_name = try emitType(state, arrayListElementType(T));
                return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_name});
            }

            if (comptime isFunctionType(T)) return try emitFunctionLike(state, T, false);
            if (comptime isThreadsafeFunctionType(T)) return try emitFunctionLike(state, T, true);

            if (comptime isReferenceType(T)) {
                return emitType(state, T.referenced_type);
            }

            if (comptime isClassType(T)) {
                return shortTypeName(T);
            }

            if (comptime isObjectLikeStruct(T)) {
                try emitInterfaceDecl(state, T);
                return shortTypeName(T);
            }
        },
        .@"enum" => {
            try emitEnumDecl(state, T);
            return shortTypeName(T);
        },
        .@"union" => {
            return try emitUnionType(state, T);
        },
        else => {},
    }

    return "unknown";
}

fn emitEnumDecl(state: *State, comptime T: type) !void {
    const name = shortTypeName(T);
    if (state.emitted.contains(name)) return;
    try state.emitted.put(name, {});

    try appendFmt(&state.declarations, "export declare const enum {s} {{\n", .{name});
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (comptime isStringEnumType(T)) {
            try appendFmt(&state.declarations, "  {s} = '{s}',\n", .{ field.name, field.name });
        } else {
            try appendFmt(&state.declarations, "  {s} = {d},\n", .{ field.name, field.value });
        }
    }
    try append(&state.declarations, "}\n\n");
}

fn emitInterfaceDecl(state: *State, comptime T: type) !void {
    const name = shortTypeName(T);
    if (state.emitted.contains(name)) return;
    try state.emitted.put(name, {});

    const info = @typeInfo(T).@"struct";
    try appendFmt(&state.declarations, "export interface {s} {{\n", .{name});
    inline for (info.fields) |field| {
        const field_info = @typeInfo(field.type);
        const ts_type = switch (field_info) {
            .optional => try emitType(state, field_info.optional.child),
            else => try emitType(state, field.type),
        };
        if (field_info == .optional) {
            try appendFmt(&state.declarations, "  {s}?: {s}\n", .{ field.name, ts_type });
        } else {
            try appendFmt(&state.declarations, "  {s}: {s}\n", .{ field.name, ts_type });
        }
    }
    try append(&state.declarations, "}\n\n");
}

fn emitUnionType(state: *State, comptime T: type) ![]const u8 {
    const info = @typeInfo(T).@"union";
    if (info.fields.len == 0) return "never";

    var buf = StringBuilder.init(state.allocator);
    defer buf.deinit();

    inline for (info.fields, 0..) |field, idx| {
        if (idx > 0) try append(&buf, " | ");
        try append(&buf, try emitType(state, field.type));
    }

    return try buf.toOwnedSlice();
}

fn collectFunctionInfo(comptime T: type) struct {
    args_type: type,
    return_type: type,
    tsfn_error_first: bool,
} {
    const info = @typeInfo(T).@"struct";
    comptime var args_type: type = void;
    comptime var return_type: type = void;
    comptime var tsfn_error_first = false;

    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "args")) args_type = field.type;
        if (std.mem.eql(u8, field.name, "return_type")) return_type = field.type;
        if (std.mem.eql(u8, field.name, "thread_safe_function_call_variant")) {
            const tmp = @as(T, undefined);
            tsfn_error_first = @field(tmp, "thread_safe_function_call_variant");
        }
    }
    return .{ .args_type = args_type, .return_type = return_type, .tsfn_error_first = tsfn_error_first };
}

fn emitFunctionLike(state: *State, comptime T: type, comptime is_tsfn: bool) ![]const u8 {
    return emitFunctionLikeWithNames(state, T, is_tsfn, null);
}

fn emitFunctionLikeWithNames(state: *State, comptime T: type, comptime is_tsfn: bool, param_names: ?[]const []const u8) ![]const u8 {
    const info = collectFunctionInfo(T);
    var buf = StringBuilder.init(state.allocator);
    defer buf.deinit();
    try append(&buf, "(");

    var wrote_arg = false;
    if (is_tsfn and info.tsfn_error_first) {
        try append(&buf, "err: Error | null");
        wrote_arg = true;
    }

    const args_info = @typeInfo(info.args_type);
    switch (info.args_type) {
        void => {},
        else => switch (args_info) {
            .@"struct" => {
                if (args_info.@"struct".is_tuple) {
                    const total = args_info.@"struct".fields.len;
                    inline for (args_info.@"struct".fields, 0..) |field, idx| {
                        if (wrote_arg or idx > 0) try append(&buf, ", ");
                        const arg_type = try emitType(state, field.type);
                        try appendFmt(&buf, "{s}: {s}", .{ resolvedArgName(param_names, idx, total), arg_type });
                        wrote_arg = true;
                    }
                } else {
                    if (wrote_arg) try append(&buf, ", ");
                    const arg_type = try emitType(state, info.args_type);
                    try appendFmt(&buf, "{s}: {s}", .{ resolvedArgName(param_names, 0, 1), arg_type });
                }
            },
            else => {
                if (wrote_arg) try append(&buf, ", ");
                const arg_type = try emitType(state, info.args_type);
                try appendFmt(&buf, "{s}: {s}", .{ resolvedArgName(param_names, 0, 1), arg_type });
            },
        },
    }

    try append(&buf, ") => ");
    if (is_tsfn) {
        try append(&buf, "void");
    } else {
        try append(&buf, try emitType(state, info.return_type));
    }
    return try buf.toOwnedSlice();
}

fn emitMethodSignature(state: *State, writer: *StringBuilder, comptime fn_type: type, comptime name: []const u8, comptime skip_first: bool, param_names: ?[]const []const u8) !void {
    const info = @typeInfo(fn_type).@"fn";
    try appendFmt(writer, "{s}(", .{name});

    try emitMethodParams(state, writer, fn_type, skip_first, param_names);

    const ret = info.return_type.?;
    const ret_payload = switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
    try appendFmt(writer, ": {s}", .{try emitType(state, ret_payload)});
}

fn emitMethodParams(state: *State, writer: *StringBuilder, comptime fn_type: type, comptime skip_first: bool, param_names: ?[]const []const u8) !void {
    const info = @typeInfo(fn_type).@"fn";
    var first = true;
    const total = if (skip_first) info.params.len - 1 else info.params.len;
    const source_offset: usize = if (param_names) |names|
        if (skip_first and names.len == total + 1) 1 else 0
    else
        0;
    inline for (info.params, 0..) |param, idx| {
        if (skip_first and idx == 0) continue;
        if (!first) try append(writer, ", ");
        first = false;
        const ts_type = try emitType(state, param.type.?);
        const arg_idx = if (skip_first) idx - 1 else idx;
        const effective_names = if (param_names) |names| names[source_offset..] else null;
        try appendFmt(writer, "{s}: {s}", .{ resolvedArgName(effective_names, arg_idx, total), ts_type });
    }
    try append(writer, ")");
}

fn emitClassDecl(state: *State, comptime ExportName: []const u8, comptime T: type) !void {
    if (state.exported.contains(ExportName)) return;
    try state.exported.put(ExportName, {});
    if (state.emitted.contains(ExportName)) return;
    try state.emitted.put(ExportName, {});

    const Wrapped = T.WrappedType;
    const wrapped_info = @typeInfo(Wrapped).@"struct";
    try appendFmt(&state.declarations, "export declare class {s} {{\n", .{ExportName});

    if (@hasDecl(T, "HasConstructorInit") and !T.HasConstructorInit) {
        try append(&state.declarations, "  private constructor()\n");
    } else {
        if (@hasDecl(Wrapped, "init")) {
            try append(&state.declarations, "  constructor(");
            const constructor_param_names = try state.source.getClassConstructorParamNames(ExportName);
            try emitMethodParams(state, &state.declarations, @TypeOf(Wrapped.init), false, constructor_param_names);
            try append(&state.declarations, "\n");
        } else {
            try append(&state.declarations, "  constructor(");
            inline for (wrapped_info.fields, 0..) |field, idx| {
                if (idx > 0) try append(&state.declarations, ", ");
                try appendFmt(&state.declarations, "{s}: {s}", .{ field.name, try emitType(state, field.type) });
            }
            try append(&state.declarations, ")\n");
        }
    }

    inline for (wrapped_info.fields) |field| {
        try appendFmt(&state.declarations, "  {s}: {s}\n", .{ field.name, try emitType(state, field.type) });
    }

    inline for (wrapped_info.decls) |decl| {
        const value = @field(Wrapped, decl.name);
        const decl_type = @TypeOf(value);
        if (@typeInfo(decl_type) == .@"fn") {
            if (comptime std.mem.eql(u8, decl.name, "init") or std.mem.eql(u8, decl.name, "deinit")) continue;
            const fn_info = @typeInfo(decl_type).@"fn";
            const is_instance = fn_info.params.len > 0 and (fn_info.params[0].type.? == *Wrapped or fn_info.params[0].type.? == Wrapped);
            const ret = fn_info.return_type.?;
            const ret_payload = switch (@typeInfo(ret)) {
                .error_union => |eu| eu.payload,
                else => ret,
            };
            const is_factory = ret_payload == Wrapped or ret_payload == *Wrapped;
            if (!is_instance and is_factory) {
                const method_param_names = try state.source.getClassMethodParamNames(ExportName, decl.name);
                try appendFmt(&state.declarations, "  static {s}(", .{decl.name});
                try emitMethodParams(state, &state.declarations, decl_type, false, method_param_names);
                try appendFmt(&state.declarations, ": {s}", .{ExportName});
                try append(&state.declarations, "\n");
            } else if (!is_instance) {
                const method_param_names = try state.source.getClassMethodParamNames(ExportName, decl.name);
                try append(&state.declarations, "  static ");
                try emitMethodSignature(state, &state.declarations, decl_type, decl.name, false, method_param_names);
                try append(&state.declarations, "\n");
            } else {
                const method_param_names = try state.source.getClassMethodParamNames(ExportName, decl.name);
                try append(&state.declarations, "  ");
                try emitMethodSignature(state, &state.declarations, decl_type, decl.name, true, method_param_names);
                try append(&state.declarations, "\n");
            }
        } else if (@typeInfo(decl_type) != .type) {
            try appendFmt(&state.declarations, "  static readonly {s}: {s}\n", .{ decl.name, try emitType(state, decl_type) });
        }
    }

    try append(&state.declarations, "}\n\n");
}

fn emitExportFunction(state: *State, comptime name: []const u8, comptime fn_value: anytype) !void {
    if (state.exported.contains(name)) return;
    try state.exported.put(name, {});
    const fn_type = @TypeOf(fn_value);
    const info = @typeInfo(fn_type).@"fn";
    try appendFmt(&state.exports, "export declare function {s}(", .{name});

    const has_env = info.params.len > 0 and info.params[0].type.? == napi.Env;
    const total = if (has_env) info.params.len - 1 else info.params.len;
    const source_param_names = try state.source.getExportFunctionParamNames(name);
    const source_offset: usize = if (source_param_names) |names|
        if (has_env and names.len == total + 1) 1 else 0
    else
        0;
    const effective_names = if (source_param_names) |names| names[source_offset..] else null;
    var first = true;
    inline for (info.params, 0..) |param, idx| {
        if (has_env and idx == 0) continue;
        if (!first) try append(&state.exports, ", ");
        first = false;
        const ts_type = try emitType(state, param.type.?);
        const arg_idx = if (has_env) idx - 1 else idx;
        try appendFmt(&state.exports, "{s}: {s}", .{ resolvedArgName(effective_names, arg_idx, total), ts_type });
    }

    const ret = info.return_type.?;
    const ret_payload = switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
    const ret_payload_info = @typeInfo(ret_payload);
    if (comptime isFunctionType(ret_payload)) {
        const returned_param_names = try state.source.getReturnedFunctionParamNames(name);
        try append(&state.exports, "): ");
        try append(&state.exports, try emitFunctionLikeWithNames(state, ret_payload, false, returned_param_names));
        try append(&state.exports, "\n");
    } else if (comptime ret_payload_info == .pointer and ret_payload_info.pointer.size == .one and isFunctionType(ret_payload_info.pointer.child)) {
        const returned_param_names = try state.source.getReturnedFunctionParamNames(name);
        try append(&state.exports, "): ");
        try append(&state.exports, try emitFunctionLikeWithNames(state, ret_payload_info.pointer.child, false, returned_param_names));
        try append(&state.exports, "\n");
    } else {
        try appendFmt(&state.exports, "): {s}\n", .{try emitType(state, ret_payload)});
    }
}

fn emitExportConst(state: *State, comptime name: []const u8, value: anytype) !void {
    if (state.exported.contains(name)) return;
    try state.exported.put(name, {});
    const ts_type = try emitType(state, @TypeOf(value));
    try appendFmt(&state.exports, "export declare const {s}: {s}\n", .{ name, ts_type });
}

fn isSimpleIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!isIdentifierChar(ch)) return false;
    }
    return true;
}

fn isStringLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"';
}

fn isNumericLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    var start: usize = 0;
    if (trimmed[0] == '-' or trimmed[0] == '+') start = 1;
    if (start >= trimmed.len) return false;
    for (trimmed[start..]) |ch| {
        if (!((ch >= '0' and ch <= '9') or ch == '.' or ch == '_')) return false;
    }
    return true;
}

fn isSourceEnvType(type_expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_expr, " \t\r\n");
    return std.mem.eql(u8, trimmed, "napi.Env") or std.mem.eql(u8, trimmed, "Env");
}

fn isSourceNumericType(type_expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_expr, " \t\r\n");
    return std.mem.eql(u8, trimmed, "i8") or
        std.mem.eql(u8, trimmed, "i16") or
        std.mem.eql(u8, trimmed, "i32") or
        std.mem.eql(u8, trimmed, "i64") or
        std.mem.eql(u8, trimmed, "isize") or
        std.mem.eql(u8, trimmed, "u8") or
        std.mem.eql(u8, trimmed, "u16") or
        std.mem.eql(u8, trimmed, "u32") or
        std.mem.eql(u8, trimmed, "u64") or
        std.mem.eql(u8, trimmed, "usize") or
        std.mem.eql(u8, trimmed, "f16") or
        std.mem.eql(u8, trimmed, "f32") or
        std.mem.eql(u8, trimmed, "f64") or
        std.mem.eql(u8, trimmed, "f80") or
        std.mem.eql(u8, trimmed, "f128") or
        std.mem.eql(u8, trimmed, "c_short") or
        std.mem.eql(u8, trimmed, "c_int") or
        std.mem.eql(u8, trimmed, "c_uint") or
        std.mem.eql(u8, trimmed, "c_long") or
        std.mem.eql(u8, trimmed, "c_ulong") or
        std.mem.eql(u8, trimmed, "c_longlong") or
        std.mem.eql(u8, trimmed, "c_ulonglong") or
        std.mem.eql(u8, trimmed, "c_float") or
        std.mem.eql(u8, trimmed, "c_double");
}

fn trimConstType(type_expr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, type_expr, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "const ")) {
        return std.mem.trimLeft(u8, trimmed["const ".len..], " \t");
    }
    return trimmed;
}

fn matchSourceSliceChild(type_expr: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_expr, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "[]")) return trimConstType(trimmed[2..]);
    return null;
}

fn matchSourceArrayChild(type_expr: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_expr, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
    if (close + 1 >= trimmed.len) return null;
    return trimConstType(trimmed[close + 1 ..]);
}

fn isSourceStringType(type_expr: []const u8) bool {
    if (matchSourceSliceChild(type_expr)) |child| {
        return std.mem.eql(u8, child, "u8") or std.mem.eql(u8, child, "u16");
    }
    return false;
}

const TypeCall = struct {
    callee: []const u8,
    arg: []const u8,
};

fn parseSingleArgTypeCall(text: []const u8) ?TypeCall {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const callee = std.mem.trim(u8, trimmed[0..open], " \t");
    const arg = std.mem.trim(u8, trimmed[open + 1 .. trimmed.len - 1], " \t");
    if (callee.len == 0 or arg.len == 0 or std.mem.indexOfScalar(u8, arg, ',') != null) return null;
    return .{ .callee = callee, .arg = arg };
}

fn splitTopLevelCommaList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var items = std.array_list.Managed([]const u8).init(allocator);
    errdefer items.deinit();

    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) {
                    depth_paren -= 1;
                }
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) {
                    depth_brace -= 1;
                }
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) {
                    depth_bracket -= 1;
                }
            },
            ',' => {
                if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                    const item = std.mem.trim(u8, text[start..i], " \t\r\n");
                    if (item.len > 0) try items.append(item);
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, text[start..], " \t\r\n");
    if (tail.len > 0) try items.append(tail);
    return try items.toOwnedSlice();
}

fn isArrayListTypeAlias(state: *State, file_path: []const u8, callee: []const u8, depth: usize) !bool {
    if (depth > 8) return false;
    const trimmed = std.mem.trim(u8, callee, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "ArrayList") or std.mem.eql(u8, trimmed, "std.ArrayList")) return true;
    if (std.mem.endsWith(u8, trimmed, ".ArrayList")) return true;

    if (try state.source.findConstAssignmentInFile(file_path, trimmed)) |rhs| {
        const resolved = std.mem.trim(u8, rhs, " \t\r\n");
        if (std.mem.eql(u8, resolved, "std.ArrayList") or std.mem.eql(u8, resolved, "ArrayList")) return true;
        if (parseAliasRef(resolved)) |alias| {
            return std.mem.eql(u8, alias.right, "ArrayList");
        }
    }
    return false;
}

fn emitSourceStructType(state: *State, file_path: []const u8, struct_expr: []const u8, depth: usize) anyerror![]const u8 {
    const trimmed = std.mem.trim(u8, struct_expr, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "struct {") or !std.mem.endsWith(u8, trimmed, "}")) return "unknown";

    const body = std.mem.trim(u8, trimmed["struct {".len .. trimmed.len - 1], " \t\r\n");
    const parts = try splitTopLevelCommaList(state.allocator, body);

    var is_tuple = true;
    for (parts) |part| {
        if (std.mem.indexOfScalar(u8, part, ':') != null) {
            is_tuple = false;
            break;
        }
    }

    var buf = StringBuilder.init(state.allocator);
    defer buf.deinit();

    if (is_tuple) {
        try append(&buf, "[");
        for (parts, 0..) |part, idx| {
            if (idx > 0) try append(&buf, ", ");
            try append(&buf, try emitSourceTypeExpr(state, file_path, part, depth + 1));
        }
        try append(&buf, "]");
    } else {
        try append(&buf, "{ ");
        var first = true;
        for (parts) |part| {
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
            if (!first) try append(&buf, "; ");
            first = false;
            const field_name = std.mem.trim(u8, part[0..colon], " \t");
            const field_type = std.mem.trim(u8, part[colon + 1 ..], " \t");
            try appendFmt(&buf, "{s}: {s}", .{ field_name, try emitSourceTypeExpr(state, file_path, field_type, depth + 1) });
        }
        try append(&buf, " }");
    }

    return try buf.toOwnedSlice();
}

fn emitSourceTypeExpr(state: *State, file_path: []const u8, type_expr: []const u8, depth: usize) anyerror![]const u8 {
    if (depth > 8) return "unknown";

    const trimmed = std.mem.trim(u8, stripFunctionQualifiers(type_expr), " \t\r\n");
    if (trimmed.len == 0) return "void";

    if (std.mem.startsWith(u8, trimmed, "?")) {
        const child = try emitSourceTypeExpr(state, file_path, trimmed[1..], depth + 1);
        return try std.fmt.allocPrint(state.allocator, "{s} | undefined | null", .{child});
    }

    if (std.mem.lastIndexOfScalar(u8, trimmed, '!')) |idx| {
        return try emitSourceTypeExpr(state, file_path, trimmed[idx + 1 ..], depth + 1);
    }

    if (std.mem.eql(u8, trimmed, "void")) return "void";
    if (std.mem.eql(u8, trimmed, "bool")) return "boolean";
    if (isSourceNumericType(trimmed)) return "number";
    if (isSourceStringType(trimmed)) return "string";

    if (std.mem.eql(u8, trimmed, "napi.Promise")) return "Promise<void>";
    if (std.mem.eql(u8, trimmed, "napi.Buffer")) return "Buffer";
    if (std.mem.eql(u8, trimmed, "napi.ArrayBuffer")) return "ArrayBuffer";
    if (std.mem.eql(u8, trimmed, "napi.DataView")) return "DataView";

    if (matchSourceSliceChild(trimmed)) |child| {
        const child_ts = try emitSourceTypeExpr(state, file_path, child, depth + 1);
        return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_ts});
    }

    if (matchSourceArrayChild(trimmed)) |child| {
        const child_ts = try emitSourceTypeExpr(state, file_path, child, depth + 1);
        return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_ts});
    }

    if (std.mem.startsWith(u8, trimmed, "struct {") and std.mem.endsWith(u8, trimmed, "}")) {
        return try emitSourceStructType(state, file_path, trimmed, depth + 1);
    }

    if (parseSingleArgTypeCall(trimmed)) |type_call| {
        if (try isArrayListTypeAlias(state, file_path, type_call.callee, depth + 1)) {
            const child_ts = try emitSourceTypeExpr(state, file_path, type_call.arg, depth + 1);
            return try std.fmt.allocPrint(state.allocator, "Array<{s}>", .{child_ts});
        }
    }

    if (parseAliasRef(trimmed)) |alias| {
        if (try state.source.resolveImportPath(file_path, alias.left)) |import_path| {
            return try emitSourceTypeExpr(state, import_path, alias.right, depth + 1);
        }
    }

    if (try state.source.findConstAssignmentInFile(file_path, trimmed)) |rhs| {
        return try emitSourceTypeExpr(state, file_path, rhs, depth + 1);
    }

    return "unknown";
}

fn findLocalConstInitializer(body: []const u8, symbol: []const u8) ?[]const u8 {
    return findConstAssignmentInContent(body, symbol);
}

const ResolvedInitValue = union(enum) {
    function: SourceFunctionSignature,
    value_type: []const u8,
};

fn inferSourceValueType(state: *State, file_path: []const u8, init_body: []const u8, expr: []const u8, depth: usize) anyerror![]const u8 {
    if (depth > 8) return "unknown";

    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return "unknown";

    if (isStringLiteral(trimmed)) return "string";
    if (isNumericLiteral(trimmed)) return "number";
    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return "boolean";

    if (std.mem.startsWith(u8, trimmed, "napi.String.New(")) return "string";

    if (isSimpleIdentifier(trimmed)) {
        if (findLocalConstInitializer(init_body, trimmed)) |initializer| {
            return try inferSourceValueType(state, file_path, init_body, initializer, depth + 1);
        }
        if (try state.source.findConstAssignmentInFile(file_path, trimmed)) |initializer| {
            return try inferSourceValueType(state, file_path, init_body, initializer, depth + 1);
        }
    }

    return "unknown";
}

fn resolveInitValue(state: *State, file_path: []const u8, init_body: []const u8, expr: []const u8, depth: usize) anyerror!ResolvedInitValue {
    if (depth > 8) return .{ .value_type = "unknown" };

    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return .{ .value_type = "unknown" };

    if (isSimpleIdentifier(trimmed)) {
        if (findLocalConstInitializer(init_body, trimmed)) |initializer| {
            return try resolveInitValue(state, file_path, init_body, initializer, depth + 1);
        }

        if (try state.source.findSourceFunctionSignature(file_path, trimmed, false)) |signature| {
            return .{ .function = signature };
        }

        if (try state.source.findConstAssignmentInFile(file_path, trimmed)) |initializer| {
            return try resolveInitValue(state, file_path, init_body, initializer, depth + 1);
        }
    }

    if (parseAliasRef(trimmed)) |alias| {
        if (try state.source.resolveImportPath(file_path, alias.left)) |import_path| {
            if (try state.source.findSourceFunctionSignature(import_path, alias.right, false)) |signature| {
                return .{ .function = signature };
            }
            return try resolveInitValue(state, import_path, init_body, alias.right, depth + 1);
        }
    }

    return .{ .value_type = try inferSourceValueType(state, file_path, init_body, trimmed, depth + 1) };
}

fn buildInitFunctionDeclaration(state: *State, export_name: []const u8, file_path: []const u8, signature: SourceFunctionSignature) anyerror![]const u8 {
    var buf = StringBuilder.init(state.allocator);
    defer buf.deinit();

    try appendFmt(&buf, "export declare function {s}(", .{export_name});

    const has_env = signature.params.len > 0 and isSourceEnvType(signature.params[0].type_expr);
    var first = true;
    for (signature.params, 0..) |param, idx| {
        if (has_env and idx == 0) continue;
        if (!first) try append(&buf, ", ");
        first = false;
        try appendFmt(&buf, "{s}: {s}", .{
            param.name,
            try emitSourceTypeExpr(state, file_path, param.type_expr, 0),
        });
    }

    try appendFmt(&buf, "): {s}\n", .{try emitSourceTypeExpr(state, file_path, signature.return_type_expr, 0)});
    return try buf.toOwnedSlice();
}

fn buildInitExport(state: *State, spec: InitExportSpec) anyerror!InitExport {
    const resolved = try resolveInitValue(state, spec.file_path, spec.init_body, spec.value_expr, 0);
    return switch (resolved) {
        .function => |signature| .{
            .name = spec.name,
            .declaration = try buildInitFunctionDeclaration(state, spec.name, spec.file_path, signature),
        },
        .value_type => |ts_type| .{
            .name = spec.name,
            .declaration = try std.fmt.allocPrint(state.allocator, "export declare const {s}: {s}\n", .{ spec.name, ts_type }),
        },
    };
}

fn emitInitExports(state: *State) anyerror!void {
    const specs = try state.source.collectInitExportSpecs();
    for (specs) |spec| {
        if (state.exported.contains(spec.name)) continue;
        const init_export = try buildInitExport(state, spec);
        try state.exported.put(init_export.name, {});
        try append(&state.exports, init_export.declaration);
    }
}

fn appendHeader(writer: *StringBuilder, header: []const u8) !void {
    if (header.len == 0) return;
    try append(writer, header);
    if (header[header.len - 1] != '\n') {
        try append(writer, "\n");
    }
    try append(writer, "\n");
}

fn generate(allocator: std.mem.Allocator, root_source_path: []const u8, header: []const u8) ![]u8 {
    var source = SourceResolver.init(allocator, root_source_path);
    var state = State.init(allocator, &source);
    defer state.deinit();

    const Root = if (@TypeOf(root) == type) root else @TypeOf(root);
    const root_info = @typeInfo(Root).@"struct";
    inline for (root_info.fields) |field| {
        const value = @field(root, field.name);
        if (comptime @typeInfo(field.type) == .@"fn") {
            try emitExportFunction(&state, field.name, value);
        } else if (comptime isClassType(field.type)) {
            try emitClassDecl(&state, field.name, field.type);
        } else {
            try emitExportConst(&state, field.name, value);
        }
    }

    inline for (root_info.decls) |decl| {
        const value = @field(root, decl.name);
        const decl_type = @TypeOf(value);
        if (comptime @typeInfo(decl_type) == .@"fn") {
            try emitExportFunction(&state, decl.name, value);
        } else if (comptime decl_type == type and isClassType(value)) {
            try emitClassDecl(&state, decl.name, value);
        } else if (comptime decl_type == type and isObjectLikeStruct(value)) {
            try emitInterfaceDecl(&state, value);
        } else if (comptime decl_type == type and @typeInfo(value) == .@"enum") {
            try emitEnumDecl(&state, value);
        } else if (comptime isClassType(decl_type)) {
            try emitClassDecl(&state, decl.name, decl_type);
        } else if (comptime @typeInfo(decl_type) != .type) {
            try emitExportConst(&state, decl.name, value);
        }
    }

    try emitInitExports(&state);

    var output = StringBuilder.init(allocator);
    errdefer output.deinit();
    try append(&output, "/* auto-generated by zig-addon */\n");
    try append(&output, "/* eslint-disable */\n");
    try appendHeader(&output, header);
    if (header.len == 0 and state.declarations.items.len > 0) {
        try append(&output, "\n");
    }
    try append(&output, state.declarations.items);
    if (state.declarations.items.len > 0 and state.exports.items.len > 0) {
        try append(&output, "\n");
    }
    try append(&output, state.exports.items);
    return try output.toOwnedSlice();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const output_path = args.next() orelse return error.InvalidArgument;
    const root_source_path = args.next() orelse return error.InvalidArgument;
    const header = args.next() orelse "";

    const content = try generate(allocator, root_source_path, header);
    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}
