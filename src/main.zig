const std = @import("std");
const net = std.net;
const eql = std.mem.eql;
const xev = @import("xev");
const posix = std.posix;

const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    const allocator = std.heap.FixedBufferAllocator;
    const address = try net.Address.resolveIp("127.0.0.1", 6379);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(1);

    var ud: bool = false;
    var recv_buf: [1024]u8 = undefined;
    var recv_len: usize = 1024;

    var mem = allocator.init(&recv_buf);

    while (true) {
        var accept_c: xev.Completion = .{};
        var read_c: xev.Completion = .{};
        server.accept(&loop, &accept_c, bool, &ud, handle_accept);

        try loop.run(.until_done);

        server.read(&loop, &read_c, .{ .slice = &recv_buf }, usize, &recv_len, handle_read);

        try loop.run(xev.RunMode.until_done);
        mem.reset();
    }
}

pub fn handle_read(
    buf_size: ?*usize,
    l: *xev.Loop,
    _: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const read_bytes = r catch |err| {
        std.debug.print("read error {}", .{err});
        return xev.CallbackAction.disarm;
    };

    if (read_bytes == buf_size.?.*) {
        std.debug.print("buffer full", .{});
    }

    const buffer = b.slice;

    if (read_bytes == 0) {
        std.debug.print("read nothing", .{});
        return xev.CallbackAction.disarm;
    }

    var iter = std.mem.tokenizeAny(u8, buffer, "\n\r");
    //var wQueue: xev.TCP.WriteQueue = .{};
    //var wRequest: xev.TCP.WriteRequest = undefined;

    var written = false;
    const allocator = std.heap.page_allocator;
    var responses = std.ArrayList(u8).init(allocator);

    while (iter.next()) |cmd| {
        const resp = command(cmd);
        //const wr: xev.TCP.WriteRequest = .{ .full_write_buffer = resp };
        // wQueue.push(wr);
        responses.appendSlice(resp) catch |err| {
            std.debug.print("allocation error: {}\n", .{err});
        };
    }

    var write_c: xev.Completion = .{};

    s.write(l, &write_c, .{ .slice = responses.items }, bool, &written, handle_write);
    //s.queueWrite(l, &wQueue, &wRequest, .{}, bool, &written, handle_write);

    return xev.CallbackAction.disarm;
}
pub fn handle_write(
    ud: ?*bool,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    b: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const write_bytes = r catch |err| {
        std.debug.print("write error: {}\n", .{err});
        return xev.CallbackAction.disarm;
    };

    if (write_bytes == 0) {
        std.debug.print("wrote zero\n", .{});
        return xev.CallbackAction.disarm;
    }

    ud.?.* = true;

    std.debug.print("repsonded: {}", .{b.array});

    return xev.CallbackAction.disarm;
}

pub fn handle_accept(
    ud: ?*bool,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    std.debug.print("accepted new connection\n", .{});
    ud.?.* = true;

    return xev.CallbackAction.disarm;
}

pub fn command(cmd: []const u8) []const u8 {
    if (eql(u8, cmd, "PING")) {
        return "+PONG\r\n";
    } else {
        return "";
    }
}

test "can connect to server" {
    const testing = std.testing;

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Choose random available port (Zig #14907)
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try xev.TCP.init(address);

    // Bind and listen
    try server.bind(address);
    try server.listen(1);

    // Retrieve bound port and initialize client
    var sock_len = address.getOsSockLen();
    const fd = server.fd;
    try posix.getsockname(fd, &address.any, &sock_len);
    const client = try xev.TCP.init(address);

    // Completions we need
    var c_accept: xev.Completion = undefined;
    var c_connect: xev.Completion = undefined;

    // Accept
    var server_connected: bool = false;
    server.accept(&loop, &c_accept, bool, &server_connected, handle_accept);

    // Connect
    var connected: bool = false;
    client.connect(&loop, &c_connect, address, bool, &connected, (struct {
        fn callback(
            ud: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            r: xev.ConnectError!void,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            ud.?.* = true;
            return xev.CallbackAction.disarm;
        }
    }).callback);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_connected);
    try testing.expect(connected);
}

test "multiple connections" {
    const testing = std.testing;

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Choose random available port (Zig #14907)
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try xev.TCP.init(address);

    // Bind and listen
    try server.bind(address);
    try server.listen(1);

    // Retrieve bound port and initialize client
    var sock_len = address.getOsSockLen();
    const fd = server.fd;
    try posix.getsockname(fd, &address.any, &sock_len);

    const runner = struct {
        s: *xev.TCP,
        l: *xev.Loop,
        times: u8,

        pub fn run(self: *@This()) !void {
            var i: u8 = 0;
            while (i < self.times) {
                var server_connected: bool = false;
                var c_accept: xev.Completion = undefined;
                self.s.accept(self.l, &c_accept, bool, &server_connected, handle_accept);
                std.debug.print("call acccept \n", .{});
                try self.l.run(.until_done);
                i += 1;
            }
        }
    };

    var r: runner = runner{ .l = &loop, .s = &server, .times = 3 };

    const thread = try std.Thread.spawn(.{}, runner.run, .{&r});
    thread.detach();

    // Accept
    const client = std.net.tcpConnectToAddress(address);
    std.debug.print("client connected\n", .{});
    const client2 = try std.net.tcpConnectToAddress(address);
    std.debug.print("client 2 connected\n", .{});
    const client3 = try std.net.tcpConnectToAddress(address);
    std.debug.print("client 3 connected\n", .{});

    try testing.expect(@TypeOf(client) != std.net.TcpConnectToAddressError);
    try testing.expect(@TypeOf(client2) != std.net.TcpConnectToAddressError);
    try testing.expect(@TypeOf(client3) != std.net.TcpConnectToAddressError);
}
