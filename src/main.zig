const std = @import("std");
const build_options = @import("build_options");
const arch = @import("arch.zig").impl;
const log = @import("log.zig");
const exceptions = @import("exceptions.zig");
const dtb = @import("dtb.zig");
const mmu = @import("mmu.zig");
const mem = @import("mem.zig");
const heap = @import("heap.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const sched = @import("sched.zig");
const fwcfg = @import("fwcfg.zig");
const ramfb = @import("ramfb.zig");
const console = @import("console.zig");
const input = @import("input.zig");
const shell = @import("shell.zig");
const fs = @import("fs.zig");
const user = @import("user.zig");
const userprogs = @import("userprogs");

const kprint = log.kprint;
const kprintf = log.kprintf;

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    kprint("KERNEL PANIC: ");
    kprint(msg);
    kprint("\n");
    arch.halt();
}

fn initFs() void {
    fs.global = fs.Fs.init(heap.allocator()) catch {
        kprint("fs: init failed\n");
        return;
    };
    fs.global.clock = &timer.now;
    fs.ready = true;

    const boot = struct {
        fn run() !void {
            _ = try fs.global.mkdir("/System");
            _ = try fs.global.mkdir("/Programs");
            _ = try fs.global.mkdir("/Home");
            try fs.global.write("/System/version.txt", "Cedar 0.1 (aarch64)\nno bootloader, no mercy\n");
            try fs.global.write("/Home/welcome.txt", "Welcome home.\nThis file lives in RAM and in the moment.\n");
            try fs.global.write("/Programs/hello", userprogs.hello);
            try fs.global.write("/Programs/crash", userprogs.crash);
        }
    };
    boot.run() catch {
        kprint("fs: bootstrap failed\n");
        return;
    };
    kprint("fs: Cedar FS mounted at / (RAM, case-insensitive)\n");
}


// Entered from boot.S on core 0 in the higher half: MMU on, TTBR0
// walks disabled, stack ready, BSS cleared. dtb_virt is the device
// tree address through the direct map.
export fn kmain(dtb_virt: usize) callconv(.c) noreturn {
    arch.init();
    exceptions.install();

    kprint("Hello, Cedar!\n\n");
    kprintf("boot: direct kernel image, no bootloader, EL{d}\n", .{arch.currentEl()});
    kprintf("mmu: higher half, hhdm at 0x{x}, low half {s}\n", .{
        mmu.HHDM,
        if (mmu.lowHalfDisabled()) @as([]const u8, "disabled") else "ENABLED?!",
    });
    kprintf("exception vectors: installed (VBAR_EL1)\n", .{});

    var dt_store: ?dtb.Dtb = null;
    var ram: ?dtb.Reg = null;
    if (dtb.Dtb.init(dtb_virt)) |dt| {
        kprintf("dtb: ok at 0x{x}, version {d}, {d} bytes\n", .{ dtb_virt, dt.version, dt.raw.len });
        if (dt.rootProp("model")) |model| {
            kprintf("machine: {s}\n", .{dtb.str(model)});
        }
        if (dt.findByNodePrefix("memory")) |m| {
            kprintf("memory: 0x{x} + 0x{x} ({d} MiB)\n", .{ m.addr, m.size, m.size >> 20 });
            ram = m;
        }
        if (dt.findByCompatible("arm,pl011")) |u| {
            arch.setUartBase(mmu.p2v(u.addr));
            kprintf("uart: pl011 at phys 0x{x} (dtb-discovered, via hhdm)\n", .{u.addr});
        }
        dt_store = dt;
    } else |err| {
        kprintf("dtb: invalid at 0x{x} ({s})\n", .{ dtb_virt, @errorName(err) });
    }

    if (dt_store) |*dt| {
        if (ram) |m| {
            mem.init(dt, m, dtb_virt);
            kprintf("pmm: {d} MiB free of {d} MiB ({d} frames)\n", .{
                mem.freeMiB(), mem.totalMiB(), mem.frames.frames,
            });

            const f = mem.frames.alloc().?;
            kprintf("pmm: test frame at 0x{x}, freeing it back\n", .{f});
            mem.frames.free(f);

            if (heap.init(1024)) {
                kprint("heap: 4 MiB online\n");
                initFs();
            } else {
                kprint("heap: init failed\n");
            }

            if (user.init()) {
                kprint("user: EL0 ready, low half handed to processes\n");
            } else {
                kprint("user: init failed\n");
            }
        }
    }

    if (dt_store) |*dt| {
        var regs: [2]dtb.Reg = undefined;
        if (dt.findRegsByCompatible("arm,cortex-a15-gic", &regs) >= 2) {
            gic.init(mmu.p2v(regs[0].addr), mmu.p2v(regs[1].addr));
            kprintf("gic: v2, distributor 0x{x}, cpu interface 0x{x} (phys, via hhdm)\n", .{ regs[0].addr, regs[1].addr });
            timer.init(10);
            sched.init();
            arch.enableIrqs();
            kprint("irq: unmasked, ticking\n");

            // Display: fw_cfg + ramfb bring the framebuffer console back.
            if (dt.findByCompatible("qemu,fw-cfg-mmio")) |fc| {
                if (fwcfg.init(mmu.p2v(fc.addr))) {
                    if (ramfb.init(1024, 768)) |fb| {
                        console.init(fb);
                        log.console_enabled = true;
                        kprintf("display: ramfb {d}x{d}, console mirrored to screen\n", .{ fb.width, fb.height });
                    } else {
                        kprint("display: no ramfb (add -device ramfb), serial only\n");
                    }
                } else {
                    kprint("display: fw_cfg signature mismatch, serial only\n");
                }
            }

            // Keyboard: PL011 RX interrupt, INTID from the device tree.
            if (dt.findPropByCompatible("arm,pl011", "interrupts")) |iv| {
                if (dtb.parseGicIrq(iv)) |id| {
                    input.init(id);
                    kprintf("input: uart rx on intid {d}\n", .{id});
                }
            }

            sched.spawn("shell", shell.run) catch |e| kprintf("spawn failed: {s}\n", .{@errorName(e)});
        } else {
            kprint("gic: no v2 controller in dtb, interrupts stay off\n");
        }
    }

    if (build_options.test_exception) {
        kprint("\ntriggering brk #0 to exercise the exception path...\n");
        asm volatile ("brk #0");
    }

    if (build_options.test_fault) {
        kprint("\ndereferencing (near-)null 0x10 — the low half must fault...\n");
        const bad: *volatile u32 = @ptrFromInt(0x10);
        _ = bad.*;
    }

    arch.halt();
}
