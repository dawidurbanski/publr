const std = @import("std");

/// Parsed file from multipart form data
pub const MultipartFile = struct {
    filename: []const u8,
    content_type: []const u8,
    data: []const u8,
};

/// Parse multipart boundary from Content-Type header
pub fn parseMultipartBoundary(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, marker) orelse return null;
    return content_type[idx + marker.len ..];
}

/// Parse a file field from multipart form data
pub fn parseMultipartFile(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) ?MultipartFile {
    // Multipart format: --boundary\r\nHeaders\r\n\r\nData\r\n--boundary--
    // Iterate parts to find one with a filename

    // Build delimiter: "\r\n--" + boundary (dynamic allocation for any boundary length)
    const delim = std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary}) catch return null;
    defer allocator.free(delim);

    // Find first part boundary (starts with --boundary\r\n)
    const start_marker = std.fmt.allocPrint(allocator, "--{s}\r\n", .{boundary}) catch return null;
    defer allocator.free(start_marker);

    var pos = std.mem.indexOf(u8, body, start_marker) orelse return null;
    pos += start_marker.len;

    // Iterate through parts
    while (pos < body.len) {
        // Find end of headers (blank line)
        const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse return null;
        const headers = body[pos .. pos + headers_end];
        const data_start = pos + headers_end + 4;

        // Find end of this part's data
        const data_end_rel = std.mem.indexOf(u8, body[data_start..], delim) orelse body.len - data_start;

        // Check if this part has a filename (file field, not text field)
        if (std.mem.indexOf(u8, headers, "filename=\"")) |_| {
            var filename: []const u8 = "upload";
            var content_type_val: []const u8 = "application/octet-stream";

            // Parse headers for filename and content type
            var hdr_iter = std.mem.splitSequence(u8, headers, "\r\n");
            while (hdr_iter.next()) |header_line| {
                if (std.ascii.startsWithIgnoreCase(header_line, "Content-Disposition:")) {
                    if (std.mem.indexOf(u8, header_line, "filename=\"")) |fn_start| {
                        const name_start = fn_start + "filename=\"".len;
                        if (std.mem.indexOfPos(u8, header_line, name_start, "\"")) |name_end| {
                            filename = header_line[name_start..name_end];
                        }
                    }
                } else if (std.ascii.startsWithIgnoreCase(header_line, "Content-Type:")) {
                    const ct = std.mem.trimLeft(u8, header_line["Content-Type:".len..], " ");
                    if (ct.len > 0) content_type_val = ct;
                }
            }

            // Skip empty file fields (user clicked upload without selecting a file)
            if (filename.len == 0 or data_end_rel == 0) {
                // Fall through to advance to next part
            } else {
                return .{
                    .filename = filename,
                    .content_type = content_type_val,
                    .data = body[data_start .. data_start + data_end_rel],
                };
            }
        }

        // Advance past this part's data + delimiter to next part's headers
        const next_part = data_start + data_end_rel + delim.len;
        // Skip the \r\n after the delimiter to get to the next part's headers
        if (next_part + 2 <= body.len and body[next_part] == '\r' and body[next_part + 1] == '\n') {
            pos = next_part + 2;
        } else {
            break; // End of multipart (--boundary--)
        }
    }

    return null;
}

/// Extract a named text field value from multipart form data
pub fn parseMultipartField(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8, field_name: []const u8) ?[]const u8 {
    const delim = std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary}) catch return null;
    defer allocator.free(delim);

    const start_marker = std.fmt.allocPrint(allocator, "--{s}\r\n", .{boundary}) catch return null;
    defer allocator.free(start_marker);

    var pos = (std.mem.indexOf(u8, body, start_marker) orelse return null) + start_marker.len;

    const name_match = std.fmt.allocPrint(allocator, "name=\"{s}\"", .{field_name}) catch return null;
    defer allocator.free(name_match);

    while (pos < body.len) {
        const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse return null;
        const headers = body[pos .. pos + headers_end];
        const data_start = pos + headers_end + 4;
        const data_end_rel = std.mem.indexOf(u8, body[data_start..], delim) orelse body.len - data_start;

        if (std.mem.indexOf(u8, headers, name_match) != null and std.mem.indexOf(u8, headers, "filename=\"") == null) {
            return body[data_start .. data_start + data_end_rel];
        }

        const next_part = data_start + data_end_rel + delim.len;
        if (next_part + 2 <= body.len and body[next_part] == '\r' and body[next_part + 1] == '\n') {
            pos = next_part + 2;
        } else {
            break;
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "parseMultipartBoundary: extracts boundary from Content-Type" {
    const ct = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const boundary = parseMultipartBoundary(ct);
    try std.testing.expect(boundary != null);
    try std.testing.expectEqualStrings("----WebKitFormBoundary7MA4YWxkTrZu0gW", boundary.?);
}

test "parseMultipartBoundary: returns null for missing boundary" {
    const ct = "multipart/form-data";
    try std.testing.expect(parseMultipartBoundary(ct) == null);
}

test "parseMultipartBoundary: returns null for non-multipart content type" {
    const ct = "application/json";
    try std.testing.expect(parseMultipartBoundary(ct) == null);
}

test "parseMultipartFile: extracts file from multipart body" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Hello, World!" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartFile(std.testing.allocator, body, boundary);
    try std.testing.expect(result != null);
    const file = result.?;
    try std.testing.expectEqualStrings("test.txt", file.filename);
    try std.testing.expectEqualStrings("text/plain", file.content_type);
    try std.testing.expectEqualStrings("Hello, World!", file.data);
}

test "parseMultipartFile: returns null for body with no file field" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Some Title" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartFile(std.testing.allocator, body, boundary);
    try std.testing.expect(result == null);
}

test "parseMultipartFile: skips empty file field and returns null" {
    const boundary = "----TestBoundary";
    // Empty file field: filename present but no data
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"\"\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "\r\n" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartFile(std.testing.allocator, body, boundary);
    try std.testing.expect(result == null);
}

test "parseMultipartFile: defaults content type to application/octet-stream" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"data.bin\"\r\n" ++
        "\r\n" ++
        "binary data here" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartFile(std.testing.allocator, body, boundary);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("application/octet-stream", result.?.content_type);
    try std.testing.expectEqualStrings("data.bin", result.?.filename);
}

test "parseMultipartFile: returns null for empty body" {
    const result = parseMultipartFile(std.testing.allocator, "", "boundary");
    try std.testing.expect(result == null);
}

test "parseMultipartField: extracts text field value" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"folder_id\"\r\n" ++
        "\r\n" ++
        "abc123" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartField(std.testing.allocator, body, boundary, "folder_id");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("abc123", result.?);
}

test "parseMultipartField: returns null for missing field" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"other_field\"\r\n" ++
        "\r\n" ++
        "some value" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartField(std.testing.allocator, body, boundary, "folder_id");
    try std.testing.expect(result == null);
}

test "parseMultipartField: does not match file fields" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file content" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartField(std.testing.allocator, body, boundary, "file");
    try std.testing.expect(result == null);
}

test "parseMultipartField: extracts field from multi-part body with file and text" {
    const boundary = "----TestBoundary";
    const body =
        "------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n" ++
        "\r\n" ++
        "JPEG DATA" ++
        "\r\n------TestBoundary\r\n" ++
        "Content-Disposition: form-data; name=\"folder_id\"\r\n" ++
        "\r\n" ++
        "folder-xyz" ++
        "\r\n------TestBoundary--\r\n";

    const result = parseMultipartField(std.testing.allocator, body, boundary, "folder_id");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("folder-xyz", result.?);
}

test "parseMultipartField: returns null for empty body" {
    const result = parseMultipartField(std.testing.allocator, "", "boundary", "field");
    try std.testing.expect(result == null);
}
