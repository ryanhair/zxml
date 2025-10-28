const std = @import("std");
const PullParser = @import("pull_parser.zig").PullParser;
const Event = @import("pull_parser.zig").Event;
const Attribute = @import("pull_parser.zig").Attribute;

// ============================================================================
// Comptime Type Introspection Helpers
// ============================================================================

/// Check if a type is a struct type
fn isStructType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        else => false,
    };
}

/// Check if a type is an optional type
fn isOptionalType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

/// Get the child type of an optional
fn getOptionalChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => @compileError("Type is not optional: " ++ @typeName(T)),
    };
}

/// Check if a type has a parseXml function for custom parsing
fn hasParseXml(comptime T: type) bool {
    if (!isStructType(T)) return false;

    const decls = switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls,
        else => return false,
    };

    // Look for parseXml function
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, "parseXml")) {
            return true;
        }
    }

    return false;
}

/// Check if a type has xml_names configuration
fn hasXmlNames(comptime T: type) bool {
    const decls = switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls,
        .@"union" => |u| u.decls,
        else => return false,
    };

    // Look for xml_names declaration
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, "xml_names")) {
            return true;
        }
    }

    return false;
}

/// Get the XML name for a field (either from xml_names mapping or field name)
fn getXmlName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!comptime hasXmlNames(T)) {
        return field_name;
    }

    const xml_names = T.xml_names;
    const xml_names_type = @typeInfo(@TypeOf(xml_names));

    // xml_names should be a struct literal
    if (xml_names_type != .@"struct") {
        @compileError("xml_names must be a struct literal");
    }

    const name_fields = xml_names_type.@"struct".fields;

    // Look for the field name in xml_names
    inline for (name_fields) |name_field| {
        if (std.mem.eql(u8, name_field.name, field_name)) {
            return @field(xml_names, field_name);
        }
    }

    // Not found in mapping, use field name
    return field_name;
}

/// Validate xml_names configuration at compile time
fn validateXmlNames(comptime T: type) void {
    if (!comptime hasXmlNames(T)) return;

    const type_info = @typeInfo(T);
    const xml_names = T.xml_names;
    const xml_names_type = @typeInfo(@TypeOf(xml_names));

    if (xml_names_type != .@"struct") {
        @compileError("xml_names must be a struct literal");
    }

    const name_fields = xml_names_type.@"struct".fields;

    // Get fields based on whether this is a struct or union
    switch (type_info) {
        .@"struct" => |s| {
            // Check that all names in xml_names correspond to actual fields
            inline for (name_fields) |name_field| {
                var found = false;
                inline for (s.fields) |struct_field| {
                    if (std.mem.eql(u8, name_field.name, struct_field.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("xml_names contains mapping for non-existent field: " ++ name_field.name ++ " in struct " ++ @typeName(T));
                }
            }
        },
        .@"union" => |u| {
            // Check that all names in xml_names correspond to actual union variants
            inline for (name_fields) |name_field| {
                var found = false;
                inline for (u.fields) |union_field| {
                    if (std.mem.eql(u8, name_field.name, union_field.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("xml_names contains mapping for non-existent variant: " ++ name_field.name ++ " in union " ++ @typeName(T));
                }
            }
        },
        else => {},
    }
}

/// Check if a type is a primitive that can be parsed from text
fn isPrimitiveType(comptime T: type) bool {
    // Custom types with parseXml are treated as primitives
    if (comptime hasParseXml(T)) return true;

    return switch (@typeInfo(T)) {
        .int, .float, .bool => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };
}

/// Check if a type is an Iterator(tag_name, T) type
fn isIteratorType(comptime T: type) bool {
    if (!isStructType(T)) return false;

    const decls = switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls,
        else => return false,
    };

    // Look for the special __is_zxml_iterator marker
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, "__is_zxml_iterator")) {
            return true;
        }
    }

    return false;
}

/// Check if a type is a MultiIterator(Union) type
fn isMultiIteratorType(comptime T: type) bool {
    if (!isStructType(T)) return false;

    const decls = switch (@typeInfo(T)) {
        .@"struct" => |s| s.decls,
        else => return false,
    };

    // Look for the special __is_zxml_multi_iterator marker
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, "__is_zxml_multi_iterator")) {
            return true;
        }
    }

    return false;
}

/// Check if a struct has any Iterator or MultiIterator field
fn hasIterator(comptime T: type) bool {
    if (!isStructType(T)) return false;

    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => return false,
    };

    inline for (fields) |field| {
        if (isIteratorType(field.type) or isMultiIteratorType(field.type)) {
            return true;
        }
    }
    return false;
}

/// Count the number of Iterator/MultiIterator fields in a struct
fn countIterators(comptime T: type) comptime_int {
    if (!isStructType(T)) return 0;

    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => return 0,
    };

    var count: comptime_int = 0;

    inline for (fields) |field| {
        if (isIteratorType(field.type) or isMultiIteratorType(field.type)) {
            count += 1;
        }
    }
    return count;
}

// ============================================================================
// Schema Validation
// ============================================================================

/// Recursively validate that eager structs (no iterator) don't have lazy descendants
fn validateNoLazyDescendants(comptime T: type) void {
    if (!isStructType(T)) return;

    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => return,
    };

    inline for (fields) |field| {
        const FieldType = field.type;

        // Handle optional types
        const ActualType = if (isOptionalType(FieldType))
            getOptionalChild(FieldType)
        else
            FieldType;

        if (isStructType(ActualType)) {
            // Check if this nested struct has an iterator
            if (hasIterator(ActualType)) {
                @compileError("Eager struct cannot have lazy descendant: " ++
                    @typeName(T) ++ "." ++ field.name ++ " (" ++ @typeName(ActualType) ++ " has an iterator)");
            }

            // Recursively validate descendants
            validateNoLazyDescendants(ActualType);
        }
    }
}

/// Validate the entire schema structure
fn validateSchema(comptime T: type) void {
    // Must be a struct
    if (!isStructType(T)) {
        @compileError("TypedParser root type must be a struct, got: " ++ @typeName(T));
    }

    // Check iterator count constraint (0 or 1)
    const iter_count = countIterators(T);
    if (iter_count > 1) {
        @compileError("Struct can have at most 1 Iterator or MultiIterator field, found " ++
            std.fmt.comptimePrint("{d}", .{iter_count}) ++ " in " ++ @typeName(T));
    }

    // If no iterator (eager), validate no lazy descendants
    if (!hasIterator(T)) {
        validateNoLazyDescendants(T);
    }

    // Recursively validate all nested structs
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => return,
    };

    inline for (fields) |field| {
        const FieldType = field.type;

        // Handle optional types
        const ActualType = if (isOptionalType(FieldType))
            getOptionalChild(FieldType)
        else
            FieldType;

        // Recursively validate nested structs
        if (isStructType(ActualType) and !isIteratorType(ActualType) and !isMultiIteratorType(ActualType)) {
            validateSchema(ActualType);
        }
    }
}

// ============================================================================
// Primitive Type Parsers
// ============================================================================

/// Parse an integer from text
fn parseInteger(comptime T: type, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10) catch error.InvalidInteger;
}

/// Parse a float from text
fn parseFloat(comptime T: type, text: []const u8) !T {
    return std.fmt.parseFloat(T, text) catch error.InvalidFloat;
}

/// Parse a boolean from text ("true" or "false")
fn parseBoolean(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidBoolean;
}

/// Parse a string (zero-copy slice)
fn parseString(text: []const u8) []const u8 {
    return text;
}

/// Parse a primitive type from text
fn parsePrimitive(comptime T: type, text: []const u8) !T {
    // Check for custom parseXml function first
    if (comptime hasParseXml(T)) {
        return T.parseXml(text);
    }

    const info = @typeInfo(T);
    return switch (info) {
        .int => parseInteger(T, text),
        .float => parseFloat(T, text),
        .bool => parseBoolean(text),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk parseString(text);
            }
            @compileError("Unsupported pointer type for parsing: " ++ @typeName(T));
        },
        else => @compileError("Unsupported type for primitive parsing: " ++ @typeName(T)),
    };
}

/// Parse an optional type
fn parseOptional(comptime T: type, text: ?[]const u8) !?T {
    if (text == null) return null;
    return try parsePrimitive(T, text.?);
}

// ============================================================================
// Attribute Helpers
// ============================================================================

/// Find an attribute by name in an attributes slice
fn findAttribute(attributes: []const Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.name, name)) {
            return attr.value;
        }
    }
    return null;
}

// ============================================================================
// Struct Parsing
// ============================================================================

/// Parse an eager struct (no Iterator fields) - parses entire subtree
/// Called after seeing element_start, consumes up to and including the matching element_end
fn parseEagerStruct(comptime T: type, parser: *PullParser, attributes: []const Attribute, tag_name: []const u8) !T {
    // Validate xml_names configuration
    comptime validateXmlNames(T);

    var result: T = undefined;
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => @compileError("parseEagerStruct requires a struct type"),
    };

    // Track which fields we've parsed
    var fields_parsed: [fields.len]bool = [_]bool{false} ** fields.len;

    // Step 1: Parse attributes into fields
    inline for (fields, 0..) |field, i| {
        // Validation: eager structs can't have iterator fields
        comptime {
            if (isIteratorType(field.type) or isMultiIteratorType(field.type)) {
                @compileError("Eager struct " ++ @typeName(T) ++ " cannot have Iterator field: " ++ field.name);
            }
        }

        // Handle optional types
        const is_optional = comptime isOptionalType(field.type);
        const FieldType = comptime if (is_optional) getOptionalChild(field.type) else field.type;

        // Get the XML name for this field (may be mapped via xml_names)
        const xml_name = comptime getXmlName(T, field.name);

        // Try to find in attributes (for primitives)
        if (comptime isPrimitiveType(FieldType)) {
            if (findAttribute(attributes, xml_name)) |attr_value| {
                @field(result, field.name) = if (is_optional)
                    try parsePrimitive(FieldType, attr_value)
                else
                    try parsePrimitive(FieldType, attr_value);
                fields_parsed[i] = true;
            } else if (is_optional) {
                @field(result, field.name) = null;
                fields_parsed[i] = true;
            } else if (field.default_value_ptr) |default_ptr| {
                // Use default value if field has one
                const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                @field(result, field.name) = default_value;
                fields_parsed[i] = true;
            }
        }
    }

    // Step 2: Parse child elements
    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |elem| {
                // Check if this matches a field
                var matched = false;
                inline for (fields, 0..) |field, i| {
                    const xml_name = comptime getXmlName(T, field.name);
                    if (!matched and !fields_parsed[i] and std.mem.eql(u8, elem.name, xml_name)) {
                        const is_optional = comptime isOptionalType(field.type);
                        const FieldType = comptime if (is_optional) getOptionalChild(field.type) else field.type;

                        if (comptime isStructType(FieldType)) {
                            // Nested struct - parse recursively
                            const nested = try parseEagerStruct(FieldType, parser, elem.attributes, xml_name);
                            @field(result, field.name) = nested;
                            fields_parsed[i] = true;
                            matched = true;
                        } else if (comptime isPrimitiveType(FieldType)) {
                            // Primitive in element text content
                            const text = try parseElementText(parser);
                            @field(result, field.name) = try parsePrimitive(FieldType, text);
                            fields_parsed[i] = true;
                            matched = true;
                        }
                    }
                }

                // If we didn't match a field, skip this element entirely
                if (!matched) {
                    try skipElement(parser, elem.name);
                }
            },
            .end_element => |elem| {
                const name = elem.name;
                // Found our closing tag
                if (std.mem.eql(u8, name, tag_name)) {
                    // Check all required fields were parsed, or set defaults
                    inline for (fields, 0..) |field, i| {
                        if (!fields_parsed[i]) {
                            if (comptime isOptionalType(field.type)) {
                                // Optional field - already set to null above if not parsed
                            } else if (field.default_value_ptr) |default_ptr| {
                                // Use default value
                                const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                                @field(result, field.name) = default_value;
                                fields_parsed[i] = true;
                            } else {
                                return error.MissingRequiredField;
                            }
                        }
                    }
                    return result;
                }
                // Otherwise this is an unexpected closing tag
                return error.UnexpectedElement;
            },
            else => {},
        }
    }

    return error.UnexpectedEndOfDocument;
}

/// Skip an entire element (including all nested content)
/// Called after seeing element_start, consumes up to and including the matching element_end
fn skipElement(parser: *PullParser, tag_name: []const u8) !void {
    var depth: u32 = 1;
    while (try parser.next()) |event| {
        switch (event) {
            .start_element => depth += 1,
            .end_element => |elem| {
                const name = elem.name;
                depth -= 1;
                if (depth == 0 and std.mem.eql(u8, name, tag_name)) {
                    return;
                }
            },
            else => {},
        }
    }
    return error.UnexpectedEndOfDocument;
}

/// Parse element text content (consumes up to and including closing tag)
fn parseElementText(parser: *PullParser) ![]const u8 {
    while (try parser.next()) |event| {
        switch (event) {
            .text => |text| return text,
            .end_element => return "", // Empty element
            else => {},
        }
    }
    return error.UnexpectedEndOfDocument;
}

/// Parse a lazy struct (has Iterator/MultiIterator field) - parses attributes, creates iterator
/// Called after seeing start_element, positions parser for iteration (does NOT consume closing tag)
fn parseLazyStruct(comptime T: type, parser: *PullParser, attributes: []const Attribute, tag_name: []const u8) !T {
    // Validate xml_names configuration
    comptime validateXmlNames(T);

    var result: T = undefined;
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => @compileError("parseLazyStruct requires a struct type"),
    };

    // Note: We assume the caller (TypedParser.init) has already validated that T has an iterator

    // Parse attributes into non-iterator fields
    inline for (fields) |field| {
        const is_iterator = comptime (isIteratorType(field.type) or isMultiIteratorType(field.type));

        if (!is_iterator) {
            // Handle optional types
            const is_optional = comptime isOptionalType(field.type);
            const FieldType = comptime if (is_optional) getOptionalChild(field.type) else field.type;

            // Get the XML name for this field (may be mapped via xml_names)
            const xml_name = comptime getXmlName(T, field.name);

            // Try to find in attributes (for primitives)
            if (comptime isPrimitiveType(FieldType)) {
                if (findAttribute(attributes, xml_name)) |attr_value| {
                    @field(result, field.name) = if (is_optional)
                        try parsePrimitive(FieldType, attr_value)
                    else
                        try parsePrimitive(FieldType, attr_value);
                } else if (is_optional) {
                    @field(result, field.name) = null;
                } else if (field.default_value_ptr) |default_ptr| {
                    // Use default value
                    const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                    @field(result, field.name) = default_value;
                } else {
                    return error.MissingRequiredField;
                }
            } else {
                return error.LazyStructCanOnlyHavePrimitiveAttributes;
            }
        }
    }

    // Create iterator for the iterator field
    inline for (fields) |field| {
        if (comptime (isIteratorType(field.type) or isMultiIteratorType(field.type))) {
            @field(result, field.name) = field.type{
                .parser = parser,
                .parent_tag = tag_name,
            };
        }
    }

    return result;
}

// ============================================================================
// Iterator Type Generators
// ============================================================================

/// Generate an Iterator type for iterating over repeated elements with the same tag
pub fn Iterator(comptime tag_name: []const u8, comptime T: type) type {
    return struct {
        parser: *PullParser,
        parent_tag: []const u8,
        done: bool = false,
        last_element: ?[]const u8 = null,

        // Marker for type detection
        pub const __is_zxml_iterator = true;

        const ItemType = T;
        const item_tag = tag_name;

        pub fn next(self: *const @This()) !?ItemType {
            const mutable_self = @constCast(self);
            if (mutable_self.done) return null;

            // Auto-skip: if last element wasn't the one we're iterating, skip to parent close
            if (mutable_self.last_element) |last| {
                if (!std.mem.eql(u8, last, item_tag)) {
                    try mutable_self.skipToParentClose();
                    mutable_self.last_element = null;
                }
            }

            // Find next matching element
            while (try mutable_self.parser.next()) |event| {
                switch (event) {
                    .start_element => |elem| {
                        mutable_self.last_element = elem.name;

                        if (std.mem.eql(u8, elem.name, item_tag)) {
                            // Found matching element - parse it based on whether it has iterators
                            return if (comptime hasIterator(ItemType))
                                try parseLazyStruct(ItemType, mutable_self.parser, elem.attributes, elem.name)
                            else
                                try parseEagerStruct(ItemType, mutable_self.parser, elem.attributes, elem.name);
                        } else {
                            // Not our element, skip it entirely
                            try skipElement(mutable_self.parser, elem.name);
                        }
                    },
                    .end_element => |elem| {
                        const name = elem.name;
                        if (std.mem.eql(u8, name, mutable_self.parent_tag)) {
                            mutable_self.done = true;
                            return null;
                        }
                    },
                    else => {},
                }
            }

            mutable_self.done = true;
            return null;
        }

        fn skipToParentClose(self: *@This()) !void {
            var depth: u32 = 0;
            while (try self.parser.next()) |event| {
                switch (event) {
                    .start_element => depth += 1,
                    .end_element => |elem| {
                        const name = elem.name;
                        if (depth == 0 and std.mem.eql(u8, name, self.parent_tag)) {
                            self.done = true;
                            return;
                        }
                        depth -= 1;
                    },
                    else => {},
                }
            }
        }
    };
}

/// Generate a MultiIterator type for iterating over elements with different tags (union variants)
pub fn MultiIterator(comptime Union: type) type {
    // Validate that Union is a tagged union
    const union_info = @typeInfo(Union);
    if (union_info != .@"union") {
        @compileError("MultiIterator requires a union type, got: " ++ @typeName(Union));
    }

    // Validate xml_names if present
    comptime validateXmlNames(Union);

    return struct {
        parser: *PullParser,
        parent_tag: []const u8,
        done: bool = false,
        last_element: ?[]const u8 = null,

        // Marker for type detection
        pub const __is_zxml_multi_iterator = true;

        const UnionType = Union;

        pub fn next(self: *const @This()) !?UnionType {
            const mutable_self = @constCast(self);
            if (mutable_self.done) return null;

            // Auto-skip: if last element doesn't match any union variant, skip to parent close
            if (mutable_self.last_element) |last| {
                var matched_variant = false;
                inline for (@typeInfo(UnionType).@"union".fields) |field| {
                    const xml_name = comptime getXmlName(UnionType, field.name);
                    if (std.mem.eql(u8, last, xml_name)) {
                        matched_variant = true;
                        break;
                    }
                }
                if (!matched_variant) {
                    try mutable_self.skipToParentClose();
                    mutable_self.last_element = null;
                }
            }

            // Find next matching element
            while (try mutable_self.parser.next()) |event| {
                switch (event) {
                    .start_element => |elem| {
                        mutable_self.last_element = elem.name;

                        // Try to match against each union variant
                        inline for (@typeInfo(UnionType).@"union".fields) |field| {
                            const xml_name = comptime getXmlName(UnionType, field.name);
                            if (std.mem.eql(u8, elem.name, xml_name)) {
                                // Parse this variant based on whether it has iterators
                                const FieldType = field.type;
                                const parsed = if (comptime hasIterator(FieldType))
                                    try parseLazyStruct(FieldType, mutable_self.parser, elem.attributes, xml_name)
                                else
                                    try parseEagerStruct(FieldType, mutable_self.parser, elem.attributes, xml_name);
                                return @unionInit(UnionType, field.name, parsed);
                            }
                        }

                        // Not a union variant, skip it
                        try skipElement(mutable_self.parser, elem.name);
                    },
                    .end_element => |elem| {
                        const name = elem.name;
                        if (std.mem.eql(u8, name, mutable_self.parent_tag)) {
                            mutable_self.done = true;
                            return null;
                        }
                    },
                    else => {},
                }
            }

            mutable_self.done = true;
            return null;
        }

        fn skipToParentClose(self: *@This()) !void {
            var depth: u32 = 0;
            while (try self.parser.next()) |event| {
                switch (event) {
                    .start_element => depth += 1,
                    .end_element => |elem| {
                        const name = elem.name;
                        if (depth == 0 and std.mem.eql(u8, name, self.parent_tag)) {
                            self.done = true;
                            return;
                        }
                        depth -= 1;
                    },
                    else => {},
                }
            }
        }
    };
}

// ============================================================================
// TypedParser Generator
// ============================================================================

pub fn TypedParser(comptime T: type) type {
    // Validate schema at compile time
    comptime {
        validateSchema(T);
    }

    return struct {
        allocator: std.mem.Allocator,
        pull_parser: *PullParser,
        result: T,

        /// Initialize with a Reader for streaming parsing (large files)
        pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !@This() {
            const pull_parser = try allocator.create(PullParser);
            errdefer allocator.destroy(pull_parser);

            pull_parser.* = PullParser.initWithReader(allocator, reader);
            errdefer pull_parser.deinit();

            // Skip to first element (root)
            var root_elem: ?Event = null;
            while (try pull_parser.next()) |event| {
                if (event == .start_element) {
                    root_elem = event;
                    break;
                }
            }

            if (root_elem == null) {
                return error.NoRootElement;
            }

            const elem = root_elem.?.start_element;

            // Parse root element based on whether it has iterators
            const result = if (comptime hasIterator(T))
                try parseLazyStruct(T, pull_parser, elem.attributes, elem.name)
            else
                try parseEagerStruct(T, pull_parser, elem.attributes, elem.name);

            return .{
                .allocator = allocator,
                .pull_parser = pull_parser,
                .result = result,
            };
        }

        /// Initialize with XML in memory for faster parsing (small documents)
        /// Performance: ~800-850 MB/s
        pub fn initInMemory(allocator: std.mem.Allocator, xml: []const u8) !@This() {
            const pull_parser = try allocator.create(PullParser);
            errdefer allocator.destroy(pull_parser);

            pull_parser.* = PullParser.initInMemory(allocator, xml);
            errdefer pull_parser.deinit();

            // Skip to first element (root)
            var root_elem: ?Event = null;
            while (try pull_parser.next()) |event| {
                if (event == .start_element) {
                    root_elem = event;
                    break;
                }
            }

            if (root_elem == null) {
                return error.NoRootElement;
            }

            const elem = root_elem.?.start_element;

            // Parse root element based on whether it has iterators
            const result = if (comptime hasIterator(T))
                try parseLazyStruct(T, pull_parser, elem.attributes, elem.name)
            else
                try parseEagerStruct(T, pull_parser, elem.attributes, elem.name);

            return .{
                .allocator = allocator,
                .pull_parser = pull_parser,
                .result = result,
            };
        }

        /// Initialize with memory-mapped file for large documents
        /// Best for large files (100+ MB) - OS handles paging automatically
        /// Performance: ~550-800 MB/s depending on file size
        pub fn initWithMmap(allocator: std.mem.Allocator, file_path: []const u8) !@This() {
            const pull_parser = try allocator.create(PullParser);
            errdefer allocator.destroy(pull_parser);

            pull_parser.* = try PullParser.initWithMmap(allocator, file_path);
            errdefer pull_parser.deinit();

            // Skip to first element (root)
            var root_elem: ?Event = null;
            while (try pull_parser.next()) |event| {
                if (event == .start_element) {
                    root_elem = event;
                    break;
                }
            }

            if (root_elem == null) {
                return error.NoRootElement;
            }

            const elem = root_elem.?.start_element;

            // Parse root element based on whether it has iterators
            const result = if (comptime hasIterator(T))
                try parseLazyStruct(T, pull_parser, elem.attributes, elem.name)
            else
                try parseEagerStruct(T, pull_parser, elem.attributes, elem.name);

            return .{
                .allocator = allocator,
                .pull_parser = pull_parser,
                .result = result,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.pull_parser.deinit();
            self.allocator.destroy(self.pull_parser);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "validate simple eager struct" {
    const Simple = struct {
        name: []const u8,
        value: u32,
    };

    // Should compile without error
    comptime validateSchema(Simple);
}

test "validate nested eager struct" {
    const Inner = struct {
        x: u32,
        y: u32,
    };

    const Outer = struct {
        name: []const u8,
        inner: Inner,
    };

    // Should compile without error
    comptime validateSchema(Outer);
}

test "detect iterator count violation" {
    // This test validates comptime error detection
    // We can't actually run it, but it documents the expected behavior

    // const Invalid = struct {
    //     iter1: Iterator("foo", u32),
    //     iter2: Iterator("bar", u32),  // ERROR: too many iterators
    // };
    // comptime validateSchema(Invalid);
}

test "isPrimitiveType detection" {
    try std.testing.expect(isPrimitiveType(u32));
    try std.testing.expect(isPrimitiveType(i32));
    try std.testing.expect(isPrimitiveType(f32));
    try std.testing.expect(isPrimitiveType(bool));
    try std.testing.expect(isPrimitiveType([]const u8));
    try std.testing.expect(!isPrimitiveType(struct { x: u32 }));
}

test "isOptionalType detection" {
    try std.testing.expect(isOptionalType(?u32));
    try std.testing.expect(isOptionalType(?[]const u8));
    try std.testing.expect(!isOptionalType(u32));
    try std.testing.expect(!isOptionalType([]const u8));
}

test "hasIterator detection" {
    const NoIter = struct {
        x: u32,
    };

    const WithIter = struct {
        x: u32,
        items: Iterator("item", u32),
    };

    try std.testing.expect(!hasIterator(NoIter));
    try std.testing.expect(hasIterator(WithIter));
}

test "Iterator type detection" {
    const TestIter = Iterator("test", u32);
    try std.testing.expect(isIteratorType(TestIter));

    const TestStruct = struct { x: u32 };
    try std.testing.expect(!isIteratorType(TestStruct));
}

test "parseInteger" {
    try std.testing.expectEqual(@as(u32, 42), try parseInteger(u32, "42"));
    try std.testing.expectEqual(@as(i32, -123), try parseInteger(i32, "-123"));
    try std.testing.expectEqual(@as(u8, 255), try parseInteger(u8, "255"));
    try std.testing.expectError(error.InvalidInteger, parseInteger(u32, "abc"));
    try std.testing.expectError(error.InvalidInteger, parseInteger(u8, "256"));
}

test "parseFloat" {
    try std.testing.expectEqual(@as(f32, 3.14), try parseFloat(f32, "3.14"));
    try std.testing.expectEqual(@as(f64, -2.5), try parseFloat(f64, "-2.5"));
    try std.testing.expectError(error.InvalidFloat, parseFloat(f32, "abc"));
}

test "parseBoolean" {
    try std.testing.expectEqual(true, try parseBoolean("true"));
    try std.testing.expectEqual(false, try parseBoolean("false"));
    try std.testing.expectError(error.InvalidBoolean, parseBoolean("yes"));
    try std.testing.expectError(error.InvalidBoolean, parseBoolean("1"));
}

test "parseString" {
    const text = "hello world";
    const result = parseString(text);
    try std.testing.expectEqualStrings("hello world", result);
    // Zero-copy: should be same slice
    try std.testing.expectEqual(text.ptr, result.ptr);
}

test "parsePrimitive" {
    try std.testing.expectEqual(@as(u32, 42), try parsePrimitive(u32, "42"));
    try std.testing.expectEqual(@as(f32, 3.14), try parsePrimitive(f32, "3.14"));
    try std.testing.expectEqual(true, try parsePrimitive(bool, "true"));
    try std.testing.expectEqualStrings("test", try parsePrimitive([]const u8, "test"));
}

test "parseOptional" {
    const result1 = try parseOptional(u32, "42");
    try std.testing.expectEqual(@as(?u32, 42), result1);

    const result2 = try parseOptional(u32, null);
    try std.testing.expectEqual(@as(?u32, null), result2);
}

test "parseEagerStruct simple" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const xml =
        \\<person name="Alice" age="30"></person>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    // Skip to first element
    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const person = try parseEagerStruct(Person, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
}

test "parseEagerStruct nested" {
    const Address = struct {
        street: []const u8,
        city: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    const xml =
        \\<person name="Bob">
        \\  <address street="123 Main St" city="Springfield"></address>
        \\</person>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    // Skip to first element
    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const person = try parseEagerStruct(Person, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("Bob", person.name);
    try std.testing.expectEqualStrings("123 Main St", person.address.street);
    try std.testing.expectEqualStrings("Springfield", person.address.city);
}

test "default values - primitives" {
    const Config = struct {
        timeout: u32 = 30,
        retries: u32 = 3,
        debug: bool = false,
        host: []const u8,
    };

    const xml =
        \\<config host="localhost"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const config = try parseEagerStruct(Config, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u32, 30), config.timeout);
    try std.testing.expectEqual(@as(u32, 3), config.retries);
    try std.testing.expectEqual(false, config.debug);
}

test "default values - string literal" {
    const Config = struct {
        name: []const u8 = "default-name",
        port: u32 = 8080,
    };

    const xml =
        \\<config port="3000"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const config = try parseEagerStruct(Config, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("default-name", config.name);
    try std.testing.expectEqual(@as(u32, 3000), config.port);
}

test "default values - optional with default" {
    const Config = struct {
        timeout: ?u32 = 30,
        host: []const u8,
    };

    const xml =
        \\<config host="localhost"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const config = try parseEagerStruct(Config, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(?u32, 30), config.timeout);
}

test "default values - in lazy struct" {
    const Book = struct {
        title: []const u8,
    };

    const Library = struct {
        name: []const u8,
        established: u32 = 2000,
        books: Iterator("book", Book),
    };

    const xml =
        \\<library name="City Library">
        \\    <book title="1984"/>
        \\</library>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const library = try parseLazyStruct(Library, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("City Library", library.name);
    try std.testing.expectEqual(@as(u32, 2000), library.established);
}

test "custom type parser - parseXml" {
    const Timestamp = struct {
        seconds: i64,

        pub fn parseXml(text: []const u8) !@This() {
            // Simple parser: expect "ts-<seconds>"
            if (!std.mem.startsWith(u8, text, "ts-")) {
                return error.InvalidFormat;
            }
            const seconds_str = text[3..];
            const seconds = try std.fmt.parseInt(i64, seconds_str, 10);
            return .{ .seconds = seconds };
        }
    };

    const EventRecord = struct {
        name: []const u8,
        timestamp: Timestamp,
    };

    const xml =
        \\<event name="test" timestamp="ts-1234567890"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const result = try parseEagerStruct(EventRecord, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expectEqual(@as(i64, 1234567890), result.timestamp.seconds);
}

test "custom type parser - optional custom type" {
    const UserId = struct {
        id: u32,

        pub fn parseXml(text: []const u8) !@This() {
            // Parse "user-<id>"
            if (!std.mem.startsWith(u8, text, "user-")) {
                return error.InvalidFormat;
            }
            const id_str = text[5..];
            const id = try std.fmt.parseInt(u32, id_str, 10);
            return .{ .id = id };
        }
    };

    const Record = struct {
        name: []const u8,
        user_id: ?UserId,
    };

    const xml1 =
        \\<record name="test" user_id="user-123"/>
    ;

    var reader1 = std.Io.Reader.fixed(xml1);
    var parser1 = PullParser.initWithReader(std.testing.allocator, &reader1);
    defer parser1.deinit();

    var elem1: Event = undefined;
    while (try parser1.next()) |event| {
        if (event == .start_element) {
            elem1 = event;
            break;
        }
    }

    const result1 = try parseEagerStruct(Record, &parser1, elem1.start_element.attributes, elem1.start_element.name);

    try std.testing.expectEqualStrings("test", result1.name);
    try std.testing.expectEqual(@as(?u32, 123), if (result1.user_id) |uid| uid.id else null);

    // Test with missing optional
    const xml2 =
        \\<record name="test2"/>
    ;

    var reader2 = std.Io.Reader.fixed(xml2);
    var parser2 = PullParser.initWithReader(std.testing.allocator, &reader2);
    defer parser2.deinit();

    var elem2: Event = undefined;
    while (try parser2.next()) |event| {
        if (event == .start_element) {
            elem2 = event;
            break;
        }
    }

    const result2 = try parseEagerStruct(Record, &parser2, elem2.start_element.attributes, elem2.start_element.name);

    try std.testing.expectEqualStrings("test2", result2.name);
    try std.testing.expectEqual(@as(?UserId, null), result2.user_id);
}

test "custom type parser - error propagation" {
    const Validated = struct {
        value: u32,

        pub fn parseXml(text: []const u8) !@This() {
            const value = try std.fmt.parseInt(u32, text, 10);
            if (value > 100) {
                return error.ValueTooLarge;
            }
            return .{ .value = value };
        }
    };

    const Config = struct {
        validated: Validated,
    };

    const xml =
        \\<config validated="200"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const result = parseEagerStruct(Config, &parser, elem.start_element.attributes, elem.start_element.name);
    try std.testing.expectError(error.ValueTooLarge, result);
}

test "name mapping - struct fields" {
    const Book = struct {
        isbn: []const u8,
        max_score: u32,

        pub const xml_names = .{
            .isbn = "ISBN-13",
            .max_score = "max-score",
        };
    };

    const xml =
        \\<book ISBN-13="978-0451524935" max-score="100"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const book = try parseEagerStruct(Book, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("978-0451524935", book.isbn);
    try std.testing.expectEqual(@as(u32, 100), book.max_score);
}

test "name mapping - partial mapping" {
    const Config = struct {
        host: []const u8,
        port: u32,
        timeout: u32,

        pub const xml_names = .{
            .host = "server-host",
            // port and timeout use field names
        };
    };

    const xml =
        \\<config server-host="localhost" port="8080" timeout="30"/>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const config = try parseEagerStruct(Config, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u32, 8080), config.port);
    try std.testing.expectEqual(@as(u32, 30), config.timeout);
}

test "name mapping - child elements" {
    const Address = struct {
        street: []const u8,

        pub const xml_names = .{
            .street = "street-name",
        };
    };

    const Person = struct {
        name: []const u8,
        address: Address,

        pub const xml_names = .{
            .address = "home-address",
        };
    };

    const xml =
        \\<person name="Alice">
        \\    <home-address>
        \\        <street-name>123 Main St</street-name>
        \\    </home-address>
        \\</person>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const person = try parseEagerStruct(Person, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqualStrings("123 Main St", person.address.street);
}

test "name mapping - union variants" {
    const Book = struct {
        title: []const u8,
    };

    const Movie = struct {
        title: []const u8,
    };

    const MediaItem = union(enum) {
        book: Book,
        movie: Movie,

        pub const xml_names = .{
            .book = "book-item",
            .movie = "movie-item",
        };
    };

    const Collection = struct {
        name: []const u8,
        items: MultiIterator(MediaItem),
    };

    const xml =
        \\<collection name="MyCollection">
        \\    <book-item title="1984"/>
        \\    <movie-item title="Inception"/>
        \\</collection>
    ;

    var reader = std.Io.Reader.fixed(xml);
    var parser = PullParser.initWithReader(std.testing.allocator, &reader);
    defer parser.deinit();

    var elem: Event = undefined;
    while (try parser.next()) |event| {
        if (event == .start_element) {
            elem = event;
            break;
        }
    }

    const collection = try parseLazyStruct(Collection, &parser, elem.start_element.attributes, elem.start_element.name);

    try std.testing.expectEqualStrings("MyCollection", collection.name);

    // Check first item (book)
    const item1 = try collection.items.next();
    try std.testing.expect(item1 != null);
    try std.testing.expect(item1.? == .book);
    try std.testing.expectEqualStrings("1984", item1.?.book.title);

    // Check second item (movie)
    const item2 = try collection.items.next();
    try std.testing.expect(item2 != null);
    try std.testing.expect(item2.? == .movie);
    try std.testing.expectEqualStrings("Inception", item2.?.movie.title);

    // No more items
    const item3 = try collection.items.next();
    try std.testing.expect(item3 == null);
}
