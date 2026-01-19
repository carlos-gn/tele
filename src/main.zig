const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libswscale/swscale.h");
});

pub fn main() !void {
    c.av_log_set_level(c.AV_LOG_ERROR);

    const version = c.avformat_version();
    const major = version >> 16;
    const minor = (version >> 8) & 0xFF;
    const micro = version & 0xFF;

    std.debug.print("libavformat version: {}.{}.{}\n", .{ major, minor, micro });

    var format_ctx: ?*c.AVFormatContext = null;
    const r = c.avformat_open_input(&format_ctx, "sample-5s.mp4", null, null);

    if (r < 0) {
        std.log.debug("Something went wrong {}", .{r});
        return;
    }

    const ret = c.avformat_find_stream_info(format_ctx, null);
    if (ret < 0) {
        std.debug.print("Failed to find a stream info\n", .{});
        return;
    }

    const streams = format_ctx.?.streams;
    const nb_streams = format_ctx.?.nb_streams;

    var video_stream_index: usize = undefined;
    var codec_ctx: ?*c.AVCodecContext = null;
    for (0..nb_streams) |i| {
        const stream = streams[i];
        const codecpar = stream.*.codecpar;

        if (codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            video_stream_index = i;
            const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
            if (codec == null) {
                std.debug.print("Decoded not found\n", .{});
                return;
            }

            std.log.debug("decoder: {s}\n", .{codec.*.name});
            codec_ctx = c.avcodec_alloc_context3(codec);
            if (codec_ctx == null) return;

            _ = c.avcodec_parameters_to_context(codec_ctx, codecpar);

            if (c.avcodec_open2(codec_ctx, codec, null) < 0) {
                std.log.debug("Failed to open decoder\n", .{});
                return;
            }

            break;
        }
    }

    const packet: ?*c.AVPacket = c.av_packet_alloc();
    const frame: ?*c.AVFrame = c.av_frame_alloc();
    defer c.av_packet_free(@ptrCast(@constCast(&packet)));
    defer c.av_frame_free(@ptrCast(@constCast(&frame)));

    const target_fps = 30;
    const frame_time_ns: u64 = std.time.ns_per_s / target_fps;

    var timer = try std.time.Timer.start();
    var frame_count: u64 = 0;
    while (c.av_read_frame(format_ctx, packet) >= 0) {
        defer c.av_packet_unref(packet);

        // Skip non-video packets (audio, etc.)
        if (packet.?.*.stream_index != video_stream_index) continue;

        // Send compressed packet to decoder
        if (c.avcodec_send_packet(codec_ctx, packet) < 0) continue;

        // Try to receive decoded frame
        if (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
            const display_width: c_int = 1280;
            const display_height: c_int = 720;
            const sws_ctx = c.sws_getContext(
                frame.?.*.width,
                frame.?.*.height,
                frame.?.*.format,
                display_width,
                display_height,
                c.AV_PIX_FMT_RGBA,
                c.SWS_BILINEAR,
                null,
                null,
                null,
            );
            if (sws_ctx == null) return;
            defer c.sws_freeContext(sws_ctx);

            const rgba_size: usize = @intCast(display_width * display_height * 4);
            const allocator = std.heap.page_allocator;
            const rgba_buffer = allocator.alloc(u8, rgba_size) catch return;
            defer allocator.free(rgba_buffer);

            var dst_data: [1][*]u8 = .{rgba_buffer.ptr};
            const stride: c_int = @intCast(display_width * 4);
            var dst_stride: [1]c_int = .{stride};

            _ = c.sws_scale(
                sws_ctx,
                @ptrCast(&frame.?.*.data), // source planes
                &frame.?.*.linesize, // source strides
                0, // start line
                frame.?.*.height, // number of lines
                @ptrCast(&dst_data), // dest planes
                &dst_stride, // dest strides
            );

            const file = try std.fs.createFileAbsolute("/tmp/frame.raw", .{});
            try file.writeAll(rgba_buffer);
            file.close();

            // Base64 encode the path (not the pixels!)
            var path_b64: [64]u8 = undefined;
            const encoded_path = std.base64.standard.Encoder.encode(&path_b64, "/tmp/frame.raw");

            const stdout_file = std.fs.File.stdout();
            // Single escape sequence
            try stdout_file.writeAll("\x1b_Ga=d,d=i,i=1,q=2\x1b\\");
            try stdout_file.writeAll("\x1b[H");
            var cmd_buf: [256]u8 = undefined;
            const cmd = try std.fmt.bufPrint(
                &cmd_buf,
                "\x1b_Gf=32,i=1,p=1,q=2,s={},v={},t=f,a=T;{s}\x1b\\",
                .{ display_width, display_height, encoded_path },
            );
            try stdout_file.writeAll(cmd);
            frame_count += 1;
            const elapsed = timer.read();
            const target = frame_count * frame_time_ns;
            if (elapsed < target) {
                std.Thread.sleep(target - elapsed);
            }
        }
    }
    const total_time = timer.read();
    const actual_fps = @as(f64, @floatFromInt(frame_count)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s);
    std.debug.print("Played {} frames, avg {d:.1} fps\n", .{ frame_count, actual_fps });
    c.avformat_close_input(&format_ctx);
}
