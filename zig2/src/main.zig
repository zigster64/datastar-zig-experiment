const std = @import("std");
const datastar = @import("datastar");
const db = @import("db.zig");
const sqlite = @import("sqlite.zig");

const pubsub = datastar.pubsub;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HTTPServer = datastar.HTTPServer;
const HTTPRequest = datastar.HTTPRequest;

const options = @import("options");
const use_zio = options.io_mode == .zio;
const zio = if (use_zio) @import("zio") else void;
const zts = @import("zts");

const default_address = "0.0.0.0:8080";
const default_db_path = "users.db";

const tmpl = @embedFile("html/index.html");

// message queue schema for pubsub broadcasts
const MQSchema = union(enum) {
    users: void,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    server: *HTTPServer,
    pubsub: pubsub.PubSub(MQSchema),
    db: sqlite.Db,
    db_lock: Io.Mutex,

    pub fn init(env: std.process.Init, io: std.Io) !*App {
        var args = env.minimal.args.iterate();
        _ = args.next();
        const address_text = args.next() orelse default_address;
        const db_path: [:0]const u8 = args.next() orelse default_db_path;

        const port = if (std.mem.lastIndexOfScalar(u8, address_text, ':')) |colon|
            std.fmt.parseInt(u16, address_text[colon + 1 ..], 10) catch |err| {
                std.log.err("invalid port in '{s}': {s}", .{ address_text, @errorName(err) });
                return err;
            }
        else
            8080;

        var app_db = try sqlite.Db.open(env.gpa, db_path);
        errdefer app_db.close();
        try db.init(&app_db);

        const app = try env.gpa.create(App);
        errdefer env.gpa.destroy(app);

        const server = try HTTPServer.init(env, .{
            .port = port,
            .watch = true,
            .log = .{ .theme = .monochrom },
            .io = io,
        });
        server.useContext(app);

        app.* = .{
            .io = io,
            .allocator = env.gpa,
            .server = server,
            .pubsub = pubsub.PubSub(MQSchema).init(io, env.gpa),
            .db = app_db,
            .db_lock = Io.Mutex.init,
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.db.close();
        app.server.deinit();
    }

    pub fn getUsers(self: *App) !UsersList {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        self.db_lock.lock(self.io) catch unreachable;
        defer self.db_lock.unlock(self.io);
        const users = try db.allUsers(&self.db, arena.allocator());
        return .{ .arena = arena, .users = users };
    }

    pub fn renderUsersTable(app: *App, writer: anytype) !void {
        var users_list = try app.getUsers();
        defer users_list.deinit();
        try users_list.renderAsTable(writer);
    }

    pub fn insertUser(app: *App, name: []const u8, email: []const u8, role: []const u8) !void {
        app.db_lock.lock(app.io) catch unreachable;
        defer app.db_lock.unlock(app.io);
        _ = try db.insertUser(&app.db, name, email, role);
    }

    pub fn deleteUser(app: *App, id: i64) !void {
        app.db_lock.lock(app.io) catch unreachable;
        defer app.db_lock.unlock(app.io);
        try db.deleteUser(&app.db, id);
    }

    pub fn publishUsers(app: *App) !void {
        try app.pubsub.publish(.users, .all);
    }
};

const UsersList = struct {
    arena: std.heap.ArenaAllocator,
    users: []db.User,

    pub fn deinit(self: *UsersList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn renderAsTable(self: UsersList, writer: anytype) !void {
        try zts.print(tmpl, "users_table_start", .{self.users.len}, writer);
        for (self.users) |user| {
            try user.renderAsTableRow(writer);
        }
        try zts.write(tmpl, "users_table_end", writer);
    }
};

const ArenaWriter = struct {
    list: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ArenaWriter {
        return .{ .list = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *ArenaWriter) void {
        self.list.deinit(self.allocator);
    }

    pub fn print(self: *ArenaWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, fmt, args));
    }

    pub fn writeAll(self: *ArenaWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn items(self: ArenaWriter) []const u8 {
        return self.list.items;
    }
};

pub fn main(init: std.process.Init) !void {
    const rt = if (use_zio) try zio.Runtime.init(init.gpa, .{ .executors = .auto }) else {};
    defer if (use_zio) rt.deinit();
    const io: std.Io = if (use_zio) rt.io() else init.io;

    var app = try App.init(init, io);
    defer app.deinit();

    const r = app.server.router;
    r.get("/", index);
    r.get("/users", index);
    r.get("/index.html", index);
    r.get("/static/:filename", staticHandler);
    r.get("/updates", usersList);
    r.post("/users", handleCreate);
    r.delete("/users/:id", handleDelete);

    try app.server.run();
}

fn index(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);

    var w = ArenaWriter.init(http.arena);
    defer w.deinit();

    try zts.writeHeader(tmpl, &w);
    try app.renderUsersTable(&w);
    try zts.write(tmpl, "index_end", &w);

    return http.html(w.items());
}

fn staticHandler(http: *HTTPRequest) !void {
    if (http.params.get("filename")) |filename| {
        if (std.mem.eql(u8, filename, "datastar.js")) {
            return http.sendData(@embedFile("static/datastar.js"), "text/javascript; charset=utf-8");
        }
        if (std.mem.eql(u8, filename, "app.js")) {
            return http.sendData(@embedFile("static/app.js"), "text/javascript; charset=utf-8");
        }
        if (std.mem.eql(u8, filename, "app.css")) {
            return http.sendData(@embedFile("static/app.css"), "text/css");
        }
    }
    http.status = .not_found;
}

fn usersList(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    var sse = try http.NewSSESync();
    defer sse.close();
    var mq = try app.pubsub.connect();
    defer mq.deinit();
    try mq.subscribe(.users);
    while (try mq.nextTimeout(.fromSeconds(30))) |event| switch (event) {
        .msg => {
            const w = sse.patchElementsWriter(.{});
            try app.renderUsersTable(w);
            try sse.flush();
        },
        .timeout => {}, // try sse.keepalive(),
    };
}

fn handleCreate(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);

    const Signals = struct { name: []const u8, email: []const u8, role: []const u8 };
    const s = http.readSignals(Signals) catch {
        http.status = .bad_request;
        return;
    };

    const name = std.mem.trim(u8, s.name, " \t\r\n");
    const email = std.mem.trim(u8, s.email, " \t\r\n");
    const role = if (s.role.len > 0) s.role else "member";

    var name_err: ?[]const u8 = null;
    var email_err: ?[]const u8 = null;
    if (name.len == 0) name_err = "Name is required.";
    if (email.len == 0) {
        email_err = "Email is required.";
    } else if (std.mem.indexOfScalar(u8, email, '@') == null) {
        email_err = "Please enter a valid email address.";
    }

    if (name_err != null or email_err != null) {
        var sse = try http.NewSSESync();
        defer sse.close();
        try sse.patchSignals(.{ .nameError = name_err orelse "", .emailError = email_err orelse "" }, .{});
        return;
    }

    _ = try app.insertUser(name, email, role);
    try app.publishUsers();

    // Reset form signals and close the dialog.
    var sse = try http.NewSSESync();
    defer sse.close();
    try sse.patchSignals(.{
        .name = "",
        .email = "",
        .role = "member",
        .nameError = "",
        .emailError = "",
        .addOpen = false,
    }, .{});
}

fn handleDelete(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);

    const id_str = http.params.get("id") orelse {
        http.status = .not_found;
        return;
    };
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        http.status = .not_found;
        return;
    };

    try app.deleteUser(id);
    try app.publishUsers();

    var sse = try http.NewSSESync();
    defer sse.close();
    try sse.flush();
}
