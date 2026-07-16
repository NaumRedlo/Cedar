const std = @import("std");

// Cedar is ARM-only by design: aarch64 is the sole supported architecture
// (Apple Silicon via QEMU/HVF, Raspberry Pi hardware later).

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
            // The small code model reaches the top-2GiB link address
            // through PC-relative addressing.
            .code_model = .small,
        }),
    });
    kernel.setLinkerScript(b.path("linker-aarch64.ld"));
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.pie = false;
    b.installArtifact(kernel);

    const iso_cmd = b.addSystemCommand(&.{"scripts/mkiso.sh"});
    iso_cmd.step.dependOn(b.getInstallStep());
    const iso_step = b.step("iso", "Build bootable cedar.iso");
    iso_step.dependOn(&iso_cmd.step);

    // UEFI-only on ARM: edk2 firmware ships with Homebrew's QEMU.
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",      "virt",
        "-cpu",    "cortex-a72",
        "-m",      "2G",
        "-device", "ramfb",
        "-bios",   "/usr/local/share/qemu/edk2-aarch64-code.fd",
        "-cdrom",  "cedar.iso",
        "-serial", "stdio",
    });
    run_cmd.step.dependOn(&iso_cmd.step);
    const run_step = b.step("run", "Boot Cedar in QEMU (serial on stdio)");
    run_step.dependOn(&run_cmd.step);
}
