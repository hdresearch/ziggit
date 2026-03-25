const std = @import("std");
const interface = @import("interface.zig");

// Platform implementations
const native = @import("native.zig");
const wasi = @import("wasi.zig");
const freestanding = @import("freestanding.zig");

/// Get the current platform implementation based on compile-time target
pub fn getCurrentPlatform() interface.Platform {
    return switch (@import("builtin").target.os.tag) {
        .wasi => wasi.wasi_platform,
        .freestanding => freestanding.freestanding_platform,
        else => native.native_platform,
    };
}

// Re-export types from interface
pub const Platform = interface.Platform;
pub const ArgIterator = interface.ArgIterator;
pub const FileSystem = interface.FileSystem;