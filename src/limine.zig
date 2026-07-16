// Limine boot protocol definitions. All magic numbers and struct layouts
// are taken verbatim from limine/limine.h (v9.x) — do not invent them.

const COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
const COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

// The bootloader scans the .limine_requests section between these markers.
pub export var requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

// Base revision 3: the bootloader sets the last element to 0 if supported.
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3,
};

pub export var requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*volatile HhdmResponse = null,
};

pub export var hhdm_request: HhdmRequest linksection(".limine_requests") = .{};

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    // Response revision 1
    mode_count: u64,
    modes: ?*anyopaque,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: ?[*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*volatile FramebufferResponse = null,
};

pub export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = .{};

pub fn baseRevisionSupported() bool {
    return @as(*volatile u64, &base_revision[2]).* == 0;
}
