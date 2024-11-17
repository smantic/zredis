const std = @import("std");
const net = std.net;
const eql = std.mem.eql;
const xev = @import("xev");

const stdout = std.io.getStdOut().writer();
const Conn = std.net.Server.Connection;

pub fn main() !void {
    _ = xev;

    const address = try net.Address.resolveIp("127.0.0.1", 6379);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const connection = try listener.accept();
        try stdout.print("accepted new connection", .{});

        var thread = try std.Thread.spawn(.{}, handle_conn, .{connection});
        thread.detach();
    }
}

const Tag = enum {
    eof,
    invalid,
    null,
    seperator,
    true,
    false,
    length,
    integer,
    indicator_simple_string,
    indicator_simple_error,
    indicator_integer,
    indicator_bulk_string,
    indicator_array,
    indicator_nulls,
    indicator_boolean,
    indicator_double,
    indicator_big_number,
    indicator_bulk_error,
    indicator_verbatim_string,
    indicator_maps,
    indicator_attributes,
    indicator_sets,
    indicator_pushes,
    command_ping,
    command_echo,

    pub fn inidicator(c: u8) ?Tag {
        return switch (c) {
            else => null,
        };
    }

    pub fn command(t: []u8) ?Tag {
        if (eql([]u8, t)) {}
    }
};

const Token = struct { Tag: Tag = undefined, data: ?[]const u8 = null };

// inspired by std.zig.tokenizer.zig
pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    state: State,

    const State = enum {
        start,
        string,
        length,
        integer,
        boolean,
        double,
        verbatim,
    };

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = -1,
            .state = .start,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{};
        const start = self.index;

        while (true) {
            self.index += 1;
            switch (self.state) {
                .start => switch (self.buffer[self.index]) {
                    0 => { // eof
                        if (self.index == self.buffer.len) {
                            result.Tag = Tag.eof;
                            result.end = self.index;
                            return result;
                        }
                    },
                    '\r' => { // /r/n seperator
                        result.Tag = Tag.seperator;
                        self.index += 1;
                        return result;
                    },
                    '+' => { // simple string
                        result.Tag = Token.indicator_simple_string;
                        self.state = State.string;
                        return result;
                    },
                    '-' => { // simple error
                        result.Tag = Token.indicator_simple_error;
                        self.state = State.string;
                        return result;
                    },
                    ':' => { // integer
                        result.Tag = Token.indicator_integer;
                        self.state = State.integer;
                        return result;
                    },
                    '$' => { // bulk string
                        result.Tag = Token.indicator_bulk_string;
                        // TODO need to have a different state for parsing string
                        // since this potentially allows /r/n
                        self.state = State.length;
                        return result;
                    },
                    '*' => { // array
                        result.Tag = Token.indicator_array;
                        self.state = State.length;
                        return result;
                    },
                    '_' => { // null
                        result.Tag = Token.indicator_nulls;
                        return result;
                    },
                    '#' => { // boolean
                        result.Tag = Token.indicator_boolean;
                        self.state = State.boolean;
                        return result;
                    },
                    ',' => { // double
                        result.Tag = Token.indicator_double;
                        self.state = State.double;
                        return result;
                    },
                    '(' => { // big number
                        result.Tag = Token.indicator_big_number;
                        self.state = State.integer;
                        return result;
                    },
                    '!' => { // bulk error
                        result.Tag = Token.indicator_bulk_error;
                        self.state = State.length;
                        return result;
                    },
                    '=' => { // verbatim string
                        result.Tag = Token.indicator_verbatim_string;
                        self.state = State.length;
                        return result;
                    },
                    '%' => { // map
                        result.Tag = Token.indicator_maps;
                        self.sate = State.length;
                        return result;
                    },
                    '`' => { // attribute
                        result.Tag = Token.indicator_attributes;
                        self.state = State.length;
                        return result;
                    },
                    '~' => { // set
                        result.Tag = Token.indicator_sets;
                        self.state = State.length;
                        return result;
                    },
                    '>' => { // push
                        result.Tag = Token.indicator_pushes;
                        self.state = State.length;
                        return result;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', ' ' => {
                        self.state = State.string;
                        continue;
                    },
                    else => {
                        result.Tag = Tag.invalid;
                        return result;
                    },
                },
                .double => {
                    switch (self.buffer[self.index]) {
                        '+', '-', '0'...'9', '.', 'e', 'E' => continue,
                        'i', 'n', 'f' => continue, // inf
                        'n', 'a', 'n' => continue, // NaN
                        else => {
                            result.data = self.buffer[start..self.index];
                            return result;
                        },
                    }
                },
                .boolean => {
                    switch (self.buffer[self.index]) {
                        't' => {
                            result.Tag = Tag.true;
                            self.state = State.start;
                            return result;
                        },
                        'f' => {
                            result.Tag = Tag.true;
                            self.state = State.start;
                            return result;
                        },
                        else => {
                            self.state = State.start;
                            result.data = self.buffer[start..self.index];
                            return result;
                        },
                    }
                },
                .integer => {
                    switch (self.buffer[self.index]) {
                        '+', '-', '0'...'9' => continue,
                        else => {
                            result.Tag = Tag.integer;
                            result.data = self.buffer[start..self.index];
                            self.state = State.start;
                            return result;
                        },
                    }
                },
                .string => {
                    switch (self.buffer[self.index]) {
                        'a'...'z', 'A'...'Z', '0'...'9', ' ' => continue,
                        ':' => continue, // verbatim strings identify type
                        else => {
                            result.data = self.buffer[start..self.index];
                            self.state = State.start;
                            return result;
                        },
                    }
                },
                .length => {
                    switch (self.buffer[self.index]) {
                        '0'...'9' => continue,
                        '-' => { // only -1 is allowed.
                            result.Tag = Tag.null;
                            continue;
                        },
                        else => {
                            result.data = self.buffer[start..self.index];
                            self.state = State.start;
                            return result;
                        },
                    }
                },
            }
        }
    }
};

pub fn handle_conn(c: Conn) !void {
    defer c.stream.close();
    var buff: [1024]u8 = undefined;
    const allocator = std.heap.HeapAllocator;

    while (true) {
        const read_bytes = try c.stream.read(&buff);
        if (read_bytes == 0) break;
        const tokenizer = Tokenizer.init(buff);

        var tokens = std.ArrayList(Token).init(allocator);

        while (tokenizer.next()) |token| {
            try tokens.append(token);
        }

        try handle(c, tokens.items);

        //try c.stream.writeAll(resp);
    }

    try std.Thread.yield();
}

const Command = union(enum) {
    PING: struct {},
    ECHO: struct {
        Arg: []u8,
    },
};

pub fn handle(c: Conn, t: []const Token) !void {
    _ = c;
    _ = t;
}

pub fn respond(c: Conn, cmd: ?Command) !void {
    if (cmd == null) {
        return "";
    }
    switch (cmd.?) {
        .PING => |_| try std.fmt.format(c, "+PONG\r\n", .{}),
        .ECHO => |echo| try std.fmt.format(c, "+{s}\r\n", .{echo.Arg}),
    }
}
