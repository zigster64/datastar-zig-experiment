const std = @import("std");
const datastar = @import("datastar");
const db = @import("db.zig");
const sqlite = @import("sqlite.zig");

const pubsub = datastar.pubsub;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HTTPServer = datastar.HTTPServer;
const HTTPRequest = datastar.HTTPRequest;

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

    pub fn init(env: std.process.Init) !*App {
        // Open the database once at startup to create/seed it before any request
        // is served. Each connection later opens its own handle to the same file.
        {
            var args = env.minimal.args.iterate();
            _ = args.next();
            const db_path: [:0]const u8 = args.next() orelse default_db_path;

            std.log.info("creating DB at {s}", .{db_path});
            var setup_db = try sqlite.Db.open(env.gpa, db_path);
            defer setup_db.close();
            std.log.info("seeding DB at {s}", .{db_path});
            try db.init(&setup_db);
            std.log.info("DB ready at {s}", .{db_path});
        }

        const app = try env.gpa.create(App);
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
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.server.deinit();
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

fn index(http: *HTTPRequest) !void {
    return http.html(@embedFile("html/index.html"));
}

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

fn usersList(http: *HTTPRequest) !void {
    const app = http.getCtx(*App);
    var sse = try http.NewSSESync();
    defer sse.close();
    try updateUsersList(app, &sse); // initial render

    var mq = try app.pubsub.connect();
    defer mq.deinit();
    try mq.subscribe(.users);

    while (try mq.nextTimeout(.fromSeconds(30))) |event| switch (event) {
        .msg => try updateUsersList(app, &sse),
        .timeout => try sse.keepalive(),
    };
}

fn updateUsersList(app: *App, sse: *datastar.SSE) !void {
    _ = app; // autofix
    var w = sse.patchElementsWriter(.{});

    try w.writeAll(@embedFile("html/mock_users.html"));
    try sse.flush();
}
