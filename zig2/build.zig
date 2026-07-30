const std = @import("std");

const IoMode = enum { std, zio };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const io_mode = b.option(IoMode, "io", "IO backend: std (Io.Threaded, default) or zio (stackful coroutines)") orelse .std;

    const options = b.addOptions();
    options.addOption(IoMode, "io_mode", io_mode);

    const exe = b.addExecutable(.{
        .name = "zig2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    exe.root_module.addOptions("options", options);

    const datastar = b.dependency("datastar", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("datastar", datastar.module("datastar"));

    const zts = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zts", zts.module("zts"));

    if (io_mode == .zio) {
        const zio = b.dependency("zio", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zio", zio.module("zio"));
    }

    linkSqlite(b, exe.root_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the App");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

/// Compile and link the vendored SQLite amalgamation into `mod`.
fn linkSqlite(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_ENABLE_STAT4",
        },
    });
}
