const std = @import("std");
const testing = std.testing;
const StringStorage = @import("./string_storage.zig").StringStorage;

/// XML parsing events for pull-style parsing
pub const Event = union(enum) {
    /// Document start
    start_document,

    /// Document end
    end_document,

    /// Start of an element with name and attributes
    start_element: struct {
        name: []const u8,
        attributes: []const Attribute,
    },

    /// End of an element
    end_element: struct {
        name: []const u8,
    },

    /// Text content (entity-decoded)
    text: []const u8,

    /// Comment content
    comment: []const u8,

    /// CDATA content (raw)
    cdata: []const u8,

    /// Processing instruction
    processing_instruction: struct {
        target: []const u8,
        data: []const u8,
    },

    /// XML declaration
    xml_declaration: struct {
        version: []const u8,
        encoding: ?[]const u8,
        standalone: ?bool,
    },

    /// DOCTYPE declaration (simplified)
    doctype: struct {
        name: []const u8,
        system_id: ?[]const u8,
        public_id: ?[]const u8,
    },

    /// Whitespace (if preserved)
    whitespace: []const u8,
};

/// Attribute name-value pair
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// Stack entry for element hierarchy tracking
const StackEntry = struct {
    name: []const u8,
    attr_start: usize, // Index in attr_workspace where this element's attributes start
    attr_count: usize, // Number of attributes for this element
    buffer_mark: usize, // Position in string buffer to reset to on pop
};

/// Parser state for tracking context
pub const ParserState = enum {
    Initial,
    InDocument,
    InElement,
    InText,
    Complete,
    Error,
};

/// Streaming backend for event-based XML parsing using Reader API
pub const StreamingBackend = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    strings: StringStorage,

    state: ParserState = .Initial,
    depth: u8 = 0,

    // Configuration - optimized for performance
    preserve_whitespace: bool = false,
    resolve_entities: bool = true,

    // Element stack for structure validation and data lifetime
    element_stack: [256]StackEntry = undefined,
    stack_size: u8 = 0,

    // Attribute workspace (managed like a stack)
    attr_workspace: [256]Attribute = undefined,
    total_attr_count: usize = 0,

    // Entity definitions from DTD
    entities: std.StringHashMap([]const u8) = undefined,
    entities_initialized: bool = false,

    // Self-closing element tracking
    pending_end_element: ?[]const u8 = null,
    pending_attr_start: usize = 0,

    /// Initialize streaming backend with a Reader (caller owns the buffer passed to reader)
    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) StreamingBackend {
        return .{
            .allocator = allocator,
            .reader = reader,
            .strings = StringStorage.init(allocator),
        };
    }

    /// Initialize entity map (called lazily when first DTD is encountered)
    fn initEntities(self: *StreamingBackend, allocator: std.mem.Allocator) !void {
        if (!self.entities_initialized) {
            self.entities = std.StringHashMap([]const u8).init(allocator);
            self.entities_initialized = true;
        }
    }

    /// Deinitialize parser
    pub fn deinit(self: *StreamingBackend) void {
        self.strings.deinit();
        if (self.entities_initialized) {
            self.entities.deinit();
        }
    }

    /// Get next parsing event
    pub fn next(self: *StreamingBackend) !?Event {
        // Check for pending self-closing end element first
        if (self.pending_end_element) |name| {
            self.pending_end_element = null;
            self.total_attr_count = self.pending_attr_start;
            return Event{ .end_element = .{ .name = name } };
        }

        while (true) {
            switch (self.state) {
                .Initial => {
                    self.state = .InDocument;
                    return Event.start_document;
                },
                .InDocument, .InElement => {
                    // Skip whitespace unless preserving
                    if (!self.preserve_whitespace) {
                        self.skipWhitespace() catch |err| switch (err) {
                            error.EndOfStream => {
                                if (self.state != .Complete) {
                                    self.state = .Complete;
                                    return Event.end_document;
                                }
                                return null;
                            },
                            else => return err,
                        };
                    }

                    // Peek at next byte to decide what to parse
                    const byte = self.reader.peekByte() catch |err| switch (err) {
                        error.EndOfStream => {
                            if (self.state != .Complete) {
                                self.state = .Complete;
                                return Event.end_document;
                            }
                            return null;
                        },
                        else => return err,
                    };

                    if (byte == '<') {
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
    }

    /// Parse markup starting with '<'
    fn parseMarkup(self: *StreamingBackend) !Event {
        // Peek at least 2 bytes to determine markup type
        const lookahead = try self.reader.peek(2);
        if (lookahead.len < 2) {
            return error.UnexpectedEndOfInput;
        }

        switch (lookahead[1]) {
            '/' => {
                // Closing tag
                return try self.parseEndElement();
            },
            '!' => {
                // Need more lookahead to distinguish <!--, <![CDATA[, <!DOCTYPE
                const longer = try self.reader.peek(9);
                if (std.mem.startsWith(u8, longer, "<!--")) {
                    return try self.parseComment();
                } else if (std.mem.startsWith(u8, longer, "<![CDATA[")) {
                    return try self.parseCDATA();
                } else if (std.mem.startsWith(u8, longer, "<!DOCTYPE")) {
                    return try self.parseDoctype();
                } else {
                    return error.InvalidMarkup;
                }
            },
            '?' => {
                // Check for XML declaration specifically (must be "<?xml " or "<?xml?")
                const longer = try self.reader.peek(6);
                if (longer.len >= 5 and
                    std.mem.eql(u8, longer[0..5], "<?xml") and
                    (longer[5] == ' ' or longer[5] == '\t' or
                        longer[5] == '\r' or longer[5] == '\n' or
                        longer[5] == '?'))
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
    fn parseStartElement(self: *StreamingBackend) !Event {
        _ = try self.reader.takeByte(); // Skip '<'

        // Mark buffer position before storing anything for this element
        const buffer_mark = self.strings.mark();
        const attr_start = self.total_attr_count;

        const name = try self.parseName();

        // Parse attributes
        const attrs = try self.parseAttributes();
        const attr_count = self.total_attr_count - attr_start;

        // Check for self-closing
        var self_closing = false;
        const byte = try self.reader.peekByte();
        if (byte == '/') {
            self_closing = true;
            self.reader.toss(1);
        }

        // Expect '>'
        const closing = try self.reader.takeByte();
        if (closing != '>') {
            return error.ExpectedClosingBracket;
        }

        if (!self_closing) {
            self.depth += 1;
            self.state = .InElement;

            // Push element entry onto stack
            if (self.stack_size >= self.element_stack.len) {
                return error.TooManyNestedElements;
            }
            self.element_stack[self.stack_size] = .{
                .name = name,
                .attr_start = attr_start,
                .attr_count = attr_count,
                .buffer_mark = buffer_mark,
            };
            self.stack_size += 1;
        }

        const start_event = Event{ .start_element = .{
            .name = name,
            .attributes = attrs,
        } };

        // For self-closing elements, schedule end event for next call
        if (self_closing) {
            self.pending_end_element = name;
            self.pending_attr_start = attr_start;
        }

        return start_event;
    }

    /// Parse end element
    fn parseEndElement(self: *StreamingBackend) !Event {
        self.reader.toss(2); // Skip '</'

        // Validate structure: check that closing tag matches opening tag
        if (self.stack_size == 0) {
            return error.UnmatchedClosingTag;
        }

        const entry = self.element_stack[self.stack_size - 1];

        // Parse and validate name matches without storing
        try self.parseNameAndValidate(entry.name);

        // Skip whitespace
        try self.skipWhitespace();

        // Expect '>'
        const closing = try self.reader.takeByte();
        if (closing != '>') {
            return error.ExpectedClosingBracket;
        }

        // Pop from stack, reset attribute count and buffer position
        const element_name = entry.name; // Save before popping
        self.stack_size -= 1;
        self.total_attr_count = entry.attr_start;
        self.strings.resetToMark(entry.buffer_mark);

        if (self.depth > 0) {
            self.depth -= 1;
        }

        if (self.depth == 0) {
            self.state = .InDocument;
        }

        return Event{ .end_element = .{ .name = element_name } };
    }

    /// Parse attributes
    fn parseAttributes(self: *StreamingBackend) ![]const Attribute {
        const attr_start = self.total_attr_count;

        while (true) {
            // Skip whitespace
            try self.skipWhitespace();

            // Check what's next
            const byte = try self.reader.peekByte();
            if (byte == '>' or byte == '/') {
                break;
            }

            if (self.total_attr_count >= self.attr_workspace.len) {
                return error.TooManyAttributes;
            }

            // Parse attribute name
            const attr_name = try self.parseName();

            // Skip whitespace
            try self.skipWhitespace();

            // Expect '='
            const equals = try self.reader.takeByte();
            if (equals != '=') {
                return error.ExpectedEquals;
            }

            // Skip whitespace
            try self.skipWhitespace();

            // Parse attribute value
            const quote = try self.reader.takeByte();
            if (quote != '"' and quote != '\'') {
                return error.ExpectedQuote;
            }

            // Read until closing quote
            const attr_value = try self.takeUntilByte(quote);
            _ = try self.reader.takeByte(); // Skip closing quote

            // Store or process attribute value (entity decoding if needed)
            const processed_value = if (self.resolve_entities and std.mem.indexOfScalar(u8, attr_value, '&') != null)
                try self.resolveEntities(attr_value)
            else
                try self.strings.store(attr_value);

            self.attr_workspace[self.total_attr_count] = .{
                .name = attr_name,
                .value = processed_value,
            };
            self.total_attr_count += 1;
        }

        return self.attr_workspace[attr_start..self.total_attr_count];
    }

    /// Parse text content
    fn parseText(self: *StreamingBackend) !Event {
        // Read until '<'
        const raw_text = try self.takeUntilByte('<');

        if (raw_text.len == 0) {
            return error.EmptyText;
        }

        // Check if it's all whitespace
        var all_whitespace = true;
        for (raw_text) |c| {
            if (!std.ascii.isWhitespace(c)) {
                all_whitespace = false;
                break;
            }
        }

        // Store the text (either as-is or after entity resolution)
        const stored_text = if (self.resolve_entities and std.mem.indexOfScalar(u8, raw_text, '&') != null)
            try self.resolveEntities(raw_text)
        else
            try self.strings.store(raw_text);

        if (all_whitespace and !self.preserve_whitespace) {
            return Event{ .whitespace = stored_text };
        }

        return Event{ .text = stored_text };
    }

    /// Parse comment
    fn parseComment(self: *StreamingBackend) !Event {
        // Skip "<!--"
        self.reader.toss(4);

        // Find "-->"
        const comment_content = try self.takeUntilPattern("-->");
        self.reader.toss(3); // Skip "-->"

        const stored = try self.strings.store(comment_content);
        return Event{ .comment = stored };
    }

    /// Parse CDATA
    fn parseCDATA(self: *StreamingBackend) !Event {
        // Skip "<![CDATA["
        self.reader.toss(9);

        // Find "]]>"
        const cdata_content = try self.takeUntilPattern("]]>");
        self.reader.toss(3); // Skip "]]>"

        const stored = try self.strings.store(cdata_content);
        return Event{ .cdata = stored };
    }

    /// Parse XML declaration
    fn parseXmlDeclaration(self: *StreamingBackend) !Event {
        // Skip "<?xml"
        self.reader.toss(5);

        var version: []const u8 = "1.0";
        var encoding: ?[]const u8 = null;
        var standalone: ?bool = null;

        // Parse attributes until "?>"
        while (true) {
            try self.skipWhitespace();

            // Check for end of declaration
            const lookahead = try self.reader.peek(2);
            if (std.mem.startsWith(u8, lookahead, "?>")) {
                self.reader.toss(2);
                break;
            }

            // Parse attribute name
            const attr_name = try self.parseName();
            try self.skipWhitespace();

            // Expect '='
            const equals = try self.reader.takeByte();
            if (equals != '=') return error.InvalidXmlDeclaration;

            try self.skipWhitespace();

            // Parse attribute value
            const quote = try self.reader.takeByte();
            if (quote != '"' and quote != '\'') return error.InvalidXmlDeclaration;

            const attr_value = try self.takeUntilByte(quote);
            _ = try self.reader.takeByte(); // Skip closing quote

            const stored_value = try self.strings.store(attr_value);

            // Assign to appropriate field
            if (std.mem.eql(u8, attr_name, "version")) {
                version = stored_value;
            } else if (std.mem.eql(u8, attr_name, "encoding")) {
                encoding = stored_value;
            } else if (std.mem.eql(u8, attr_name, "standalone")) {
                standalone = std.mem.eql(u8, stored_value, "yes");
            }
        }

        return Event{ .xml_declaration = .{
            .version = version,
            .encoding = encoding,
            .standalone = standalone,
        } };
    }

    /// Parse processing instruction
    fn parseProcessingInstruction(self: *StreamingBackend) !Event {
        // Skip "<?"
        self.reader.toss(2);

        // Parse target name (already stored by parseName)
        const target = try self.parseName();

        try self.skipWhitespace();

        // Find "?>"
        const data = try self.takeUntilPattern("?>");
        self.reader.toss(2); // Skip "?>"

        const stored_data = try self.strings.store(data);

        return Event{ .processing_instruction = .{
            .target = target,
            .data = stored_data,
        } };
    }

    /// Parse DOCTYPE (simplified)
    fn parseDoctype(self: *StreamingBackend) !Event {
        // Skip "<!DOCTYPE"
        self.reader.toss(9);

        try self.skipWhitespace();

        // Get DOCTYPE name
        const name = try self.parseName();

        // Look for SYSTEM or PUBLIC
        var system_id: ?[]const u8 = null;
        var public_id: ?[]const u8 = null;

        while (true) {
            try self.skipWhitespace();

            const byte = self.reader.peekByte() catch break;
            if (byte == '>' or byte == '[') break;

            // Check for SYSTEM or PUBLIC
            const lookahead = try self.reader.peek(6);
            if (std.mem.startsWith(u8, lookahead, "SYSTEM")) {
                self.reader.toss(6);
                try self.skipWhitespace();

                const quote = try self.reader.takeByte();
                if (quote == '"' or quote == '\'') {
                    system_id = try self.takeUntilByte(quote);
                    _ = try self.reader.takeByte(); // Skip closing quote
                }
            } else if (std.mem.startsWith(u8, lookahead, "PUBLIC")) {
                self.reader.toss(6);
                try self.skipWhitespace();

                // First quoted string (public ID)
                const quote1 = try self.reader.takeByte();
                if (quote1 == '"' or quote1 == '\'') {
                    public_id = try self.takeUntilByte(quote1);
                    _ = try self.reader.takeByte(); // Skip closing quote

                    try self.skipWhitespace();

                    // Second quoted string (system ID)
                    const quote2 = try self.reader.takeByte();
                    if (quote2 == '"' or quote2 == '\'') {
                        system_id = try self.takeUntilByte(quote2);
                        _ = try self.reader.takeByte(); // Skip closing quote
                    }
                }
            } else {
                break;
            }
        }

        // Handle internal DTD subset
        const byte = self.reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => return error.UnterminatedDoctype,
            else => return err,
        };

        if (byte == '[') {
            self.reader.toss(1); // Skip '['
            try self.initEntities(self.allocator);
            try self.parseInternalDTD();
        }

        // Skip to closing >
        _ = try self.takeUntilByte('>');
        _ = try self.reader.takeByte(); // Skip '>'

        // Store system_id and public_id if they exist (name already stored by parseName)
        const system_str = if (system_id) |s|
            try self.strings.store(s)
        else
            null;

        const public_str = if (public_id) |p|
            try self.strings.store(p)
        else
            null;

        return Event{ .doctype = .{
            .name = name,
            .system_id = system_str,
            .public_id = public_str,
        } };
    }

    /// Parse internal DTD subset to extract entity declarations
    fn parseInternalDTD(self: *StreamingBackend) !void {
        var depth: u32 = 1;

        while (depth > 0) {
            const byte = try self.reader.takeByte();

            if (byte == '[') {
                depth += 1;
            } else if (byte == ']') {
                depth -= 1;
            } else if (byte == '<' and depth == 1) {
                // Check if this is <!ENTITY
                const lookahead = try self.reader.peek(7);
                if (std.mem.startsWith(u8, lookahead, "!ENTITY")) {
                    self.reader.toss(7); // Skip "!ENTITY"

                    try self.skipWhitespace();

                    // Get entity name
                    const entity_name = try self.parseName();

                    try self.skipWhitespace();

                    // Parse entity value (quoted string)
                    const quote = try self.reader.takeByte();
                    if (quote == '"' or quote == '\'') {
                        const entity_value = try self.takeUntilByte(quote);
                        _ = try self.reader.takeByte(); // Skip closing quote

                        // Store entity value (entity_name already stored by parseName)
                        const stored_value = try self.strings.store(entity_value);
                        try self.entities.put(entity_name, stored_value);
                    }

                    // Skip to end of declaration
                    _ = try self.takeUntilByte('>');
                    _ = try self.reader.takeByte(); // Skip '>'
                }
            }
        }
    }

    /// Resolve text with DTD entities, then fall back to built-in entity resolution
    fn resolveEntities(self: *StreamingBackend, text: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '&') == null) {
            return try self.strings.store(text);
        }

        // If we have DTD entities, manually resolve them first
        if (self.entities_initialized) {
            var resolved = std.ArrayList(u8){};
            defer resolved.deinit(self.strings.allocator);

            var i: usize = 0;
            while (i < text.len) {
                if (text[i] == '&') {
                    // Find the entity end
                    const entity_start = i + 1;
                    const entity_end = std.mem.indexOfScalarPos(u8, text, entity_start, ';') orelse {
                        // No semicolon found, treat as literal
                        try resolved.append(self.strings.allocator, text[i]);
                        i += 1;
                        continue;
                    };

                    const entity_name = text[entity_start..entity_end];

                    // Check DTD entities first
                    if (self.entities.get(entity_name)) |entity_value| {
                        if (entity_value.len > 0) {
                            try resolved.appendSlice(self.strings.allocator, entity_value);
                            i = entity_end + 1; // Skip past ';'
                            continue;
                        }
                    }

                    // Fall back to built-in entities
                    if (std.mem.eql(u8, entity_name, "lt")) {
                        try resolved.append(self.strings.allocator, '<');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "gt")) {
                        try resolved.append(self.strings.allocator, '>');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "amp")) {
                        try resolved.append(self.strings.allocator, '&');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "quot")) {
                        try resolved.append(self.strings.allocator, '"');
                        i = entity_end + 1;
                        continue;
                    } else if (std.mem.eql(u8, entity_name, "apos")) {
                        try resolved.append(self.strings.allocator, '\'');
                        i = entity_end + 1;
                        continue;
                    }

                    // Handle numeric character references
                    if (entity_name.len > 1 and entity_name[0] == '#') {
                        const codepoint = if (entity_name[1] == 'x' or entity_name[1] == 'X')
                            std.fmt.parseInt(u21, entity_name[2..], 16) catch {
                                // Invalid, keep as literal
                                try resolved.appendSlice(self.strings.allocator, text[i .. entity_end + 1]);
                                i = entity_end + 1;
                                continue;
                            }
                        else
                            std.fmt.parseInt(u21, entity_name[1..], 10) catch {
                                // Invalid, keep as literal
                                try resolved.appendSlice(self.strings.allocator, text[i .. entity_end + 1]);
                                i = entity_end + 1;
                                continue;
                            };

                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            // Invalid codepoint, keep as literal
                            try resolved.appendSlice(self.strings.allocator, text[i .. entity_end + 1]);
                            i = entity_end + 1;
                            continue;
                        };
                        try resolved.appendSlice(self.strings.allocator, buf[0..len]);
                        i = entity_end + 1;
                        continue;
                    }

                    // Unknown entity, keep as literal
                    try resolved.appendSlice(self.strings.allocator, text[i .. entity_end + 1]);
                    i = entity_end + 1;
                } else {
                    try resolved.append(self.strings.allocator, text[i]);
                    i += 1;
                }
            }

            // Store the resolved text and return it
            const ref = try self.strings.store(resolved.items);
            return self.strings.getString(ref);
        }

        // No DTD entities, fall back to normal string storage entity resolution
        const ref = try self.strings.store(text);
        return self.strings.getString(ref);
    }

    /// Check if a character is a valid XML NameStartChar
    /// NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] |
    ///                   [#x370-#x37D] | [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] |
    ///                   [#x2C00-#x2FEF] | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD] |
    ///                   [#x10000-#xEFFFF]
    /// Parse an XML name with fast-path for ASCII names
    /// Most XML names are simple ASCII, so we optimize for that case
    fn parseName(self: *StreamingBackend) ![]const u8 {
        // Fast path: peek a reasonable chunk for typical names
        const initial_chunk_size = 64;
        const chunk = self.reader.peek(initial_chunk_size) catch |err| switch (err) {
            error.EndOfStream => blk: {
                // Try to get at least 1 byte
                const partial = self.reader.peek(1) catch |e| switch (e) {
                    error.EndOfStream => return error.InvalidElementName,
                    else => return e,
                };
                break :blk partial;
            },
            else => return err,
        };

        // Scan for delimiter in the chunk
        var len: usize = 0;
        while (len < chunk.len) : (len += 1) {
            const byte = chunk[len];
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
                byte == '>' or byte == '/' or byte == '=' or byte == '<')
            {
                break;
            }
        }

        // If we scanned the whole chunk without finding delimiter, continue looking
        // This happens either when name is long OR when chunk is small (end of buffer)
        if (len == chunk.len) {
            // Try to get more data to find the delimiter
            while (true) {
                const buffered = try self.reader.peek(len + 1);
                if (buffered.len <= len) {
                    // No more data available, end of stream
                    break;
                }

                const byte = buffered[len];
                if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
                    byte == '>' or byte == '/' or byte == '=' or byte == '<')
                {
                    break;
                }

                len += 1;
                if (len > 1024) return error.InvalidElementName;
            }
        }

        if (len == 0) {
            return error.InvalidElementName;
        }

        // Take the name and store it
        const name = try self.reader.take(len);
        const stored_ref = try self.strings.store(name);
        return self.strings.getString(stored_ref);
    }

    /// Parse name and validate it matches expected, without storing
    fn parseNameAndValidate(self: *StreamingBackend, expected: []const u8) !void {
        // Peek ahead to check name matches
        const buffered = try self.reader.peek(expected.len);
        if (buffered.len < expected.len) {
            return error.MismatchedTags;
        }

        // Check each character matches
        if (!std.mem.eql(u8, buffered[0..expected.len], expected)) {
            return error.MismatchedTags;
        }

        // Check that the name ends here (next char is delimiter)
        const next_buffered = self.reader.peek(expected.len + 1) catch |err| switch (err) {
            error.EndOfStream => {
                // Name ends at EOF, which is fine
                self.reader.toss(expected.len);
                return;
            },
            else => return err,
        };

        if (next_buffered.len > expected.len) {
            const next_byte = next_buffered[expected.len];
            if (next_byte != ' ' and next_byte != '\t' and next_byte != '\n' and next_byte != '\r' and
                next_byte != '>' and next_byte != '/' and next_byte != '<')
            {
                // Name continues, doesn't match
                return error.MismatchedTags;
            }
        }

        // Valid match, consume the name
        self.reader.toss(expected.len);
    }

    /// Skip whitespace characters
    fn skipWhitespace(self: *StreamingBackend) !void {
        const chunk_size = 64;

        while (true) {
            const chunk = self.reader.peek(chunk_size) catch |err| switch (err) {
                error.EndOfStream => blk: {
                    // Try to peek at least 1 byte
                    const partial = self.reader.peek(1) catch |e| switch (e) {
                        error.EndOfStream => return, // No more data, we're done
                        else => return e,
                    };
                    break :blk partial;
                },
                else => return err,
            };

            if (chunk.len == 0) return;

            // Count consecutive whitespace
            var count: usize = 0;
            for (chunk) |byte| {
                if (!std.ascii.isWhitespace(byte)) break;
                count += 1;
            }

            if (count > 0) {
                self.reader.toss(count);
                // If we didn't consume the whole chunk, we found non-whitespace and are done
                if (count < chunk.len) return;
                // Otherwise, all of chunk was whitespace, continue to next chunk
            } else {
                // No whitespace found at current position
                return;
            }
        }
    }

    /// Read until a specific byte is found (not including the delimiter)
    /// Returns the slice and leaves the delimiter to be consumed by caller
    /// Does NOT store the result - caller must store if needed
    fn takeUntilByte(self: *StreamingBackend, delimiter: u8) ![]const u8 {
        var len: usize = 0;
        // Start with small chunk for common short tokens, grow for longer ones
        var chunk_size: usize = 64;

        while (true) {
            // Try to peek a chunk, but handle EndOfStream (peek as much as available)
            const buffered = self.reader.peek(len + chunk_size) catch |err| switch (err) {
                error.EndOfStream => blk: {
                    // Try smaller peek to get whatever is available
                    const partial = self.reader.peek(len + 1) catch |e| switch (e) {
                        error.EndOfStream => return error.UnterminatedToken,
                        else => return e,
                    };
                    if (partial.len <= len) return error.UnterminatedToken;
                    break :blk partial;
                },
                else => return err,
            };

            const available = buffered.len - len;
            if (available == 0) {
                return error.UnterminatedToken;
            }

            // Search for delimiter in the newly available portion
            const search_slice = buffered[len..buffered.len];
            if (std.mem.indexOfScalar(u8, search_slice, delimiter)) |offset| {
                // Found delimiter at position len + offset
                return try self.reader.take(len + offset);
            }

            // Delimiter not found in this chunk, continue from end of buffer
            len = buffered.len;

            // Grow chunk size for longer tokens (up to 512 bytes)
            if (chunk_size < 512) {
                chunk_size = @min(chunk_size * 2, 512);
            }

            // Sanity check: prevent unbounded growth
            if (len > 16 * 1024 * 1024) {
                return error.TokenTooLarge;
            }
        }
    }

    /// Read until a specific pattern is found (not including the pattern)
    /// Returns the slice and leaves the pattern to be consumed by caller
    /// Does NOT store the result - caller must store if needed
    fn takeUntilPattern(self: *StreamingBackend, pattern: []const u8) ![]const u8 {
        var len: usize = 0;
        while (true) {
            const buffered = try self.reader.peek(len + pattern.len);
            if (buffered.len < len + pattern.len) {
                // Not enough data, check if we're at end
                if (buffered.len <= len) {
                    return error.UnterminatedToken;
                }
            }

            // Check if pattern matches at current position
            if (buffered.len >= len + pattern.len and
                std.mem.eql(u8, buffered[len..][0..pattern.len], pattern))
            {
                break;
            }

            len += 1;

            // Sanity check: prevent unbounded growth
            if (len > 16 * 1024 * 1024) {
                return error.TokenTooLarge;
            }
        }

        return try self.reader.take(len);
    }

    /// Get current seek position in the reader
    pub fn getPosition(self: *const StreamingBackend) usize {
        return self.reader.seek;
    }

    /// Get parser state
    pub fn getState(self: *const StreamingBackend) ParserState {
        return self.state;
    }

    /// Get current depth
    pub fn getDepth(self: *const StreamingBackend) u8 {
        return self.depth;
    }
};
