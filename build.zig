const std = @import("std");

// Cedar is ARM-only by design: aarch64 is the sole supported architecture
// (Apple Silicon via QEMU/HVF, Raspberry Pi hardware later).
//
// No bootloader: the kernel is a raw image with a Linux arm64 boot header,
// loaded directly by QEMU's -kernel (and later by the Raspberry Pi
// firmware as kernel8.img).

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Bare-metal target: no OS, no FP/SIMD so the kernel never touches
    // vector state (interrupt handlers won't have to save it).
    const a64 = std.Target.aarch64.Feature;
    var sub = std.Target.Cpu.Feature.Set.empty;
    sub.addFeature(@intFromEnum(a64.fp_armv8));
    sub.addFeature(@intFromEnum(a64.neon));
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = sub,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        // Zig 0.16's self-hosted backends can't handle some of our
        // bare-metal needs yet; the LLVM backend can.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .small,
        }),
    });
    kernel.root_module.addAssemblyFile(b.path("src/boot.S"));
    kernel.setLinkerScript(b.path("linker-aarch64.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    b.installArtifact(kernel);

    // Strip the ELF container down to the raw bytes QEMU/RPi firmware load.
    const image = kernel.addObjCopy(.{ .format = .bin });
    const install_image = b.addInstallBinFile(image.getOutput(), "cedar.img");
    b.getInstallStep().dependOn(&install_image.step);

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",       "virt",
        "-cpu",     "cortex-a72",
        "-m",       "2G",
        "-kernel",  "zig-out/bin/cedar.img",
        "-serial",  "stdio",
        "-display", "none",
    });
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Boot Cedar in QEMU (serial on stdio)");
    run_step.dependOn(&run_cmd.step);
}
