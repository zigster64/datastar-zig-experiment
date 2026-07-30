//! Zig wrapper over the vendored SQLite C API: open a database, execute
//! statements, iterate result rows. C result codes map to `Error`; the message
//! stays reachable via `Db.errmsg`.
//!
//! A `Db` is used by a single thread (opened with `SQLITE_OPEN_NOMUTEX`), so it
//! holds an unsynchronized prepared-statement cache: `prepareCached` compiles
//! each SQL string once and reuses it.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    /// Generic error; call `Db.errmsg` for the SQLite message.
    Sqlite,
    /// The database file is locked or busy.
    Busy,
    /// A constraint (e.g. UNIQUE, NOT NULL) was violated.
    Constraint,
    OutOfMemory,
};

/// `SQLITE_TRANSIENT` tells SQLite to copy bound blobs/text. The C header
/// defines it as `(sqlite3_destructor_type)-1`, a sentinel SQLite compares by
/// identity and never calls. translate-c cannot lower it (a function pointer
/// with an unaligned address), so we re-declare `sqlite3_bind_text` with the
/// destructor typed as a plain opaque pointer (alignment 1) and hand it the
/// sentinel directly.
const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));
const bindTextRaw = @extern(*const fn (
    ?*c.sqlite3_stmt,
    c_int,
    [*c]const u8,
    c_int,
    ?*const anyopaque,
) callconv(.c) c_int, .{ .name = "sqlite3_bind_text" });

/// Map a SQLite result code to `Error` (success codes map to no error).
fn check(rc: c_int) Error!void {
    return switch (rc) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => Error.Busy,
        c.SQLITE_CONSTRAINT => Error.Constraint,
        c.SQLITE_NOMEM => Error.OutOfMemory,
        else => {
            std.log.err("SQLite Invalid Return Code: {}", .{rc});
            return Error.Sqlite;
        },
    };
}

pub const Db = struct {
    handle: *c.sqlite3,
    gpa: Allocator,
    /// SQL string -> compiled statement. Keys must be stable for the `Db`'s
    /// lifetime; all callers pass string literals.
    stmt_cache: std.StringHashMapUnmanaged(*c.sqlite3_stmt),

    /// Open (creating if necessary) the database at `path`. Pass `":memory:"`
    /// for a private in-memory database.
    ///
    /// The connection is opened in multi-thread mode (`SQLITE_OPEN_NOMUTEX`):
    /// no per-call mutex. This is safe because a `Db` is never shared between
    /// threads — each worker opens its own. WAL is enabled so readers do not
    /// block the single writer.
    pub fn open(gpa: Allocator, path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
        errdefer if (handle) |h| {
            _ = c.sqlite3_close(h);
        };
        try check(rc);
        const h = handle orelse return Error.OutOfMemory;

        // A busy connection waits (up to 5s) rather than failing immediately.
        _ = c.sqlite3_busy_timeout(h, 5000);

        var db: Db = .{ .handle = h, .gpa = gpa, .stmt_cache = .empty };
        // WAL: concurrent readers alongside one writer; NORMAL sync is durable
        // under WAL. Both are no-ops on `:memory:`.
        db.exec("PRAGMA journal_mode = WAL;") catch {};
        db.exec("PRAGMA synchronous = NORMAL;") catch {};
        return db;
    }

    pub fn close(self: *Db) void {
        var it = self.stmt_cache.valueIterator();
        while (it.next()) |h| _ = c.sqlite3_finalize(h.*);
        self.stmt_cache.deinit(self.gpa);
        _ = c.sqlite3_close(self.handle);
        self.* = undefined;
    }

    /// The message describing the most recent failed call on this connection.
    pub fn errmsg(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    /// The rowid of the most recent successful INSERT on this connection.
    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Execute one or more semicolon-separated statements, discarding any rows.
    /// Intended for schema setup and other statements without bound parameters.
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        check(c.sqlite3_exec(self.handle, sql.ptr, null, null, null)) catch |err| {
            std.log.err("SQLite Error: '{s}' error: {}", .{ sql, err });
            return err;
        };
    }

    /// Compile `sql` once and cache it; subsequent calls return the same
    /// statement, reset with its bindings cleared, ready to bind and step. The
    /// cache owns the statement (finalized in `close`); callers must not
    /// `deinit` it. `sql` must be a stable string (a literal).
    pub fn prepareCached(self: *Db, sql: []const u8) Error!Stmt {
        if (self.stmt_cache.get(sql)) |h| {
            _ = c.sqlite3_reset(h);
            _ = c.sqlite3_clear_bindings(h);
            return .{ .handle = h };
        }
        var handle: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &handle, null));
        const h = handle orelse return Error.Sqlite;
        errdefer _ = c.sqlite3_finalize(h);
        try self.stmt_cache.put(self.gpa, sql, h);
        return .{ .handle = h };
    }

    /// Compile a single, uncached statement the caller owns and must `deinit`.
    /// For one-off statements not worth caching.
    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &handle, null));
        return .{ .handle = handle orelse return Error.Sqlite };
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    /// Finalize an uncached statement (from `Db.prepare`). Never call on a
    /// statement from `Db.prepareCached`; the cache owns those.
    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    /// Bind a 64-bit integer to parameter `index` (1-based).
    pub fn bindInt(self: *Stmt, index: c_int, value: i64) Error!void {
        try check(c.sqlite3_bind_int64(self.handle, index, value));
    }

    /// Bind text to parameter `index` (1-based). SQLite copies the bytes
    /// (via `SQLITE_TRANSIENT`), so `value` need not outlive the call.
    pub fn bindText(self: *Stmt, index: c_int, value: []const u8) Error!void {
        try check(bindTextRaw(
            self.handle,
            index,
            value.ptr,
            @intCast(value.len),
            transient,
        ));
    }

    /// Advance to the next row. Returns `true` while a row is available and
    /// `false` once the statement is exhausted.
    pub fn step(self: *Stmt) Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        try check(rc);
        return false;
    }

    /// Reset an executed statement so it can be stepped again.
    pub fn reset(self: *Stmt) Error!void {
        try check(c.sqlite3_reset(self.handle));
    }

    pub fn columnInt64(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    /// Return column `col` of the current row as text. The slice is owned by
    /// SQLite and is only valid until the next `step`/`reset`/`deinit`; copy it
    /// if it must outlive the row.
    pub fn columnText(self: *Stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        return ptr[0..len];
    }
};

test "open in-memory, create, insert, and query with a cached statement" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    var ins = try db.prepareCached("INSERT INTO t (name) VALUES (?1);");
    try ins.bindText(1, "alice");
    try std.testing.expect(!try ins.step());

    // Same SQL returns the same (reset) cached statement.
    var ins2 = try db.prepareCached("INSERT INTO t (name) VALUES (?1);");
    try std.testing.expectEqual(ins.handle, ins2.handle);
    try ins2.bindText(1, "bob");
    try std.testing.expect(!try ins2.step());

    var sel = try db.prepareCached("SELECT id, name FROM t ORDER BY id;");
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1), sel.columnInt64(0));
    try std.testing.expectEqualStrings("alice", sel.columnText(1));
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("bob", sel.columnText(1));
    try std.testing.expect(!try sel.step());
}

test "constraint violation maps to error" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    var ins = try db.prepareCached("INSERT INTO t (id, name) VALUES (1, NULL);");
    try std.testing.expectError(Error.Constraint, ins.step());
}
