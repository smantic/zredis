const std = @import("std");
const net = std.net;
const eql = std.mem.eql;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try stdout.print("Logs from your program will appear here!", .{});

    const address = try net.Address.resolveIp("127.0.0.1", 6379);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const connection = try listener.accept();

        var buff: [1024]u8 = undefined;

        while (true) {
            const read_bytes = try connection.stream.read(&buff);
            if (read_bytes == 0) break;
            var iter = std.mem.tokenizeAny(u8, &buff, "\n\r");

            while (iter.next()) |cmd| {
                const resp = command(cmd);
                try stdout.print("responded: {s}\n", .{resp});
                try connection.stream.writeAll(resp);
            }
        }

        try stdout.print("accepted new connection", .{});
        connection.stream.close();
    }
}

pub fn command(cmd: []const u8) []const u8 {
    if (eql(u8, cmd, "PING")) {
        return "+PONG\r\n";
    } else {
        return "";
    }
}
