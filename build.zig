const std = @import("std");

const Arch = enum { aarch64, x86_64 };

pub fn build(b: *std.Build) void {
    const arch = b.option(Arch, "arch", "Target architecture (default: aarch64)") orelse .aarch64;
    const optimize = b.standardOptimizeOption(.{});

    // Bare-metal targets: no OS, no SIMD/FPU so the kernel never touches
    // vector state (interrupt handlers won't have to save it).
    const target = switch (arch) {
        .x86_64 => blk: {
            const x86 = std.Target.x86.Feature;
            var add = std.Target.Cpu.Feature.Set.empty;
            var sub = std.Target.Cpu.Feature.Set.empty;
            add.addFeature(@intFromEnum(x86.soft_float));
            sub.addFeature(@intFromEnum(x86.mmx));
            sub.addFeature(@intFromEnum(x86.sse));
            sub.addFeature(@intFromEnum(x86.sse2));
            sub.addFeature(@intFromEnum(x86.avx));
            sub.addFeature(@intFromEnum(x86.avx2));
            break :blk b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = add,
                .cpu_features_sub = sub,
            });
        },
        .aarch64 => blk: {
            const a64 = std.Target.aarch64.Feature;
            var sub = std.Target.Cpu.Feature.Set.empty;
            sub.addFeature(@intFromEnum(a64.fp_armv8));
            sub.addFeature(@intFromEnum(a64.neon));
            break :blk b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_sub = sub,
            });
        },
    };

    const kernel = b.addExecutable(.{
        .name = "kernel",
        // Zig 0.16's self-hosted backends can't handle some of our
        // bare-metal needs yet; the LLVM backend can.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // x86_64 kernel code model places code in the top 2 GiB;
            // aarch64 reaches it with the default small model (PC-relative).
            .code_model = switch (arch) {
                .x86_64 => .kernel,
                .aarch64 => .small,
            },
            // Red zone is an x86_64 SysV concept; interrupts would clobber it.
            .red_zone = switch (arch) {
                .x86_64 => false,
                .aarch64 => null,
            },
        }),
    });
    kernel.setLinkerScript(b.path(b.fmt("linker-{s}.ld", .{@tagName(arch)})));
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.pie = false;
    b.installArtifact(kernel);

    const iso_name = b.fmt("cedar-{s}.iso", .{@tagName(arch)});
    const iso_cmd = b.addSystemCommand(&.{ "scripts/mkiso.sh", @tagName(arch) });
    iso_cmd.step.dependOn(b.getInstallStep());
    const iso_step = b.step("iso", "Build bootable ISO for the selected arch");
    iso_step.dependOn(&iso_cmd.step);

    const run_cmd = switch (arch) {
        .x86_64 => b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-M",       "q35",
            "-cdrom",   iso_name,
            "-serial",  "stdio",
            "-display", "none",
            "-no-reboot",
        }),
        // UEFI-only on ARM: edk2 firmware ships with Homebrew's QEMU.
        .aarch64 => b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",      "virt",
            "-cpu",    "cortex-a72",
            "-m",      "2G",
            "-device", "ramfb",
            "-bios",   "/usr/local/share/qemu/edk2-aarch64-code.fd",
            "-cdrom",  iso_name,
            "-serial", "stdio",
        }),
    };
    run_cmd.step.dependOn(&iso_cmd.step);
    const run_step = b.step("run", "Boot Cedar in QEMU (serial on stdio)");
    run_step.dependOn(&run_cmd.step);
}
