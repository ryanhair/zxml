const std = @import("std");
const zxml = @import("zxml");

const xml_content = @embedFile("./tiger.svg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .never_unmap = true,
        .retain_metadata = true,
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

    try std.testing.expectEqual(240, doc.paths.items.len);
}

pub const SvgPath = struct {
    dummy: u8 = 0,

    fn parse(allocator: std.mem.Allocator, xml: SvgXml.PathXml) !SvgPath {
        // ignored for this example...
        _ = allocator;
        _ = xml;
        return SvgPath{};
    }
};

pub const SvgDocument = struct {
    allocator: std.mem.Allocator,

    paths: std.ArrayList(SvgPath) = std.ArrayList(SvgPath).empty,

    pub fn deinit(self: *SvgDocument) void {
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
            .paths = try std.ArrayList(SvgPath).initCapacity(allocator, 240),
        };

        // This is where we have a bug, especially in ReleaseFast mode,
        // but maybe also in ReleaseSafe mode.
        while (try self.xml.paths.next()) |item| {
            const path = try SvgPath.parse(allocator, item);
            try doc.paths.append(allocator, path);
        }

        return doc;
    }

    pub fn deinit(self: *SvgParser) void {
        self.parser.deinit();
    }
};

const SvgXml = struct {
    paths: zxml.Iterator("path", SvgXml.PathXml),

    const PathXml = struct {
        d: []const u8,
    };
};
