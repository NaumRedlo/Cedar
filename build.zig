const std = @import("std");

pub fn build(b: *std.Build) void {
    // Bare-metal x86_64: no OS, no SIMD/FPU (soft float), red zone disabled
    // because interrupt handlers would clobber it.
    const x86 = std.Target.x86.Feature;
    var features_add = std.Target.Cpu.Feature.Set.empty;
    var features_sub = std.Target.Cpu.Feature.Set.empty;
    features_add.addFeature(@intFromEnum(x86.soft_float));
    features_sub.addFeature(@intFromEnum(x86.mmx));
    features_sub.addFeature(@intFromEnum(x86.sse));
    features_sub.addFeature(@intFromEnum(x86.sse2));
    features_sub.addFeature(@intFromEnum(x86.avx));
    features_sub.addFeature(@intFromEnum(x86.avx2));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = features_add,
        .cpu_features_sub = features_sub,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        // Zig 0.16's self-hosted x86_64 backend can't handle soft-float
        // f128 (ubsan_rt) yet; the LLVM backend can.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .red_zone = false,
        }),
    });
    kernel.setLinkerScript(b.path("linker.ld"));
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.pie = false;
    b.installArtifact(kernel);

    const iso_cmd = b.addSystemCommand(&.{"scripts/mkiso.sh"});
    iso_cmd.step.dependOn(b.getInstallStep());
    const iso_step = b.step("iso", "Build bootable cedar.iso");
    iso_step.dependOn(&iso_cmd.step);

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",       "q35",
        "-cdrom",   "cedar.iso",
        "-serial",  "stdio",
        "-display", "none",
        "-no-reboot",
    });
    run_cmd.step.dependOn(&iso_cmd.step);
    const run_step = b.step("run", "Boot Cedar in QEMU (serial on stdio)");
    run_step.dependOn(&run_cmd.step);
}
