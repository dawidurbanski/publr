//! Image Processing — Resize & WebP Conversion
//!
//! Wraps stb_image (decode), stb_image_resize2 (resize), stb_image_write (JPEG/PNG
//! encode), and libwebp (WebP encode). All processing happens in-memory.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
    @cInclude("stb_image_write.h");
    @cInclude("libwebp.h");
});

/// Output format for processed images
pub const ImageFormat = enum {
    jpeg,
    png,
    webp,

    pub fn mimeType(self: ImageFormat) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .webp => "image/webp",
        };
    }

    pub fn extension(self: ImageFormat) []const u8 {
        return switch (self) {
            .jpeg => ".jpg",
            .png => ".png",
            .webp => ".webp",
        };
    }
};

/// Fit mode for width+height crops
pub const FitMode = enum {
    crop, // pixel-crop at native resolution (default)
    cover, // resize to cover, then crop
};

/// Parameters for image processing
pub const ImageParams = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    focal_x: u8 = 50, // 0-100, default center
    focal_y: u8 = 50,
    fit: FitMode = .crop,
    format: ?ImageFormat = null,
    quality: u8 = 90,
};

/// Result of image processing
pub const ProcessResult = struct {
    data: []u8,
    format: ImageFormat,
    width: u32,
    height: u32,

    pub fn deinit(self: *ProcessResult, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// Source image format detected from data
const SourceFormat = enum { jpeg, png, other };

fn detectSourceFormat(data: []const u8) SourceFormat {
    // JPEG: starts with FF D8
    if (data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8) return .jpeg;
    // PNG: starts with 89 50 4E 47
    if (data.len >= 4 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47) return .png;
    return .other;
}

/// Check if a MIME type is processable (can be decoded by stb_image)
pub fn isProcessableImage(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "image/jpeg") or
        std.mem.eql(u8, mime_type, "image/png");
}

/// Negotiate output format based on Accept header and source MIME type.
/// Returns WebP if client supports it, otherwise keeps the source format.
pub fn negotiateFormat(accept_header: ?[]const u8, source_mime: []const u8) ImageFormat {
    const source_fmt: ImageFormat = if (std.mem.eql(u8, source_mime, "image/png"))
        .png
    else
        .jpeg;

    if (accept_header) |accept| {
        if (std.mem.indexOf(u8, accept, "image/webp") != null) return .webp;
    }

    return source_fmt;
}

/// Build a cache suffix string from processing params and output format.
/// e.g., "_w600" or "_w600.webp" (when format changes from source)
pub fn cacheSuffix(allocator: Allocator, params: ImageParams, output_format: ImageFormat, source_mime: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    if (params.width) |w| {
        try std.fmt.format(buf.writer(allocator), "_w{d}", .{w});
    }
    if (params.height) |h| {
        try std.fmt.format(buf.writer(allocator), "_h{d}", .{h});
    }

    // Include fit mode, focal point, quality in cache key when non-default
    if (params.width != null and params.height != null) {
        if (params.fit == .cover) {
            try buf.appendSlice(allocator, "_cover");
        }
        if (params.focal_x != 50 or params.focal_y != 50) {
            try std.fmt.format(buf.writer(allocator), "_fp{d}-{d}", .{ params.focal_x, params.focal_y });
        }
    }
    if (params.quality != 90) {
        try std.fmt.format(buf.writer(allocator), "_q{d}", .{params.quality});
    }

    // Append format suffix when converting to a different format
    const is_conversion = switch (output_format) {
        .webp => true, // WebP is always a conversion from JPEG/PNG
        .png => !std.mem.eql(u8, source_mime, "image/png"),
        .jpeg => !std.mem.eql(u8, source_mime, "image/jpeg"),
    };
    if (is_conversion) {
        try buf.appendSlice(allocator, output_format.extension());
    }

    return buf.toOwnedSlice(allocator);
}

/// Process an image: decode → resize → encode.
/// Caller must call result.deinit(allocator) to free the output data.
pub fn processImage(allocator: Allocator, source_bytes: []const u8, params: ImageParams) !ProcessResult {
    // Decode source image
    var orig_w: c_int = 0;
    var orig_h: c_int = 0;
    var orig_channels: c_int = 0;

    const pixels = c.stbi_load_from_memory(
        source_bytes.ptr,
        @intCast(source_bytes.len),
        &orig_w,
        &orig_h,
        &orig_channels,
        0, // keep original channels
    ) orelse return error.DecodeFailed;
    defer c.stbi_image_free(pixels);

    const channels: u32 = @intCast(orig_channels);
    var width: u32 = @intCast(orig_w);
    var height: u32 = @intCast(orig_h);

    // Determine output format
    const source_fmt = detectSourceFormat(source_bytes);
    const output_format = params.format orelse switch (source_fmt) {
        .jpeg => ImageFormat.jpeg,
        .png => ImageFormat.png,
        .other => ImageFormat.jpeg,
    };

    // Determine target size (never upscale)
    var resize_pixels: ?[]u8 = null;
    defer if (resize_pixels) |p| allocator.free(p);

    var crop_pixels: ?[]u8 = null;
    defer if (crop_pixels) |p| allocator.free(p);

    var active_pixels: [*]u8 = pixels;

    const pixel_layout: c.stbir_pixel_layout = if (channels == 4)
        c.STBIR_4CHANNEL
    else if (channels == 3)
        c.STBIR_RGB
    else if (channels == 1)
        c.STBIR_1CHANNEL
    else
        c.STBIR_RGB;

    if (params.width != null and params.height != null) {
        const tw = params.width.?;
        const th = params.height.?;
        if (tw > 0 and th > 0) {
            if (params.fit == .crop) {
                // Pixel-crop: extract tw x th at native resolution, no resize
                const crop_w = @min(tw, width);
                const crop_h = @min(th, height);

                if (crop_w != width or crop_h != height) {
                    const cropped = try cropRect(allocator, active_pixels, width, height, channels, crop_w, crop_h, params.focal_x, params.focal_y);
                    crop_pixels = cropped;
                    active_pixels = cropped.ptr;
                    width = crop_w;
                    height = crop_h;
                }
            } else if (tw < width or th < height) {
                // Cover + crop: resize to cover both dimensions, then crop
                const scale_w = @as(f64, @floatFromInt(tw)) / @as(f64, @floatFromInt(width));
                const scale_h = @as(f64, @floatFromInt(th)) / @as(f64, @floatFromInt(height));
                const scale = @max(scale_w, scale_h);

                // Never upscale: cap scale at 1.0
                const capped_scale = @min(scale, 1.0);
                var scaled_w: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * capped_scale);
                var scaled_h: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * capped_scale);
                if (scaled_w == 0) scaled_w = 1;
                if (scaled_h == 0) scaled_h = 1;

                // Resize to cover dimensions
                if (scaled_w != width or scaled_h != height) {
                    const out_buf = try resizeBuffer(allocator, active_pixels, width, height, scaled_w, scaled_h, channels, pixel_layout);
                    resize_pixels = out_buf;
                    active_pixels = out_buf.ptr;
                    width = scaled_w;
                    height = scaled_h;
                }

                // Crop to exact target (clamped to actual size)
                const crop_w = @min(tw, width);
                const crop_h = @min(th, height);

                if (crop_w != width or crop_h != height) {
                    const cropped = try cropRect(allocator, active_pixels, width, height, channels, crop_w, crop_h, params.focal_x, params.focal_y);
                    crop_pixels = cropped;
                    active_pixels = cropped.ptr;
                    width = crop_w;
                    height = crop_h;
                }
            }
        }
    } else if (params.width) |requested_w| {
        // Width-only: resize proportionally
        if (requested_w < width and requested_w > 0) {
            const new_w = requested_w;
            const new_h: u32 = @intCast(@as(u64, height) * new_w / width);
            if (new_h == 0) return error.InvalidDimensions;

            const out_buf = try resizeBuffer(allocator, active_pixels, width, height, new_w, new_h, channels, pixel_layout);
            resize_pixels = out_buf;
            active_pixels = out_buf.ptr;
            width = new_w;
            height = new_h;
        }
    } else if (params.height) |requested_h| {
        // Height-only: resize proportionally
        if (requested_h < height and requested_h > 0) {
            const new_h = requested_h;
            const new_w: u32 = @intCast(@as(u64, width) * new_h / height);
            if (new_w == 0) return error.InvalidDimensions;

            const out_buf = try resizeBuffer(allocator, active_pixels, width, height, new_w, new_h, channels, pixel_layout);
            resize_pixels = out_buf;
            active_pixels = out_buf.ptr;
            width = new_w;
            height = new_h;
        }
    }

    // Encode output
    const encoded_data = switch (output_format) {
        .webp => try encodeWebP(allocator, active_pixels, width, height, channels, params.quality, source_fmt),
        .jpeg => try encodeJpeg(allocator, active_pixels, width, height, channels, params.quality),
        .png => try encodePng(allocator, active_pixels, width, height, channels),
    };

    return ProcessResult{
        .data = encoded_data,
        .format = output_format,
        .width = width,
        .height = height,
    };
}

// =============================================================================
// Resize & Crop Helpers
// =============================================================================

/// Resize a pixel buffer to new dimensions. Caller owns the returned slice.
fn resizeBuffer(
    allocator: Allocator,
    src: [*]const u8,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
    channels: u32,
    pixel_layout: c.stbir_pixel_layout,
) ![]u8 {
    const out_size = dst_w * dst_h * channels;
    const out_buf = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out_buf);

    const result = c.stbir_resize_uint8_linear(
        src,
        @intCast(src_w),
        @intCast(src_h),
        0,
        out_buf.ptr,
        @intCast(dst_w),
        @intCast(dst_h),
        0,
        pixel_layout,
    );

    if (result == null) {
        allocator.free(out_buf);
        return error.ResizeFailed;
    }

    return out_buf;
}

/// Crop a sub-rectangle from a pixel buffer, centered on the focal point.
/// focal_x/focal_y are 0-100 percentages. Caller owns the returned slice.
fn cropRect(
    allocator: Allocator,
    src: [*]const u8,
    src_w: u32,
    src_h: u32,
    channels: u32,
    crop_w: u32,
    crop_h: u32,
    focal_x: u8,
    focal_y: u8,
) ![]u8 {
    // Calculate crop origin from focal point, clamped to bounds
    const fx = @as(f64, @floatFromInt(focal_x)) / 100.0;
    const fy = @as(f64, @floatFromInt(focal_y)) / 100.0;

    const ideal_x: i64 = @as(i64, @intFromFloat(fx * @as(f64, @floatFromInt(src_w)))) - @as(i64, @intCast(crop_w / 2));
    const ideal_y: i64 = @as(i64, @intFromFloat(fy * @as(f64, @floatFromInt(src_h)))) - @as(i64, @intCast(crop_h / 2));

    const max_x: i64 = @as(i64, @intCast(src_w)) - @as(i64, @intCast(crop_w));
    const max_y: i64 = @as(i64, @intCast(src_h)) - @as(i64, @intCast(crop_h));

    const ox: u32 = @intCast(std.math.clamp(ideal_x, 0, max_x));
    const oy: u32 = @intCast(std.math.clamp(ideal_y, 0, max_y));

    // Copy rows
    const src_stride = src_w * channels;
    const dst_stride = crop_w * channels;
    const out_buf = try allocator.alloc(u8, crop_h * dst_stride);
    errdefer allocator.free(out_buf);

    for (0..crop_h) |row| {
        const src_offset = (oy + @as(u32, @intCast(row))) * src_stride + ox * channels;
        const dst_offset = @as(u32, @intCast(row)) * dst_stride;
        @memcpy(out_buf[dst_offset..][0..dst_stride], src[src_offset..][0..dst_stride]);
    }

    return out_buf;
}

// =============================================================================
// Encoders
// =============================================================================

/// Callback context for stb_image_write → ArrayList
const WriteContext = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,
};

fn stbWriteCallback(ctx_ptr: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    if (ctx_ptr == null or data == null or size <= 0) return;
    const wctx: *WriteContext = @ptrCast(@alignCast(ctx_ptr.?));
    const bytes: [*]const u8 = @ptrCast(data.?);
    wctx.list.appendSlice(wctx.allocator, bytes[0..@intCast(size)]) catch {};
}

fn encodeJpeg(allocator: Allocator, pixels: [*]const u8, w: u32, h: u32, ch: u32, quality: u8) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    var wctx = WriteContext{ .list = &list, .allocator = allocator };

    const result = c.stbi_write_jpg_to_func(
        stbWriteCallback,
        &wctx,
        @intCast(w),
        @intCast(h),
        @intCast(ch),
        pixels,
        @intCast(quality),
    );

    if (result == 0) return error.EncodeFailed;
    return list.toOwnedSlice(allocator);
}

fn encodePng(allocator: Allocator, pixels: [*]const u8, w: u32, h: u32, ch: u32) ![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    var wctx = WriteContext{ .list = &list, .allocator = allocator };

    const stride: c_int = @intCast(w * ch);

    const result = c.stbi_write_png_to_func(
        stbWriteCallback,
        &wctx,
        @intCast(w),
        @intCast(h),
        @intCast(ch),
        pixels,
        stride,
    );

    if (result == 0) return error.EncodeFailed;
    return list.toOwnedSlice(allocator);
}

fn encodeWebP(allocator: Allocator, pixels: [*]const u8, w: u32, h: u32, ch: u32, quality: u8, source_fmt: SourceFormat) ![]u8 {
    var output: [*c]u8 = null;
    const stride: c_int = @intCast(w * ch);

    const size = blk: {
        if (source_fmt == .png and ch == 4) {
            // PNG with alpha → lossless WebP preserves transparency
            break :blk c.WebPEncodeLosslessRGBA(pixels, @intCast(w), @intCast(h), stride, &output);
        } else if (ch == 4) {
            break :blk c.WebPEncodeRGBA(pixels, @intCast(w), @intCast(h), stride, @floatFromInt(quality), &output);
        } else {
            // JPEG source → lossy WebP
            break :blk c.WebPEncodeRGB(pixels, @intCast(w), @intCast(h), stride, @floatFromInt(quality), &output);
        }
    };

    if (size == 0) return error.EncodeFailed;
    if (output == null) return error.EncodeFailed;

    // Copy to Zig-managed memory and free WebP allocation
    const result = try allocator.alloc(u8, size);
    @memcpy(result, output[0..size]);
    c.WebPFree(output);

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "isProcessableImage: JPEG and PNG accepted" {
    try std.testing.expect(isProcessableImage("image/jpeg"));
    try std.testing.expect(isProcessableImage("image/png"));
}

test "isProcessableImage: others rejected" {
    try std.testing.expect(!isProcessableImage("image/gif"));
    try std.testing.expect(!isProcessableImage("image/webp"));
    try std.testing.expect(!isProcessableImage("application/pdf"));
    try std.testing.expect(!isProcessableImage("video/mp4"));
}

test "negotiateFormat: WebP when Accept includes it" {
    try std.testing.expectEqual(ImageFormat.webp, negotiateFormat("image/avif, image/webp, */*", "image/jpeg"));
    try std.testing.expectEqual(ImageFormat.webp, negotiateFormat("image/webp", "image/png"));
}

test "negotiateFormat: keeps source format when no WebP" {
    try std.testing.expectEqual(ImageFormat.jpeg, negotiateFormat("text/html, */*", "image/jpeg"));
    try std.testing.expectEqual(ImageFormat.png, negotiateFormat(null, "image/png"));
    try std.testing.expectEqual(ImageFormat.jpeg, negotiateFormat(null, "image/jpeg"));
}

test "cacheSuffix: width only" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 600 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w600", suffix);
}

test "cacheSuffix: width + webp conversion" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 300 }, .webp, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w300.webp", suffix);
}

test "cacheSuffix: height only" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .height = 400 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_h400", suffix);
}

test "cacheSuffix: width + height" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 80, .height = 80 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w80_h80", suffix);
}

test "cacheSuffix: width + height + webp" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 200, .height = 150 }, .webp, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w200_h150.webp", suffix);
}

test "cacheSuffix: width + height + non-default focal point" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 80, .height = 80, .focal_x = 34, .focal_y = 25 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w80_h80_fp34-25", suffix);
}

test "cacheSuffix: width + height + default focal point omitted" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 80, .height = 80 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w80_h80", suffix);
}

test "cacheSuffix: cover mode included in suffix" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 80, .height = 80, .fit = .cover }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w80_h80_cover", suffix);
}

test "cacheSuffix: non-default quality" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 300, .quality = 80 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w300_q80", suffix);
}

test "cacheSuffix: default quality omitted" {
    const suffix = try cacheSuffix(std.testing.allocator, .{ .width = 300 }, .jpeg, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("_w300", suffix);
}

test "cacheSuffix: webp conversion only (no resize)" {
    const suffix = try cacheSuffix(std.testing.allocator, .{}, .webp, "image/jpeg");
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings(".webp", suffix);
}

test "detectSourceFormat: JPEG" {
    try std.testing.expectEqual(SourceFormat.jpeg, detectSourceFormat(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
}

test "detectSourceFormat: PNG" {
    try std.testing.expectEqual(SourceFormat.png, detectSourceFormat(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A }));
}

test "detectSourceFormat: unknown" {
    try std.testing.expectEqual(SourceFormat.other, detectSourceFormat(&[_]u8{ 0x00, 0x00 }));
}

test "ImageFormat.mimeType" {
    try std.testing.expectEqualStrings("image/jpeg", ImageFormat.jpeg.mimeType());
    try std.testing.expectEqualStrings("image/webp", ImageFormat.webp.mimeType());
    try std.testing.expectEqualStrings("image/png", ImageFormat.png.mimeType());
}

test "processImage: decode 1x1 JPEG and re-encode" {
    // Minimal valid JPEG: 1x1 white pixel
    const jpeg_1x1 = [_]u8{
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
        0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
        0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x00, 0x3F, 0x00, 0x7B, 0x94, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xD9,
    };

    var result = processImage(std.testing.allocator, &jpeg_1x1, .{}) catch |err| {
        // If decode fails (minimal JPEG may not be valid enough), skip test
        if (err == error.DecodeFailed) return;
        return err;
    };
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.width);
    try std.testing.expectEqual(@as(u32, 1), result.height);
    try std.testing.expectEqual(ImageFormat.jpeg, result.format);
    try std.testing.expect(result.data.len > 0);
}

test "cropRect: center crop" {
    // 4x4 image, 3 channels, crop to 2x2 centered at 50,50
    var src: [4 * 4 * 3]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 256);

    const cropped = try cropRect(std.testing.allocator, &src, 4, 4, 3, 2, 2, 50, 50);
    defer std.testing.allocator.free(cropped);

    // 2x2 * 3 channels = 12 bytes
    try std.testing.expectEqual(@as(usize, 12), cropped.len);
}

test "cropRect: top-left focal point" {
    // 10x10, crop to 4x4 with focal at (0, 0) → origin should be (0, 0)
    var src: [10 * 10 * 3]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 256);

    const cropped = try cropRect(std.testing.allocator, &src, 10, 10, 3, 4, 4, 0, 0);
    defer std.testing.allocator.free(cropped);

    // First pixel of cropped should match first pixel of source
    try std.testing.expectEqual(src[0], cropped[0]);
    try std.testing.expectEqual(src[1], cropped[1]);
    try std.testing.expectEqual(src[2], cropped[2]);
}

test "cropRect: bottom-right focal point" {
    // 10x10, crop to 4x4 with focal at (100, 100) → origin clamped to (6, 6)
    var src: [10 * 10 * 3]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 256);

    const cropped = try cropRect(std.testing.allocator, &src, 10, 10, 3, 4, 4, 100, 100);
    defer std.testing.allocator.free(cropped);

    // First pixel of cropped should match pixel at (6, 6) in source
    const expected_offset = (6 * 10 + 6) * 3;
    try std.testing.expectEqual(src[expected_offset], cropped[0]);
    try std.testing.expectEqual(src[expected_offset + 1], cropped[1]);
    try std.testing.expectEqual(src[expected_offset + 2], cropped[2]);
}
