const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "brainiac",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    const step = b.step("run", "Run the application");
    step.dependOn(&run.step);
    
    // Used for building the support runtime for standalone
    // user applications. Will be embedded into the brainiac
    // executable as a BLOB.
    // const standalone = b.addExecutable(.{
    //     .name = "standalone",
    //     .root_source_file = b.path("src/Standalone.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(standalone);
}
