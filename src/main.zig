const std = @import("std");
const net = std.net;
const eql = std.mem.eql;

const stdout = std.io.getStdOut().writer();

pub fn main() !void {

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try stdout.print("Logs from your program will appear here!", .{});

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

// finds the next index of the /r/n seperator
// returns the end if one was not found
pub fn next_index(s: []u8, start: i32) i32 {
    var i = start;
    while (i < s.len and s[i] != null) {
        if (i == s.len) {
            break;
        }
        if (s[i] == '\r') {
            break;
        }
        i += 1;
    }

    return i;
}

pub fn handle_conn(c: net.Server.Connection) !void {
    defer c.stream.close();
    var buff: [1024]u8 = undefined;

    while (true) {
        const read_bytes = try c.stream.read(&buff);
        if (read_bytes == 0) break;
        var iter = std.mem.tokenizeAny(u8, &buff, [][]u8{"\n\r"});

        while (iter.next()) |str| {
            const indicator = Indicator.parse(str[0]);

            try stdout.print("indicator: {}\n", .{indicator});
            if (indicator == Indicator.simple_string) {
                const cmd = std.meta.stringToEnum(Command, str[1..]);

                const resp = respond(cmd, .{});
                try stdout.print("responded: {s}\n", .{resp});
                try c.stream.writeAll(resp);
            }
        }
    }

    try std.Thread.yield();
}

const Indicator = enum {
    simple_string,
    simple_error,
    integer,
    bulk_string,
    array,
    nulls,
    boolean,
    double,
    big_number,
    bulk_error,
    verbatim_string,
    maps,
    attributes,
    sets,
    pushes,

    pub fn parse(c: u8) Indicator {
        return switch (c) {
            '+' => Indicator.simple_string,
            '-' => Indicator.simple_error,
            ':' => Indicator.integer,
            '$' => Indicator.bulk_string,
            '*' => Indicator.array,
            '_' => Indicator.nulls,
            '#' => Indicator.boolean,
            ',' => Indicator.double,
            '(' => Indicator.big_number,
            '!' => Indicator.bulk_error,
            '=' => Indicator.verbatim_string,
            '%' => Indicator.maps,
            '`' => Indicator.attributes,
            '~' => Indicator.sets,
            '>' => Indicator.pushes,
        };
    }
};

const Command = enum {
    ping,
    echo,
};

pub fn respond(c: Command, args: anytype) []const u8 {
    _ = args;
    return switch (c) {
        .ping => "+PONG\r\n",
        .echo => "+ECHO\r\n",
    };
}
