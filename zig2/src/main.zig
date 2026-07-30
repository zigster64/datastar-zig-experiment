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

const default_db_path = "users.db";

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

    pub fn init(env: std.process.Init) !*App {
        // Open the database once at startup; keep it open for the lifetime of
        // the app. All callers serialize access through db_lock.
        var args = env.minimal.args.iterate();
        _ = args.next(); // skip executable name
        const db_path: [:0]const u8 = args.next() orelse default_db_path;

        std.log.info("opening DB at {s}", .{db_path});
        var app_db = try sqlite.Db.open(env.gpa, db_path);
        errdefer app_db.close();
        try db.init(&app_db);
        std.log.info("DB ready at {s}", .{db_path});

        const app = try env.gpa.create(App);
        errdefer env.gpa.destroy(app);

        const server = try HTTPServer.init(env, .{
            .port = 8080,
            .watch = true, // for Dev mode - if the app is recompiled, will restart the server
            .log = .{ .theme = .monochrom },
        });
        server.useContext(app);

        app.* = .{
            .io = env.io,
            .allocator = env.gpa,
            .server = server,
            .pubsub = pubsub.PubSub(MQSchema).init(env.io, env.gpa),
            .db = app_db,
            .db_lock = Io.Mutex.init,
        };
        return app;
    }
        // Open the database once at startup; keep it open for the lifetime of
        // the app. All callers serialize access through db_lock.
        var args = env.minimal.args.iterate();
        _ = args.next(); // skip executable name
        const db_path: [:0]const u8 = args.next() orelse default_db_path;

        std.log.info("opening DB at {s}", .{db_path});
        var app_db = try sqlite.Db.open(env.gpa, db_path);
        errdefer app_db.close();
        try db.init(&app_db);
        std.log.info("DB ready at {s}", .{db_path});

        const app = try env.gpa.create(App);
        errdefer env.gpa.destroy(app);

        const server = try HTTPServer.init(env, .{
            .port = 8080,
            .watch = true, // for Dev mode - if the app is recompiled, will restart the server
            .log = .{ .theme = .monochrom },
        });
        server.useContext(app);

        app.* = .{
            .io = env.io,
            .allocator = env.gpa,
            .server = server,
            .pubsub = pubsub.PubSub(MQSchema).init(env.io, env.gpa),
            .db = app_db,
            .db_lock = Io.Mutex.init,
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.db.close();
        app.server.deinit();
    }

    /// Lock the DB, build an arena-backed list of all users, unlock, return.
    /// Caller must call users_list.deinit() to free the arena.
    pub fn getUsers(self: *App) !UsersList {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        self.db_lock.lock(self.io) catch unreachable;
        defer self.db_lock.unlock(self.io);

        const users = try db.allUsers(&self.db, arena.allocator());

        return .{ .arena = arena, .users = users };
    }

    /// updateUsersList will get the current set of users, and then output this as a table
    /// to the given SSE stream.
    /// So all clients that are subscribed to an SSE update endpoint will get a copy of this
    pub fn updateUsersList(app: *App, sse: *datastar.SSE) !void {
        var users_list = try app.getUsers();
        defer users_list.deinit();

        const w = sse.patchElementsWriter(.{});
        try users_list.renderAsTable(w);
        try sse.flush();
    }
};

/// Arena-backed list of users. deinit() frees everything in one call:
/// all strings, the slice, and the arena's backing pages.
const UsersList = struct {
    arena: std.heap.ArenaAllocator,
    users: []db.User,

    pub fn deinit(self: *UsersList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Render the full users table to `writer`: caption, header, rows, close.
    pub fn renderAsTable(self: UsersList, writer: anytype) !void {
        try writer.print(
            \\<table id="users">
            \\  <caption>{} user(s), live-updated over SSE</caption>
            \\  <thead>
            \\    <tr>
            \\      <th>ID</th>
            \\      <th>Name</th>
            \\      <th>Email</th>
            \\      <th>Role</th>
            \\      <th></th>
            \\    </tr>
            \\  </thead>
            \\  <tbody>
            \\
        , .{self.users.len});

        for (self.users) |user| {
            try user.renderAsTableRow(writer);
        }

        try writer.writeAll(
            \\  </tbody>
            \\</table>
            \\
        );
    }
};

// mux.HandleFunc("GET /index.html", s.handlePage) - done
// mux.HandleFunc("GET /updates", s.handleUpdates) - done
// mux.Handle("GET /static/", staticHandler()) - done

// mux.HandleFunc("GET /{$}", s.handlePage)
// mux.HandleFunc("GET /users", s.handlePage)
// mux.HandleFunc("POST /users/{$}", s.handleCreate)
// mux.HandleFunc("POST /users", s.handleCreate)
// mux.HandleFunc("DELETE /users/{id}", s.handleDelete)

pub fn main(init: std.process.Init) !void {
    // Create the global app instance with web server
    var app = try App.init(init);
    defer app.deinit();

    // index and static assets
    const r = app.server.router;
    r.get("/", index);
    r.get("/static/:filename", staticHandler);

    // the SSE updater
    r.get("/updates", usersList);

    try app.server.run();
}

// handler function for GET /
fn index(http: *HTTPRequest) !void {
    return http.html(@embedFile("html/index.html"));
}

// handler function for GET /static/:filename
// staticHandler just hard codes and embeds the files for now, since there are only 3 of them
fn staticHandler(http: *HTTPRequest) !void {
    if (http.params.get("filename")) |filename| {
        if (std.mem.eql(u8, filename, "datastar.js")) {
            return http.sendData(@embedFile("static/datastar.js"), "text/javascript");
        }
        if (std.mem.eql(u8, filename, "app.js")) {
            return http.sendData(@embedFile("static/app.js"), "text/javascript");
        }
        if (std.mem.eql(u8, filename, "app.css")) {
            return http.sendData(@embedFile("static/app.css"), "text/css");
        }
    }
    http.status = .not_found;
}

// handler function for GET /update
fn usersList(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    var sse = try http.NewSSESync();
    defer sse.close();
    try app.updateUsersList(&sse); // initial render

    var mq = try app.pubsub.connect();
    defer mq.deinit();
    try mq.subscribe(.users);

    while (try mq.nextTimeout(.fromSeconds(30))) |event| switch (event) {
        .msg => try app.updateUsersList(&sse),
        .timeout => try sse.keepalive(),
    };
}
