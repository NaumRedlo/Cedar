const std = @import("std");

// Cedar is ARM-only and QEMU-only by design: aarch64 on qemu-system-
// aarch64's `virt` machine is the sole supported target.
//
// No bootloader: the kernel is a raw image with a Linux arm64 boot
// header, loaded directly by QEMU's -kernel.

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const test_exception = b.option(
        bool,
        "test-exception",
        "Execute brk #0 after boot to exercise the exception path",
    ) orelse false;
    const test_fault = b.option(
        bool,
        "test-fault",
        "Read an unmapped address after MMU enable to exercise the fault path",
    ) orelse false;

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
    const options = b.addOptions();
    options.addOption(bool, "test_exception", test_exception);
    options.addOption(bool, "test_fault", test_fault);
    kernel.root_module.addOptions("build_options", options);

    kernel.root_module.addAssemblyFile(b.path("src/boot.S"));
    kernel.root_module.addAssemblyFile(b.path("src/vectors.S"));
    kernel.setLinkerScript(b.path("linker-aarch64.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    b.installArtifact(kernel);

    // Userland programs: freestanding EL0 ELF executables, embedded into
    // the kernel and installed into /Programs at boot. The kernel's ELF
    // loader maps their segments at run time.
    const wf = b.addWriteFiles();
    var embed_source: []const u8 = "";
    for ([_][]const u8{ "hello", "crash", "reader", "cat" }) |prog| {
        const exe = b.addExecutable(.{
            .name = prog,
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("userland/{s}.zig", .{prog})),
                .target = target,
                .optimize = .ReleaseSmall,
            }),
        });
        exe.setLinkerScript(b.path("userland/user.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        exe.pie = false;
        _ = wf.addCopyFile(exe.getEmittedBin(), b.fmt("{s}.elf", .{prog}));
        embed_source = b.fmt("{s}pub const {s} = @embedFile(\"{s}.elf\");\n", .{ embed_source, prog, prog });
    }
    const embed_file = wf.add("userprogs.zig", embed_source);
    kernel.root_module.addAnonymousImport("userprogs", .{ .root_source_file = embed_file });

    // Strip the ELF container down to the raw bytes QEMU's -kernel loads.
    const image = kernel.addObjCopy(.{ .format = .bin });
    const install_image = b.addInstallBinFile(image.getOutput(), "cedar.img");
    b.getInstallStep().dependOn(&install_image.step);

    // A 16 MiB raw disk for Cedar FS snapshots, created on first run.
    const mkdisk = b.addSystemCommand(&.{
        "sh", "-c", "[ -f disk.img ] || qemu-img create -f raw disk.img 16M",
    });

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",      "virt",
        "-cpu",    "cortex-a72",
        "-smp",    "4",
        "-m",      "2G",
        "-kernel", "zig-out/bin/cedar.img",
        "-device", "ramfb",
        "-drive",  "file=disk.img,if=none,format=raw,id=hd0",
        "-device", "virtio-blk-device,drive=hd0",
        "-device", "virtio-keyboard-device",
        "-device", "virtio-tablet-device",
        "-serial", "stdio",
    });
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&mkdisk.step);
    const run_step = b.step("run", "Boot Cedar in QEMU (display window + serial on stdio)");
    run_step.dependOn(&run_cmd.step);

    // Pure-logic modules (DTB parser, frame allocator) are unit-tested
    // on the host.
    const test_step = b.step("test", "Run host unit tests");
    for ([_][]const u8{ "src/dtb.zig", "src/pmm.zig", "src/fs.zig", "src/elf.zig" }) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = b.resolveTargetQuery(.{}),
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
