const builtin = @import("builtin");

pub const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("Cedar is ARM-only: aarch64 is the sole supported architecture"),
};
