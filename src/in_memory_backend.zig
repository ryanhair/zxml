const std = @import("std");
const testing = std.testing;
const StringStorage = @import("./string_storage.zig").StringStorage;

// Re-export shared types from streaming backend
pub const Event = @import("./streaming_backend.zig").Event;
pub const Attribute = @import("./streaming_backend.zig").Attribute;

/// Parser state for tracking context
pub const ParserState = enum {
    Initial,
    InDocument,
    InElement,
    InText,
    Complete,
    Error,
};

/// In-memory backend for event-based XML parsing
pub const InMemoryBackend = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    strings: StringStorage,
    pos: usize = 0,
    state: ParserState = .Initial,
    depth: u8 = 0,

    // Configuration - optimized for performance
    preserve_whitespace: bool = false,
    resolve_entities: bool = true,

    // Element stack for structure validation
    element_stack: [256][]const u8 = undefined,
    stack_size: u8 = 0,

    // Workspace for parsing attributes (increased for real-world XML)
    attr_workspace: [256]Attribute = undefined,

    // Entity definitions from DTD
    entities: std.StringHashMap([]const u8) = undefined,
    entities_initialized: bool = false,

    // Self-closing element tracking
    pending_end_element: ?[]const u8 = null,

    /// Initialize in-memory backend
    pub fn init(allocator: std.mem.Allocator, xml: []const u8) InMemoryBackend {
        return .{
            .allocator = allocator,
            .input = xml,
            .strings = StringStorage.init(allocator),
        };
    }

    /// Deinitialize the backend
    pub fn deinit(self: *InMemoryBackend) void {
        self.strings.deinit();
        if (self.entities_initialized) {
            self.entities.deinit();
        }
    }

    /// Initialize entity map (called lazily when first DTD is encountered)
    fn initEntities(self: *InMemoryBackend, allocator: std.mem.Allocator) !void {
        if (!self.entities_initialized) {
            self.entities = std.StringHashMap([]const u8).init(allocator);
            self.entities_initialized = true;
        }
    }

    /// Get next parsing event
    pub fn next(self: *InMemoryBackend) !?Event {
        // Check for pending self-closing end element first
        if (self.pending_end_element) |name| {
            self.pending_end_element = null;
            return Event{ .end_element = .{ .name = name } };
        }

        while (self.pos < self.input.len) {
            switch (self.state) {
                .Initial => {
                    self.state = .InDocument;
                    return Event.start_document;
                },
                .InDocument, .InElement => {
                    // Skip whitespace unless preserving
                    if (!self.preserve_whitespace) {
                        self.skipWhitespace();
                    }

                    if (self.pos >= self.input.len) {
                        if (self.state != .Complete) {
                            self.state = .Complete;
                            return Event.end_document;
                        }
                        return null;
                    }

                    if (self.input[self.pos] == '<') {
                        return try self.parseMarkup();
                    } else {
                        return try self.parseText();
                    }
                },
                .Complete => return null,
                .Error => return null,
                .InText => unreachable, // Handled in parseText
            }
        }

        // End of input
        if (self.state != .Complete) {
            self.state = .Complete;
            return Event.end_document;
        }

        return null;
    }

    /// Parse markup starting with '<'
    fn parseMarkup(self: *InMemoryBackend) !Event {
        if (self.pos + 1 >= self.input.len) {
            return error.UnexpectedEndOfInput;
        }

        switch (self.input[self.pos + 1]) {
            '/' => {
                // Closing tag
                return try self.parseEndElement();
            },
            '!' => {
                if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                    return try self.parseComment();
                } else if (std.mem.startsWith(u8, self.input[self.pos..], "<![CDATA[")) {
                    return try self.parseCDATA();
                } else if (std.mem.startsWith(u8, self.input[self.pos..], "<!DOCTYPE")) {
                    return try self.parseDoctype();
                } else {
                    return error.InvalidMarkup;
                }
            },
            '?' => {
                // Check for XML declaration specifically (must be "<?xml " or "<?xml?")
                if (self.pos + 5 < self.input.len and
                    std.mem.eql(u8, self.input[self.pos .. self.pos + 5], "<?xml") and
                    (self.input[self.pos + 5] == ' ' or self.input[self.pos + 5] == '\t' or
                        self.input[self.pos + 5] == '\r' or self.input[self.pos + 5] == '\n' or
                        self.input[self.pos + 5] == '?'))
                {
                    return try self.parseXmlDeclaration();
                } else {
                    return try self.parseProcessingInstruction();
                }
            },
            else => {
                // Opening tag
                return try self.parseStartElement();
            },
        }
    }

    /// Parse start element
    fn parseStartElement(self: *InMemoryBackend) !Event {
        self.pos += 1; // Skip '<'

        const name = try self.parseName();

        // Parse attributes
        const attrs = try self.parseAttributes();

        // Check for self-closing
        var self_closing = false;
        if (self.pos < self.input.len and self.input[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
        }

        // Expect '>'
        if (self.pos >= self.input.len or self.input[self.pos] != '>') {
            return error.ExpectedClosingBracket;
        }
        self.pos += 1;

        if (!self_closing) {
            self.depth += 1;
            self.state = .InElement;

            // Push element name onto stack for validation
            if (self.stack_size >= self.element_stack.len) {
                return error.TooManyNestedElements;
            }
            self.element_stack[self.stack_size] = name;
            self.stack_size += 1;
        }

        const start_event = Event{ .start_element = .{
            .name = name,
            .attributes = attrs,
        } };

        // For self-closing elements, schedule end event for next call
        if (self_closing) {
            self.pending_end_element = name;
        }

        return start_event;
    }

    /// Parse end element
    fn parseEndElement(self: *InMemoryBackend) !Event {
        self.pos += 2; // Skip '</'

        const name = try self.parseName();

        // Skip whitespace
        self.skipWhitespace();

        // Expect '>'
        if (self.pos >= self.input.len or self.input[self.pos] != '>') {
            return error.ExpectedClosingBracket;
        }
        self.pos += 1;

        // Validate structure: check that closing tag matches opening tag
        if (self.stack_size == 0) {
            return error.UnmatchedClosingTag;
        }

        const expected_name = self.element_stack[self.stack_size - 1];
        if (!std.mem.eql(u8, expected_name, name)) {
            return error.MismatchedTags;
        }

        // Pop from stack and update depth
        self.stack_size -= 1;
        if (self.depth > 0) {
            self.depth -= 1;
        }

        if (self.depth == 0) {
            self.state = .InDocument;
        }

        return Event{ .end_element = .{ .name = name } };
    }

    /// Parse attributes
    fn parseAttributes(self: *InMemoryBackend) ![]const Attribute {
        var attr_count: usize = 0;

        while (self.pos < self.input.len and
            self.input[self.pos] != '>' and
            self.input[self.pos] != '/')
        {

            // Skip whitespace
            self.skipWhitespace();

            if (self.pos >= self.input.len or
                self.input[self.pos] == '>' or
                self.input[self.pos] == '/')
            {
                break;
            }

            if (attr_count >= self.attr_workspace.len) {
                return error.TooManyAttributes;
            }

            // Parse attribute name
            const attr_name = try self.parseName();

            // Skip whitespace
            self.skipWhitespace();

            // Expect '='
            if (self.pos >= self.input.len or self.input[self.pos] != '=') {
                return error.ExpectedEquals;
            }
            self.pos += 1;

            // Skip whitespace
            self.skipWhitespace();

            // Parse attribute value
            if (self.pos >= self.input.len) {
                return error.ExpectedAttributeValue;
            }

            const quote = self.input[self.pos];
            if (quote != '"' and quote != '\'') {
                return error.ExpectedQuote;
            }
            self.pos += 1;

            const value_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                self.pos += 1;
            }

            if (self.pos >= self.input.len) {
                return error.UnterminatedAttributeValue;
            }

            const attr_value = self.input[value_start..self.pos];
            self.pos += 1; // Skip closing quote

            // Store or process attribute value (entity decoding if needed)
            const processed_value = if (self.resolve_entities and std.mem.indexOfScalar(u8, attr_value, '&') != null)
                try self.resolveEntities(attr_value)
            else
                attr_value;

            self.attr_workspace[attr_count] = .{
                .name = attr_name,
                .value = processed_value,
            };
            attr_count += 1;
        }

        return self.attr_workspace[0..attr_count];
    }

    /// Parse text content
    fn parseText(self: *InMemoryBackend) !Event {
        const text_start = self.pos;

        while (self.pos < self.input.len and self.input[self.pos] != '<') {
            self.pos += 1;
        }

        if (self.pos == text_start) {
            return error.EmptyText;
        }

        const raw_text = self.input[text_start..self.pos];

        // Check if it's all whitespace
        var all_whitespace = true;
        for (raw_text) |c| {
            if (!std.ascii.isWhitespace(c)) {
                all_whitespace = false;
                break;
            }
        }

        if (all_whitespace and !self.preserve_whitespace) {
            return Event{ .whitespace = raw_text };
        }

        // Process entities if needed
        const processed_text = if (self.resolve_entities and std.mem.indexOfScalar(u8, raw_text, '&') != null)
            try self.resolveEntities(raw_text)
        else
            raw_text;

        return Event{ .text = processed_text };
    }

    /// Parse comment
    fn parseComment(self: *InMemoryBackend) !Event {
        // Skip "<!--"
        self.pos += 4;

        // Find "-->"
        const start = self.pos;
        const end_pattern = "-->";
        const content_end = std.mem.indexOf(u8, self.input[self.pos..], end_pattern) orelse
            return error.UnterminatedComment;

        const comment_content = self.input[start .. self.pos + content_end];
        self.pos += content_end + 3; // Skip past "-->"

        return Event{ .comment = comment_content };
    }

    /// Parse CDATA
    fn parseCDATA(self: *InMemoryBackend) !Event {
        // Skip "<![CDATA["
        self.pos += 9;

        // Find "]]>"
        const start = self.pos;
        const end_pattern = "]]>";
        const content_end = std.mem.indexOf(u8, self.input[self.pos..], end_pattern) orelse
            return error.UnterminatedCDATA;

        const cdata_content = self.input[start .. self.pos + content_end];
        self.pos += content_end + 3; // Skip past "]]>"

        return Event{ .cdata = cdata_content };
    }

    /// Parse XML declaration
    fn parseXmlDeclaration(self: *InMemoryBackend) !Event {
        // Skip "<?xml"
        self.pos += 5;

        var version: []const u8 = "1.0";
        var encoding: ?[]const u8 = null;
        var standalone: ?bool = null;

        // Parse attributes until "?>"
        while (self.pos + 1 < self.input.len) {
            self.skipWhitespace();

            // Check for end of declaration
            if (self.pos + 1 < self.input.len and
                self.input[self.pos] == '?' and self.input[self.pos + 1] == '>')
            {
                self.pos += 2;
                break;
            }

            // Parse attribute name
            const attr_name = try self.parseName();
            self.skipWhitespace();

            // Expect '='
            if (self.pos >= self.input.len or self.input[self.pos] != '=') {
                return error.InvalidXmlDeclaration;
            }
            self.pos += 1;
            self.skipWhitespace();

            // Parse attribute value
            if (self.pos >= self.input.len) return error.InvalidXmlDeclaration;
            const quote = self.input[self.pos];
            if (quote != '"' and quote != '\'') return error.InvalidXmlDeclaration;
            self.pos += 1;

            const value_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                self.pos += 1;
            }
            if (self.pos >= self.input.len) return error.InvalidXmlDeclaration;
            const attr_value = self.input[value_start..self.pos];
            self.pos += 1; // Skip closing quote

            // Assign to appropriate field
            if (std.mem.eql(u8, attr_name, "version")) {
                version = attr_value;
            } else if (std.mem.eql(u8, attr_name, "encoding")) {
                encoding = attr_value;
            } else if (std.mem.eql(u8, attr_name, "standalone")) {
                standalone = std.mem.eql(u8, attr_value, "yes");
            }
        }

        return Event{ .xml_declaration = .{
            .version = version,
            .encoding = encoding,
            .standalone = standalone,
        } };
    }

    /// Parse processing instruction
    fn parseProcessingInstruction(self: *InMemoryBackend) !Event {
        // Skip "<?"
        self.pos += 2;

        // Parse target name
        const target = try self.parseName();
        self.skipWhitespace();

        // Find "?>"
        const data_start = self.pos;
        const end_pattern = "?>";
        const data_end = std.mem.indexOf(u8, self.input[self.pos..], end_pattern) orelse
            return error.UnterminatedProcessingInstruction;

        const data = self.input[data_start .. self.pos + data_end];
        self.pos += data_end + 2; // Skip past "?>"

        return Event{ .processing_instruction = .{
            .target = target,
            .data = data,
        } };
    }

    /// Parse DOCTYPE (simplified)
    fn parseDoctype(self: *InMemoryBackend) !Event {
        // <!DOCTYPE name SYSTEM "system_id" PUBLIC "public_id">
        var pos = self.pos;

        // Skip <!DOCTYPE
        if (!std.mem.startsWith(u8, self.input[pos..], "<!DOCTYPE")) {
            return error.InvalidDoctype;
        }
        pos += 9; // length of "<!DOCTYPE"

        // Skip whitespace
        while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
            pos += 1;
        }

        // Get DOCTYPE name
        const saved_pos = self.pos;
        self.pos = pos;
        const name = self.parseName() catch {
            self.pos = saved_pos;
            return error.InvalidDoctype;
        };
        pos = self.pos;
        self.pos = saved_pos;

        // Look for SYSTEM or PUBLIC
        var system_id: ?[]const u8 = null;
        var public_id: ?[]const u8 = null;

        while (pos < self.input.len and self.input[pos] != '>' and self.input[pos] != '[') {
            // Skip whitespace
            while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                pos += 1;
            }

            if (std.mem.startsWith(u8, self.input[pos..], "SYSTEM")) {
                pos += 6;
                // Skip whitespace and find quoted string
                while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                    pos += 1;
                }
                if (pos < self.input.len and (self.input[pos] == '"' or self.input[pos] == '\'')) {
                    const quote = self.input[pos];
                    pos += 1;
                    const start = pos;
                    while (pos < self.input.len and self.input[pos] != quote) {
                        pos += 1;
                    }
                    system_id = self.input[start..pos];
                    if (pos < self.input.len) pos += 1; // Skip closing quote
                }
            } else if (std.mem.startsWith(u8, self.input[pos..], "PUBLIC")) {
                pos += 6;
                // Skip whitespace and find first quoted string (public ID)
                while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                    pos += 1;
                }
                if (pos < self.input.len and (self.input[pos] == '"' or self.input[pos] == '\'')) {
                    const quote = self.input[pos];
                    pos += 1;
                    const start = pos;
                    while (pos < self.input.len and self.input[pos] != quote) {
                        pos += 1;
                    }
                    public_id = self.input[start..pos];
                    if (pos < self.input.len) pos += 1; // Skip closing quote

                    // Skip whitespace and find second quoted string (system ID)
                    while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                        pos += 1;
                    }
                    if (pos < self.input.len and (self.input[pos] == '"' or self.input[pos] == '\'')) {
                        const quote2 = self.input[pos];
                        pos += 1;
                        const start2 = pos;
                        while (pos < self.input.len and self.input[pos] != quote2) {
                            pos += 1;
                        }
                        system_id = self.input[start2..pos];
                        if (pos < self.input.len) pos += 1; // Skip closing quote
                    }
                }
            } else {
                break;
            }
        }

        // Handle internal DTD subset
        if (pos < self.input.len and self.input[pos] == '[') {
            // Parse internal DTD subset to extract entity declarations
            pos += 1; // Skip '['
            try self.initEntities(self.allocator);
            try self.parseInternalDTD(pos, &pos);
        }

        // Skip to closing >
        while (pos < self.input.len and self.input[pos] != '>') {
            pos += 1;
        }
        if (pos < self.input.len and self.input[pos] == '>') {
            pos += 1;
        }

        self.pos = pos;

        // For in-memory backend, strings are already in the input buffer
        // so we can return them directly (no need to store)
        return Event{ .doctype = .{
            .name = name,
            .system_id = system_id,
            .public_id = public_id,
        } };
    }

    /// Parse internal DTD subset to extract entity declarations
    fn parseInternalDTD(self: *InMemoryBackend, start_pos: usize, end_pos: *usize) !void {
        var pos = start_pos;
        var depth: u32 = 1;

        while (pos < self.input.len and depth > 0) {
            if (self.input[pos] == '[') {
                depth += 1;
                pos += 1;
            } else if (self.input[pos] == ']') {
                depth -= 1;
                pos += 1;
            } else if (depth == 1 and std.mem.startsWith(u8, self.input[pos..], "<!ENTITY")) {
                // Parse entity declaration: <!ENTITY name "value">
                pos += 8; // Skip "<!ENTITY"

                // Skip whitespace
                while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                    pos += 1;
                }

                // Get entity name
                const name_start = pos;
                while (pos < self.input.len and !std.ascii.isWhitespace(self.input[pos]) and self.input[pos] != '"' and self.input[pos] != '\'') {
                    pos += 1;
                }
                const entity_name = self.input[name_start..pos];

                // Skip whitespace
                while (pos < self.input.len and std.ascii.isWhitespace(self.input[pos])) {
                    pos += 1;
                }

                // Parse entity value (quoted string)
                if (pos < self.input.len and (self.input[pos] == '"' or self.input[pos] == '\'')) {
                    const quote = self.input[pos];
                    pos += 1;
                    const value_start = pos;
                    while (pos < self.input.len and self.input[pos] != quote) {
                        pos += 1;
                    }
                    const entity_value = self.input[value_start..pos];

                    if (pos < self.input.len) pos += 1; // Skip closing quote

                    // For in-memory backend, entity names/values are already in input buffer
                    try self.entities.put(entity_name, entity_value);
                }

                // Skip to end of declaration
                while (pos < self.input.len and self.input[pos] != '>') {
                    pos += 1;
                }
                if (pos < self.input.len) pos += 1; // Skip '>'
            } else {
                pos += 1;
            }
        }

        end_pos.* = pos;
    }

    /// Resolve text with DTD entities, then fall back to built-in entity resolution
    fn resolveEntities(self: *InMemoryBackend, text: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '&') == null) {
            return text;
        }

        // If we have DTD entities, manually resolve them first
        if (self.entities_initialized) {
            var resolved = std.ArrayList(u8){};
            defer resolved.deinit(self.allocator);

            var i: usize = 0;
            while (i < text.len) {
                if (text[i] == '&') {
                    // Find the entity end
                    const entity_start = i + 1;
                    const entity_end = std.mem.indexOfScalarPos(u8, text, entity_start, ';') orelse {
                        // No semicolon found, treat as literal
                        try resolved.append(self.allocator, text[i]);
                        i += 1;
                        continue;
                    };

                    const entity_name = text[entity_start..entity_end];

                    // Check DTD entities first
                    if (self.entities.get(entity_name)) |entity_value| {
                        // Safety check: ensure entity_value is valid and within input bounds
                        if (entity_value.len > 0) {
                            const entity_start_ptr = @intFromPtr(entity_value.ptr);
                            const input_start_ptr = @intFromPtr(self.input.ptr);
                            const input_end_ptr = input_start_ptr + self.input.len;

                            if (entity_start_ptr >= input_start_ptr and
                                entity_start_ptr + entity_value.len <= input_end_ptr)
                            {
                                try resolved.appendSlice(self.allocator, entity_value);
                                i = entity_end + 1; // Skip past ';'
                                continue;
                            }
                        }
                        // If entity value is invalid, treat as unresolved entity
                        try resolved.append(self.allocator, '&');
                        try resolved.appendSlice(self.allocator, entity_name);
                        try resolved.append(self.allocator, ';');
                        i = entity_end + 1;
                        continue;
                    }

                    // Fall back to built-in entities
                    if (std.mem.eql(u8, entity_name, "lt")) {
                        try resolved.append(self.allocator, '<');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "gt")) {
                        try resolved.append(self.allocator, '>');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "amp")) {
                        try resolved.append(self.allocator, '&');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "quot")) {
                        try resolved.append(self.allocator, '"');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "apos")) {
                        try resolved.append(self.allocator, '\'');
                        i = entity_end + 1;
                        continue;
                    }

                    // Handle numeric character references
                    if (entity_name.len > 1 and entity_name[0] == '#') {
                        const codepoint = if (entity_name[1] == 'x' or entity_name[1] == 'X')
                            std.fmt.parseInt(u21, entity_name[2..], 16) catch {
                                // Invalid, keep as literal
                                try resolved.appendSlice(self.allocator, text[i .. entity_end + 1]);
                                i = entity_end + 1;
                                continue;
                            }
                        else
                            std.fmt.parseInt(u21, entity_name[1..], 10) catch {
                                // Invalid, keep as literal
                                try resolved.appendSlice(self.allocator, text[i .. entity_end + 1]);
                                i = entity_end + 1;
                                continue;
                            };

                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            // Invalid codepoint, keep as literal
                            try resolved.appendSlice(self.allocator, text[i .. entity_end + 1]);
                            i = entity_end + 1;
                            continue;
                        };
                        try resolved.appendSlice(self.allocator, buf[0..len]);
                        i = entity_end + 1;
                        continue;
                    }

                    // Unknown entity, keep as literal
                    try resolved.appendSlice(self.allocator, text[i .. entity_end + 1]);
                    i = entity_end + 1;
                } else {
                    try resolved.append(self.allocator, text[i]);
                    i += 1;
                }
            }

            // Store the resolved text and return it
            return try self.strings.store(resolved.items);
        }

        // No DTD entities, use StringStorage's built-in entity resolution
        return try self.strings.store(text);
    }

    /// Check if a character is a valid XML NameStartChar
    /// NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] |
    ///                   [#x370-#x37D] | [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] |
    ///                   [#x2C00-#x2FEF] | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD] |
    ///                   [#x10000-#xEFFFF]
    /// Parse an XML name with fast-path for ASCII names
    /// Most XML names are simple ASCII, so we optimize for that case
    fn parseName(self: *InMemoryBackend) ![]const u8 {
        const start = self.pos;

        if (self.pos >= self.input.len) {
            return error.InvalidElementName;
        }

        // Fast path: Check first character
        const first_byte = self.input[self.pos];

        // Common ASCII name start characters
        if ((first_byte >= 'a' and first_byte <= 'z') or
            (first_byte >= 'A' and first_byte <= 'Z') or
            first_byte == '_')
        {
            self.pos += 1;
        } else if (first_byte == ':') {
            // Colon is valid but less common
            self.pos += 1;
        } else if (first_byte >= 128) {
            // Non-ASCII, need full validation
            return self.parseNameWithValidation(start);
        } else {
            // Invalid ASCII character
            return error.InvalidElementName;
        }

        // Fast path: Scan rest of name
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];

            // Common ASCII name characters (most frequent first)
            if ((byte >= 'a' and byte <= 'z') or
                (byte >= 'A' and byte <= 'Z') or
                (byte >= '0' and byte <= '9') or
                byte == '-' or byte == '_' or byte == '.')
            {
                self.pos += 1;
                continue;
            }

            // Delimiter - end of name
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
                byte == '>' or byte == '/' or byte == '=')
            {
                break;
            }

            // Colon is valid but less common
            if (byte == ':') {
                self.pos += 1;
                continue;
            }

            // Non-ASCII or invalid character
            if (byte >= 128) {
                // Switch to full validation for the rest
                return self.parseNameWithValidation(start);
            }

            // Invalid ASCII character
            return error.InvalidElementName;
        }

        if (self.pos == start) {
            return error.InvalidElementName;
        }

        return self.input[start..self.pos];
    }

    /// Parse name assuming well-formed input (fast path)
    fn parseNameWithValidation(self: *InMemoryBackend, name_start: usize) ![]const u8 {
        // Fast path: assume well-formed input, just scan to delimiters
        self.pos = name_start;

        // Basic safety: don't read past end
        if (self.pos >= self.input.len) {
            return error.InvalidElementName;
        }

        // Fast scan until we hit a delimiter
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];

            // Stop at common XML delimiters
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
                byte == '>' or byte == '/' or byte == '=' or byte == '<')
            {
                break;
            }

            self.pos += 1;
        }

        if (self.pos == name_start) {
            return error.InvalidElementName;
        }

        return self.input[name_start..self.pos];
    }

    // Removed Unicode validation functions - assume well-formed input for performance

    /// Skip whitespace characters
    fn skipWhitespace(self: *InMemoryBackend) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    /// Get current parser position
    pub fn getPosition(self: *const InMemoryBackend) usize {
        return self.pos;
    }

    /// Get parser state
    pub fn getState(self: *const InMemoryBackend) ParserState {
        return self.state;
    }

    /// Get current depth
    pub fn getDepth(self: *const InMemoryBackend) u8 {
        return self.depth;
    }
};

