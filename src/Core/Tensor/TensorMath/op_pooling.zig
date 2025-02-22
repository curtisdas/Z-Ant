const std = @import("std");
const Tensor = @import("tensor").Tensor; // Import Tensor type
const pkg_allocator = @import("pkgAllocator").allocator;
const TensorMathError = @import("errorHandler").TensorMathError;
const PoolingType = @import("layer").poolingLayer.PoolingType;

pub const AutoPadType = enum {
    NOTSET,
    SAME_UPPER,
    SAME_LOWER,
    VALID,
};

pub fn get_pooling_output_shape(input_shape: []const usize, kernel: [2]usize, stride: [2]usize) ![4]usize {
    if (input_shape.len != 4) {
        return TensorMathError.InvalidDimensions;
    }

    if (kernel[0] == 0 or kernel[1] == 0 or stride[0] == 0 or stride[1] == 0) {
        return TensorMathError.WrongStride;
    }

    if (kernel[0] > input_shape[2] or kernel[1] > input_shape[3]) {
        return TensorMathError.InvalidDimensions;
    }

    const batch_size = input_shape[0];
    const channels = input_shape[1];
    const out_height = (input_shape[2] - kernel[0]) / stride[0] + 1;
    const out_width = (input_shape[3] - kernel[1]) / stride[1] + 1;

    return [4]usize{ batch_size, channels, out_height, out_width };
}

// POOLING -----------------------------------------------------------------------------------------------------------------------
pub fn pool_tensor(
    comptime T: type,
    input: *Tensor(T),
    used_windows: *Tensor(u8), // Shape: [W, input_rows, input_cols]
    kernel: []usize,
    stride: []usize,
    poolingType: PoolingType,
) !Tensor(T) {
    var outputTensorShape = try pkg_allocator.alloc(usize, input.shape.len);
    defer pkg_allocator.free(outputTensorShape);

    for (0..input.shape.len - 2) |i| {
        outputTensorShape[i] = input.shape[i];
    }
    const height = input.shape.len - 2;
    const width = input.shape.len - 1;

    outputTensorShape[height] = (input.shape[height] - kernel[0] + 1) / stride[0];
    outputTensorShape[width] = (input.shape[width] - kernel[1] + 1) / stride[1];

    var output = try Tensor(T).fromShape(&pkg_allocator, outputTensorShape);
    errdefer output.deinit();

    const location = try pkg_allocator.alloc(usize, input.shape.len);
    defer pkg_allocator.free(location);
    @memset(location, 0);

    try multidim_pooling(
        T,
        input,
        used_windows,
        &output,
        0,
        location,
        kernel,
        stride,
        poolingType,
    );

    return output;
}

pub fn multidim_pooling(
    comptime T: anytype,
    input: *Tensor(T),
    used_windows: *Tensor(u8), // Shape: [W, input_rows, input_cols]
    output: *Tensor(T),
    current_depth: usize,
    location: []usize,
    kernel: []usize,
    stride: []usize,
    poolingType: PoolingType,
) !void {
    if (current_depth == output.shape.len - 2) {
        const allocator = pkg_allocator;

        var temp_location = try allocator.alloc(usize, input.shape.len);
        defer allocator.free(temp_location);
        var window_location = try allocator.alloc(usize, input.shape.len);
        defer allocator.free(window_location);
        var window_values = try allocator.alloc(T, kernel[0] * kernel[1]);
        defer allocator.free(window_values);

        var output_row_counter: usize = 0;
        var output_col_counter: usize = 0;

        @memcpy(temp_location, location);
        @memcpy(window_location, location);

        temp_location[current_depth] = 0;
        temp_location[current_depth + 1] = 0;

        const input_rows = input.shape[current_depth];
        const input_cols = input.shape[current_depth + 1];
        const output_cols = output.shape[current_depth + 1];

        while (temp_location[current_depth] + kernel[0] <= input_rows) : (temp_location[current_depth] += stride[0]) {
            temp_location[current_depth + 1] = 0; // Reset column counter
            while (temp_location[current_depth + 1] + kernel[1] <= input_cols) : (temp_location[current_depth + 1] += stride[1]) {
                const kernel_rows = kernel[0];
                const kernel_cols = kernel[1];
                const w = output_row_counter * output_cols + output_col_counter;

                // Reset window location for each window
                @memcpy(window_location, temp_location);

                var window_idx: usize = 0;
                for (0..kernel_rows) |i| {
                    for (0..kernel_cols) |j| {
                        window_location[current_depth] = temp_location[current_depth] + i;
                        window_location[current_depth + 1] = temp_location[current_depth + 1] + j;
                        window_values[window_idx] = try input.get_at(window_location);
                        window_idx += 1;
                    }
                }

                switch (poolingType) {
                    .Max => {
                        var max = window_values[0];
                        var max_idx: usize = 0;
                        for (window_values, 0..) |val, i| {
                            if (val > max) {
                                max = val;
                                max_idx = i;
                            }
                        }

                        const row = max_idx / kernel_cols;
                        const col = max_idx % kernel_cols;
                        const max_r = temp_location[current_depth] + row;
                        const max_c = temp_location[current_depth + 1] + col;

                        used_windows.data[w * (input_rows * input_cols) + max_r * input_cols + max_c] = 1;

                        window_location[current_depth] = output_row_counter;
                        window_location[current_depth + 1] = output_col_counter;
                        try output.set_at(window_location, max);
                    },
                    .Min => {
                        var min = window_values[0];
                        var min_idx: usize = 0;
                        for (window_values, 0..) |val, i| {
                            if (val < min) {
                                min = val;
                                min_idx = i;
                            }
                        }

                        const row = min_idx / kernel_cols;
                        const col = min_idx % kernel_cols;
                        const min_r = temp_location[current_depth] + row;
                        const min_c = temp_location[current_depth + 1] + col;

                        used_windows.data[w * (input_rows * input_cols) + min_r * input_cols + min_c] = 1;

                        window_location[current_depth] = output_row_counter;
                        window_location[current_depth + 1] = output_col_counter;
                        try output.set_at(window_location, min);
                    },
                    .Avg => {
                        var sum: T = 0;
                        for (window_values) |val| {
                            sum += val;
                        }
                        const avg = sum / @as(T, @floatFromInt(window_values.len));

                        window_location[current_depth] = output_row_counter;
                        window_location[current_depth + 1] = output_col_counter;
                        try output.set_at(window_location, avg);

                        // Mark all values in window as used for average pooling
                        for (0..kernel_rows) |i| {
                            for (0..kernel_cols) |j| {
                                const avg_r = temp_location[current_depth] + i;
                                const avg_c = temp_location[current_depth + 1] + j;
                                used_windows.data[w * (input_rows * input_cols) + avg_r * input_cols + avg_c] = 1;
                            }
                        }
                    },
                }

                output_col_counter += 1;
            }
            output_row_counter += 1;
            output_col_counter = 0;
        }
    } else {
        for (0..output.shape[current_depth]) |element_at_current_depth| {
            location[current_depth] = element_at_current_depth;
            try multidim_pooling(
                T,
                input,
                used_windows,
                output,
                current_depth + 1,
                location,
                kernel,
                stride,
                poolingType,
            );
        }
    }
}

/// Performs pooling operation on a 4D tensor (batch, channels, height, width)
pub fn pool_forward(comptime T: type, input: *Tensor(T), kernel: [2]usize, stride: [2]usize, poolingType: PoolingType) !struct { output: Tensor(T), used_input: Tensor(u8) } {
    const batch_size = input.shape[0];
    const channels = input.shape[1];
    const input_rows = input.shape[2];
    const input_cols = input.shape[3];

    // Validate input dimensions
    if (input.shape.len != 4) {
        return TensorMathError.InputTensorDimensionMismatch;
    }

    // Validate kernel and stride
    if (kernel[0] == 0 or kernel[1] == 0 or stride[0] == 0 or stride[1] == 0) {
        return TensorMathError.InvalidDimensions;
    }

    // Calculate output dimensions
    const out_rows = (input_rows -% kernel[0]) / stride[0] +% 1;
    const out_cols = (input_cols -% kernel[1]) / stride[1] +% 1;

    // Validate output dimensions
    if (out_rows == 0 or out_cols == 0 or out_rows > input_rows or out_cols > input_cols) {
        return TensorMathError.InvalidDimensions;
    }

    // Allocate output tensor
    var output_shape = [_]usize{ batch_size, channels, out_rows, out_cols };
    var output = try Tensor(T).fromShape(&pkg_allocator, &output_shape);
    errdefer output.deinit();

    // Allocate used_input tensor
    var used_input_shape = [_]usize{ batch_size, channels, out_rows * out_cols, input_rows, input_cols };
    var used_input = try Tensor(u8).fromShape(&pkg_allocator, &used_input_shape);
    errdefer used_input.deinit();
    @memset(used_input.data, 0);

    // Main pooling loop
    for (0..batch_size) |b| {
        for (0..channels) |c| {
            const batch_offset = b * channels * input_rows * input_cols;
            const channel_offset = c * input_rows * input_cols;
            const out_batch_offset = b * channels * out_rows * out_cols;
            const out_channel_offset = c * out_rows * out_cols;

            for (0..out_rows) |out_r| {
                const r_start = out_r * stride[0];
                if (r_start >= input_rows) continue;

                for (0..out_cols) |out_c| {
                    const c_start = out_c * stride[1];
                    if (c_start >= input_cols) continue;

                    const window_index = out_r * out_cols + out_c;
                    const out_idx = out_batch_offset + out_channel_offset + out_r * out_cols + out_c;

                    switch (poolingType) {
                        .Max => {
                            var max_value: T = -std.math.floatMax(T);
                            var max_pos: usize = 0;
                            var found_valid = false;

                            // Scan kernel window
                            for (0..kernel[0]) |kr| {
                                const in_r = r_start + kr;
                                if (in_r >= input_rows) break;

                                for (0..kernel[1]) |kc| {
                                    const in_c = c_start + kc;
                                    if (in_c >= input_cols) break;

                                    const idx = batch_offset + channel_offset + in_r * input_cols + in_c;
                                    if (idx >= input.data.len) break;

                                    const val = input.data[idx];
                                    if (!found_valid or val > max_value) {
                                        max_value = val;
                                        max_pos = in_r * input_cols + in_c;
                                        found_valid = true;
                                    }
                                }
                            }

                            // Set output value
                            if (out_idx >= output.data.len) {
                                output.deinit();
                                used_input.deinit();
                                return TensorMathError.InvalidDimensions;
                            }
                            output.data[out_idx] = if (found_valid) max_value else 0;

                            // Mark used input
                            if (found_valid) {
                                const used_idx = b * channels * out_rows * out_cols * input_rows * input_cols +
                                    c * out_rows * out_cols * input_rows * input_cols +
                                    window_index * input_rows * input_cols + max_pos;
                                if (used_idx >= used_input.data.len) {
                                    output.deinit();
                                    used_input.deinit();
                                    return TensorMathError.InvalidDimensions;
                                }
                                used_input.data[used_idx] = 1;
                            }
                        },
                        .Min => {
                            var min_value: T = if (T == f64) std.math.inf(f64) else std.math.floatMax(T);
                            var min_pos: usize = 0;
                            var found_valid = false;

                            for (0..kernel[0]) |kr| {
                                for (0..kernel[1]) |kc| {
                                    const in_r = r_start + kr;
                                    const in_c = c_start + kc;

                                    if (in_r < input_rows and in_c < input_cols) {
                                        const idx = b * channels * input_rows * input_cols +
                                            c * input_rows * input_cols +
                                            in_r * input_cols + in_c;
                                        const val = input.data[idx];
                                        if (!found_valid or val < min_value) {
                                            min_value = val;
                                            min_pos = in_r * input_cols + in_c;
                                            found_valid = true;
                                        }
                                    }
                                }
                            }

                            if (!found_valid) {
                                min_value = 0;
                            }

                            if (out_idx >= output.data.len) {
                                output.deinit();
                                used_input.deinit();
                                return TensorMathError.InvalidDimensions;
                            }
                            output.data[out_idx] = min_value;

                            if (found_valid) {
                                const used_idx = b * channels * out_rows * out_cols * input_rows * input_cols +
                                    c * out_rows * out_cols * input_rows * input_cols +
                                    window_index * input_rows * input_cols + min_pos;
                                if (used_idx >= used_input.data.len) {
                                    output.deinit();
                                    used_input.deinit();
                                    return TensorMathError.InvalidDimensions;
                                }
                                used_input.data[used_idx] = 1;
                            }
                        },
                        .Avg => {
                            var sum: T = 0;
                            var count: usize = 0;

                            for (0..kernel[0]) |kr| {
                                for (0..kernel[1]) |kc| {
                                    const in_r = r_start + kr;
                                    const in_c = c_start + kc;

                                    if (in_r < input_rows and in_c < input_cols) {
                                        const idx = b * channels * input_rows * input_cols +
                                            c * input_rows * input_cols +
                                            in_r * input_cols + in_c;
                                        sum += input.data[idx];
                                        count += 1;

                                        const used_idx = b * channels * out_rows * out_cols * input_rows * input_cols +
                                            c * out_rows * out_cols * input_rows * input_cols +
                                            window_index * input_rows * input_cols +
                                            in_r * input_cols + in_c;
                                        if (used_idx >= used_input.data.len) {
                                            output.deinit();
                                            used_input.deinit();
                                            return TensorMathError.InvalidDimensions;
                                        }
                                        used_input.data[used_idx] = 1;
                                    }
                                }
                            }
                            const avg = if (count > 0) sum / @as(T, @floatFromInt(count)) else 0;
                            if (out_idx >= output.data.len) {
                                output.deinit();
                                used_input.deinit();
                                return TensorMathError.InvalidDimensions;
                            }
                            output.data[out_idx] = avg;
                        },
                    }
                }
            }
        }
    }

    return .{ .output = output, .used_input = used_input };
}

/// Performs backward pass for pooling operation
pub fn pool_backward(comptime T: type, dValues: *Tensor(T), input_shape: []const usize, used_input: *Tensor(u8), kernel: [2]usize, stride: [2]usize) !Tensor(T) {
    const shape = try pkg_allocator.alloc(usize, input_shape.len);
    defer pkg_allocator.free(shape);
    @memcpy(shape, input_shape);

    var dInput = try Tensor(T).fromShape(&pkg_allocator, shape);
    errdefer dInput.deinit();

    @memset(dInput.data, 0);

    const batch_size = input_shape[0];
    const channels = input_shape[1];
    const input_rows = input_shape[2];
    const input_cols = input_shape[3];

    const out_rows = dValues.shape[2];
    const out_cols = dValues.shape[3];

    for (0..batch_size) |b| {
        for (0..channels) |c| {
            for (0..out_rows) |out_r| {
                for (0..out_cols) |out_c| {
                    const grad_idx = b * channels * out_rows * out_cols +
                        c * out_rows * out_cols +
                        out_r * out_cols + out_c;
                    const grad = dValues.data[grad_idx];
                    const window_index = out_r * out_cols + out_c;

                    for (0..kernel[0]) |kr| {
                        for (0..kernel[1]) |kc| {
                            const in_r = out_r * stride[0] + kr;
                            const in_c = out_c * stride[1] + kc;

                            if (in_r < input_rows and in_c < input_cols) {
                                const mask_idx = b * channels * out_rows * out_cols * input_rows * input_cols +
                                    c * out_rows * out_cols * input_rows * input_cols +
                                    window_index * input_rows * input_cols +
                                    in_r * input_cols + in_c;
                                const mask_val = used_input.data[mask_idx];

                                if (mask_val == 1) {
                                    const input_idx = b * channels * input_rows * input_cols +
                                        c * input_rows * input_cols +
                                        in_r * input_cols + in_c;
                                    dInput.data[input_idx] += grad;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return dInput;
}

pub fn get_onnx_maxpool_output_shape(
    input_shape: []const usize,
    kernel_shape: []const usize,
    strides: []const usize,
    dilations: []const usize,
    pads: []const usize,
    auto_pad: AutoPadType,
    ceil_mode: bool,
) ![]usize {
    if (input_shape.len != 4) {
        return TensorMathError.InvalidDimensions;
    }

    const batch_size = input_shape[0];
    const channels = input_shape[1];
    const input_height = input_shape[2];
    const input_width = input_shape[3];

    var output_shape = try pkg_allocator.alloc(usize, 4);
    errdefer pkg_allocator.free(output_shape);

    output_shape[0] = batch_size;
    output_shape[1] = channels;

    var pad_h: usize = 0;
    var pad_w: usize = 0;
    var pad_top: usize = 0;
    var pad_left: usize = 0;
    var pad_bottom: usize = 0;
    var pad_right: usize = 0;

    // Calculate effective kernel size with dilations
    const effective_kernel_h = (kernel_shape[0] - 1) * dilations[0] + 1;
    const effective_kernel_w = (kernel_shape[1] - 1) * dilations[1] + 1;

    switch (auto_pad) {
        .NOTSET => {
            pad_top = pads[0];
            pad_left = pads[1];
            pad_bottom = pads[2];
            pad_right = pads[3];
            pad_h = pad_top + pad_bottom;
            pad_w = pad_left + pad_right;
        },
        .VALID => {
            pad_h = 0;
            pad_w = 0;
            pad_top = 0;
            pad_left = 0;
            pad_bottom = 0;
            pad_right = 0;
        },
        .SAME_UPPER, .SAME_LOWER => {
            // Calculate total padding needed
            const out_height = @divTrunc(input_height + strides[0] - 1, strides[0]);
            const out_width = @divTrunc(input_width + strides[1] - 1, strides[1]);

            pad_h = (out_height - 1) * strides[0] + effective_kernel_h - input_height;
            pad_w = (out_width - 1) * strides[1] + effective_kernel_w - input_width;

            if (auto_pad == .SAME_UPPER) {
                pad_top = pad_h / 2;
                pad_bottom = pad_h - pad_top;
                pad_left = pad_w / 2;
                pad_right = pad_w - pad_left;
            } else {
                pad_bottom = pad_h / 2;
                pad_top = pad_h - pad_bottom;
                pad_right = pad_w / 2;
                pad_left = pad_w - pad_right;
            }
        },
    }

    // Calculate output dimensions
    var out_height: usize = undefined;
    var out_width: usize = undefined;

    if (ceil_mode) {
        out_height = @divTrunc(input_height + pad_h - effective_kernel_h + strides[0] - 1, strides[0]) + 1;
        out_width = @divTrunc(input_width + pad_w - effective_kernel_w + strides[1] - 1, strides[1]) + 1;
    } else {
        out_height = @divTrunc(input_height + pad_h - effective_kernel_h, strides[0]) + 1;
        out_width = @divTrunc(input_width + pad_w - effective_kernel_w, strides[1]) + 1;
    }

    output_shape[2] = out_height;
    output_shape[3] = out_width;

    return output_shape;
}

/// Lean version of onnx_maxpool that takes a pre-allocated output tensor
pub fn lean_onnx_maxpool(
    comptime T: type,
    input: *Tensor(T),
    output: *Tensor(T),
    used_input: *Tensor(u8),
    kernel_shape: []const usize,
    strides: []const usize,
    dilations: []const usize,
    pads: []const usize,
    auto_pad: AutoPadType,
) !void {
    const batch_size = input.shape[0];
    const channels = input.shape[1];
    const input_height = input.shape[2];
    const input_width = input.shape[3];

    const out_height = output.shape[2];
    const out_width = output.shape[3];

    // Calculate padding based on auto_pad mode
    var pad_top: usize = 0;
    var pad_left: usize = 0;
    var pad_bottom: usize = 0;
    var pad_right: usize = 0;

    switch (auto_pad) {
        .NOTSET => {
            pad_top = pads[0];
            pad_left = pads[1];
            pad_bottom = pads[2];
            pad_right = pads[3];
        },
        .VALID => {
            // No padding needed
        },
        .SAME_UPPER, .SAME_LOWER => {
            const total_pad_h = (out_height - 1) * strides[0] + ((kernel_shape[0] - 1) * dilations[0] + 1) - input_height;
            const total_pad_w = (out_width - 1) * strides[1] + ((kernel_shape[1] - 1) * dilations[1] + 1) - input_width;

            if (auto_pad == .SAME_UPPER) {
                pad_top = total_pad_h / 2;
                pad_bottom = total_pad_h - pad_top;
                pad_left = total_pad_w / 2;
                pad_right = total_pad_w - pad_left;
            } else {
                pad_bottom = total_pad_h / 2;
                pad_top = total_pad_h - pad_bottom;
                pad_right = total_pad_w / 2;
                pad_left = total_pad_w - pad_right;
            }
        },
    }

    // Main pooling loop
    for (0..batch_size) |b| {
        for (0..channels) |c| {
            for (0..out_height) |out_y| {
                for (0..out_width) |out_x| {
                    // Calculate the kernel window boundaries in input coordinates
                    const in_y_start = @as(i64, @intCast(out_y * strides[0])) - @as(i64, @intCast(pad_top));
                    const in_x_start = @as(i64, @intCast(out_x * strides[1])) - @as(i64, @intCast(pad_left));

                    std.debug.print("\n=== Window {d},{d} ===\n", .{ out_y, out_x });
                    std.debug.print("Start coords: y={d}, x={d}\n", .{ in_y_start, in_x_start });
                    std.debug.print("Kernel: {d}x{d}, Dilations: {d}x{d}\n", .{ kernel_shape[0], kernel_shape[1], dilations[0], dilations[1] });
                    std.debug.print("Padding: top={d}, left={d}, bottom={d}, right={d}\n", .{ pad_top, pad_left, pad_bottom, pad_right });

                    // Initialize max value to 0 for explicit padding, -inf otherwise
                    var max_val = if (auto_pad == .NOTSET and (pad_top > 0 or pad_left > 0 or pad_bottom > 0 or pad_right > 0)) 0 else -std.math.inf(f32);
                    var max_found = false;

                    // Iterate over the kernel window
                    for (0..kernel_shape[0]) |kernel_y| {
                        for (0..kernel_shape[1]) |kernel_x| {
                            // Calculate input coordinates
                            const in_y = in_y_start + @as(i64, @intCast(kernel_y * dilations[0]));
                            const in_x = in_x_start + @as(i64, @intCast(kernel_x * dilations[1]));

                            // Check if the input coordinates are valid
                            if (in_y >= 0 and in_y < input_height and in_x >= 0 and in_x < input_width) {
                                const input_idx = b * channels * input_height * input_width +
                                    c * input_height * input_width +
                                    @as(usize, @intCast(in_y)) * input_width +
                                    @as(usize, @intCast(in_x));
                                const val = input.data[input_idx];
                                std.debug.print("  Kernel[{d},{d}] -> Input[{d},{d}] = {e}\n", .{ kernel_y, kernel_x, in_y, in_x, val });
                                if (!max_found or val > max_val) {
                                    max_val = val;
                                    max_found = true;
                                    std.debug.print("    New max: {e}\n", .{max_val});
                                }
                            } else {
                                std.debug.print("  Kernel[{d},{d}] -> Input[{d},{d}] = 0 (padded)\n", .{ kernel_y, kernel_x, in_y, in_x });
                            }
                        }
                    }

                    const out_idx = b * channels * out_height * out_width +
                        c * out_height * out_width +
                        out_y * out_width + out_x;

                    std.debug.print("Final max_val={e} at output[{d}]\n", .{ max_val, out_idx });

                    output.data[out_idx] = max_val;

                    // Only mark used input positions for non-padded values that were actually used
                    if (max_val != -std.math.inf(f32)) {
                        const window_index = out_y * out_width + out_x;
                        const used_idx = b * channels * out_height * out_width * input_height * input_width +
                            c * out_height * out_width * input_height * input_width +
                            window_index * input_height * input_width;
                        used_input.data[used_idx] = 1;
                    }
                }
            }
        }
    }
}

// Modify the original onnx_maxpool to use the lean version
pub fn onnx_maxpool(
    comptime T: type,
    input: *Tensor(T),
    kernel_shape: []const usize,
    strides: []const usize,
    dilations: []const usize,
    pads: []const usize,
    auto_pad: AutoPadType,
    ceil_mode: bool,
) !struct { output: Tensor(T), used_input: Tensor(u8) } {
    // Calculate output shape
    const output_shape = try get_onnx_maxpool_output_shape(
        input.shape,
        kernel_shape,
        strides,
        dilations,
        pads,
        auto_pad,
        ceil_mode,
    );
    defer pkg_allocator.free(output_shape);

    var output = try Tensor(T).fromShape(&pkg_allocator, output_shape);
    errdefer output.deinit();

    const out_height = output_shape[2];
    const out_width = output_shape[3];

    // Allocate used_input tensor
    var used_input_shape = [_]usize{ input.shape[0], input.shape[1], out_height * out_width, input.shape[2], input.shape[3] };
    var used_input = try Tensor(u8).fromShape(&pkg_allocator, &used_input_shape);
    errdefer used_input.deinit();
    @memset(used_input.data, 0);

    try lean_onnx_maxpool(
        T,
        input,
        &output,
        &used_input,
        kernel_shape,
        strides,
        dilations,
        pads,
        auto_pad,
    );

    return .{ .output = output, .used_input = used_input };
}
