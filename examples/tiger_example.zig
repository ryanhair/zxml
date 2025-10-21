const std = @import("std");
const zxml = @import("zxml");

const xml_content = @embedFile("./tiger.svg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .never_unmap = true,
        .retain_metadata = true,
        // .verbose_log = true,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. crashes in Release mode
    var parser = try SvgParser.initWithMmap(allocator, "examples/tiger.svg");

    // 2. fails with TooManyAttributes
    // const xml_content = @embedFile("./tiger.svg");
    // var reader = std.Io.Reader.fixed(xml_content);
    // var parser = try SvgParser.initStream(allocator, &reader);

    // 3. crashes in Release mode
    // var parser = try SvgParser.initInMemory(allocator, xml_content);

    defer parser.deinit();
    var doc = try parser.parse();
    defer doc.deinit();

    // std.debug.print("Loaded SVG file with {d} shapes\n", .{doc.paths.items.len});
    try std.testing.expectEqual(240, doc.paths.items.len);
}

pub const SvgPath = struct {
    dummy: u8 = 0,

    fn deinit(self: *SvgPath, allocator: std.mem.Allocator) void {
        // ignored for this example...
        _ = allocator;
        _ = self;
    }

    fn parse(allocator: std.mem.Allocator, xml: SvgXml.PathXml) !SvgPath {
        // ignored for this example...
        _ = allocator;
        _ = xml;
        return SvgPath{};
    }
};

pub const SvgDocument = struct {
    allocator: std.mem.Allocator,

    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    viewbox: ?@Vector(4, f32) = null,
    paths: std.ArrayList(SvgPath) = std.ArrayList(SvgPath).empty,

    pub fn deinit(self: *SvgDocument) void {
        for (self.paths.items, 0..) |_, k| {
            self.paths.items[k].deinit(self.allocator);
        }
        self.paths.deinit(self.allocator);
    }
};
pub const SvgParser = struct {
    const Parser = zxml.TypedParser(SvgXml);

    xml: SvgXml,
    parser: Parser,

    pub fn initWithMmap(allocator: std.mem.Allocator, filepath: []const u8) !SvgParser {
        var parser = Parser.initWithMmap(allocator, filepath) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{
            .xml = parser.result,
            .parser = parser,
        };
    }

    pub fn initInMemory(allocator: std.mem.Allocator, xml: []const u8) !SvgParser {
        var parser = Parser.initInMemory(allocator, xml) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{
            .xml = parser.result,
            .parser = parser,
        };
    }

    pub fn initStream(allocator: std.mem.Allocator, reader: *std.io.Reader) !SvgParser {
        var parser = Parser.init(allocator, reader) catch |err| {
            std.log.err("could not parse SVG: {}", .{err});
            return error.InvalidSvg;
        };
        errdefer parser.deinit();
        return SvgParser{
            .xml = parser.result,
            .parser = parser,
        };
    }

    pub fn parse(self: *SvgParser) !SvgDocument {
        const allocator = self.parser.allocator;

        var doc = SvgDocument{
            .allocator = allocator,
            // .width = try allocator.dupe(u8, self.xml.width.?),
            // .height = try allocator.dupe(u8, self.xml.height.?),
        };

        // doc.viewbox = self.parseViewBox() catch |err| brk: {
        //     std.log.warn("could not parse viewbox: {}", .{err});
        //     break :brk null;
        // };

        // This is where we have a bug, especially in ReleaseFast mode,
        // but maybe also in ReleaseSafe mode.
        while (try self.xml.paths.next()) |item| {
            // std.debug.print("Parsing path: {}\n", .{item});
            const path = try SvgPath.parse(allocator, item);
            try doc.paths.append(allocator, path);
        }

        return doc;
    }

    fn parseViewBox(self: *SvgParser) !?@Vector(4, f32) {
        if (self.xml.viewBox == null) return null;
        var viewbox: @Vector(4, f32) = undefined;
        var lexer = Lexer.init(self.xml.viewBox.?);
        viewbox[0] = try lexer.nextCoord() orelse return null;
        viewbox[1] = try lexer.nextCoord() orelse return null;
        viewbox[2] = try lexer.nextCoord() orelse 300.0;
        viewbox[3] = try lexer.nextCoord() orelse 150.0;
        return viewbox;
    }

    pub fn deinit(self: *SvgParser) void {
        self.parser.deinit();
    }
};

const SvgXml = struct {
    width: ?[]const u8,
    height: ?[]const u8,
    viewBox: ?[]const u8,
    xmlns: ?[]const u8,
    paths: zxml.Iterator("path", SvgXml.PathXml),
    // paths: zxml.MultiIterator(SvgItem),

    const SvgItem = union(enum) {
        path: SvgXml.PathXml,
    };

    const PathXml = struct {
        d: []const u8,
        fill: ?[]const u8,
        fill_opacity: ?f32,
        fill_rule: ?[]const u8,
        fill_color: ?[]const u8,
        stroke: ?[]const u8,
    };
};

// misc
const Pos2 = @Vector(2, f32);
const Lexer = struct {
    input: []const u8,
    position: usize,

    fn init(input: []const u8) Lexer {
        return Lexer{ .input = input, .position = 0 };
    }

    // Skip over spaces and comma if requested. Comma are valid for
    // separation between numbers, but not before & after a command letter.
    fn skipSpaces(self: *Lexer, skip_comma: bool) void {
        var has_comma = false;
        while (self.position < self.input.len) {
            const c = self.input[self.position];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.position += 1;
            } else if (!has_comma and skip_comma and c == ',') {
                self.position += 1;
                has_comma = true;
            } else return;
        }
    }

    fn nextNum(self: *Lexer) ?[]const u8 {
        if (self.done()) return null;

        const c = self.input[self.position];
        if (c == '-' or c == '+' or c == '.' or std.ascii.isDigit(c)) {
            var pos = self.position;
            var has_dot = false;
            if (c == '-' or c == '+') pos += 1;
            while (pos < self.input.len) {
                const cc = self.input[pos];
                if (cc == '.') {
                    if (has_dot) break;
                    has_dot = true;
                    pos += 1;
                } else if (std.ascii.isDigit(cc)) {
                    pos += 1;
                } else {
                    break;
                }
            }
            return self.input[self.position..pos];
        }

        return null;
    }

    // fn nextCmd(self: *Lexer, current: ?u8) ?u8 {
    //     self.skipSpaces(false);
    //     if (self.done()) return null;
    //     const c = self.input[self.position];
    //     if (c == ',' or c == '-' or c == '.' or c == '+' or std.ascii.isDigit(c)) {
    //         // we are just expecting new numbers for the same command
    //         self.skipSpaces(false);
    //         return current;
    //     }
    //     if (!std.ascii.isAlphabetic(c)) return null;
    //     self.position += 1;
    //     return c;
    // }

    // fn nextPair(self: *Lexer) !?Pos2 {
    //     self.skipSpaces(false);
    //     if (self.done()) return null;
    //     const v1 = try self.nextCoord();
    //     self.skipSpaces(true);
    //     const v2 = try self.nextCoord();
    //     if (v1 == null or v2 == null) return error.NumberParseFailed;
    //     return Pos2{ v1.?, v2.? };
    // }

    fn nextCoord(self: *Lexer) !?f32 {
        self.skipSpaces(true);
        const token = self.nextNum();
        if (token == null) return null;
        const val = std.fmt.parseFloat(f32, token.?) catch {
            std.debug.print("failed to parse single number from token '{s}'\n", .{token.?});
            return error.NumberParseFailed;
        };
        self.position += token.?.len;
        return val;
    }

    // fn nextBool(self: *Lexer) !bool {
    //     const b = try self.nextCoord();
    //     if (b == null) return error.MissingToken;
    //     if (b.? == 1) {
    //         return true;
    //     } else if (b.? == 0) {
    //         return false;
    //     } else {
    //         return error.NumberNotBoolean;
    //     }
    // }

    fn done(self: *Lexer) bool {
        return self.position >= self.input.len;
    }
};
