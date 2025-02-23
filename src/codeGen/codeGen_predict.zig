const std = @import("std");
const Tensor = @import("tensor").Tensor;
const ModelOnnx = @import("onnx").ModelProto;
const DataType = @import("onnx").DataType;
const TensorProto = @import("onnx").TensorProto;
const NodeProto = @import("onnx").NodeProto;
const GraphProto = @import("onnx").GraphProto;
const AttributeProto = @import("onnx").AttributeProto;
const allocator = @import("pkgAllocator").allocator;

const utils = @import("codeGen_utils.zig");
const mathGen = @import("codeGen_math_handler.zig");
const codegen_options = @import("codegen_options");

const globals = @import("globals.zig");
const ReadyNode = globals.ReadyNode;
const ReadyTensor = globals.ReadyTensor;

// Writes the computation function for predicting outputs
pub inline fn writePredict(writer: std.fs.File.Writer) !void {
    try write_outputsInitialization(writer);

    _ = try writer.print(
        \\
        \\
        \\
        \\pub export fn predict( 
        \\    input: [*]T,
        \\    input_shape: [*]u32,
        \\    shape_len: u32,
        \\    result: *[*]T,
        \\) void {{
    , .{});

    if (codegen_options.log) {
        _ = try writer.print(
            \\
            \\
            \\    if (log_function) |log| {{
            \\        log(@constCast(@ptrCast("Starting prediction...\n")));
            \\    }}
        , .{});
    }

    try write_checks(writer);

    try write_predictInitialization(writer);

    try write_graphSerialization(writer);

    try writeReturn(writer);

    _ = try writer.print(
        \\
        \\}} 
    , .{});

    std.debug.print("\n#############################################################", .{});
    std.debug.print("\n+                      EXECUTION ENDED                      +", .{});
    std.debug.print("\n#############################################################", .{});
}

// Processes and writes the computation graph
inline fn write_graphSerialization(writer: std.fs.File.Writer) !void {
    var iteration: usize = 0;
    var lastNode: *ReadyNode = undefined;
    while (true) {
        const computableNodes: std.ArrayList(*ReadyNode) = try utils.getComputableNodes(&globals.readyGraph);
        //DEBUG
        //try utils.printComputableNodes(computableNodes);

        if (computableNodes.items.len == 0) break;
        //else set the last node as the network output
        lastNode = computableNodes.items[computableNodes.items.len - 1];

        for (computableNodes.items) |node_ptr| {
            //writing the operation
            try writeOperation(writer, node_ptr);
            //set the output as ready
            try utils.setOutputsReady(node_ptr, &globals.tensorHashMap);
        }
        iteration += 1;
    }

    //setting te network output
    globals.networkOutput = lastNode.outputs.items[0].name;
}

// Initializes output tensors in the computation graph
fn write_outputsInitialization(writer: std.fs.File.Writer) !void {
    try writer.print(
        \\
        \\
        \\ // ---------------------------------------------------
        \\ // +         Initializing output Tensors             +
        \\ // ---------------------------------------------------
    , .{});

    for (globals.readyGraph.items) |*node| {

        //writing the outputs, OSS: two nodes shpuld never have the same output by definition, so we don't need to check for duplicates
        for (node.outputs.items) |output| {
            if (std.mem.eql(u8, node.nodeProto.op_type, "Constant") and node.inputs.items.len == 0) { //A node is constant if it only has one output and no inputs
                if (node.outputs.items.len > 1) return error.MultipleOutputConstant else {
                    try write_constantTensor(writer, node);
                    //set the node and tensor to Ready
                    var mutableNode: *ReadyNode = @constCast(node);
                    mutableNode.ready = true;
                }
            } else {
                const size = try write_OutputShape(
                    writer,
                    output,
                );
                try write_OutputTensor(
                    writer,
                    output.name,
                    size,
                );
            }
        }
    }
}

fn write_OutputShape(writer: std.fs.File.Writer, output: *ReadyTensor) !i64 {
    const shape = output.shape;
    var size: i64 = 1;
    try writer.print(
        \\
        \\
        \\var shape_tensor_{s} : [{}]usize = [_]usize{{
    , .{
        try utils.getSanitizedName(output.name),
        shape.len,
    });

    for (0..shape.len) |i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print(
            \\ {}
        , .{shape[i]});
        size *= shape[i];
    }

    try writer.print(
        \\}} ;
    , .{});

    return size;
}

fn write_constantTensor(writer: std.fs.File.Writer, readyNode: *const ReadyNode) !void {
    try writer.print(
        \\
        \\ // ---- CONSTANT TENSOR ---- 
    , .{});

    // Get the output tensor (constant nodes have exactly one output)
    const output = readyNode.outputs.items[0];
    const sanitized_name = try utils.getSanitizedName(output.name);

    // Find the value attribute which contains the constant tensor
    var value_attr: ?*AttributeProto = null;
    for (readyNode.nodeProto.attribute) |attr| {
        if (std.mem.eql(u8, attr.name, "value")) {
            value_attr = attr;
            break;
        }
    }

    if (value_attr == null or value_attr.?.t == null) return error.MissingConstantValue;
    const tensor = value_attr.?.t.?;

    // Write shape array
    try writer.print(
        \\
        \\const shape_tensor_{s} : [{}]usize = [_]usize{{
    , .{ sanitized_name, output.shape.len });

    for (0..output.shape.len) |i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print(
            \\ {}
        , .{output.shape[i]});
    }

    try writer.print(
        \\}} ;
    , .{});

    // Write data array
    var total_size: i64 = 1;
    for (tensor.dims) |dim| {
        total_size *= dim;
    }

    const dataTypeString = try utils.getTypeString(tensor.data_type);
    try writer.print(
        \\
        \\const array_{s} : [{d}]{s} = [_]{s}{{
    , .{ sanitized_name, total_size, dataTypeString, dataTypeString });

    // Write the actual data values
    if (tensor.float_data) |data| {
        for (0..data.len) |i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print(" {d}", .{data[i]});
        }
    } else if (tensor.int64_data) |data| {
        for (0..data.len) |i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print(" {d}", .{data[i]});
        }
    } else if (tensor.raw_data) |data| {
        switch (tensor.data_type) {
            .FLOAT => {
                const float_data = @as([*]const f32, @alignCast(@ptrCast(data.ptr)))[0..@divExact(data.len, 4)];
                for (0..float_data.len) |i| {
                    if (i > 0) try writer.print(",", .{});
                    try writer.print(" {d}", .{float_data[i]});
                }
            },
            .INT64 => {
                const int_data = @as([*]const i64, @alignCast(@ptrCast(data.ptr)))[0..@divExact(data.len, 8)];
                for (0..int_data.len) |i| {
                    if (i > 0) try writer.print(",", .{});
                    try writer.print(" {d}", .{int_data[i]});
                }
            },
            else => return error.UnsupportedDataType,
        }
    } else return error.NoDataAvailable;

    try writer.print(
        \\ }};
    , .{});

    // Write tensor initialization using fromArray
    try writer.print(
        \\
        \\const tensor_{s} = Tensor({s}).fromConstBuffer( &array_{s}, &shape_tensor_{s});
    , .{ sanitized_name, dataTypeString, sanitized_name, sanitized_name });
}

fn write_OutputTensor(writer: std.fs.File.Writer, name: []const u8, size: i64) !void {
    const sanitized_name = try utils.getSanitizedName(name);
    try writer.print(
        \\
        \\var array_{s}: [{}]T = undefined;
        \\var tensor_{s} = Tensor(T).fromConstBuffer( &array_{s}, &shape_tensor_{s});
    , .{ sanitized_name, size, sanitized_name, sanitized_name, sanitized_name });
}

fn write_checks(writer: std.fs.File.Writer) !void {
    // Autogen a check for the input shape as arg VS input shape as codegen option
    //First convert the optional String of numbers divided by a comma into an array
    const parsedInputshape = try utils.parseNumbers(codegen_options.shape);
    //check on the number of dims
    _ = try writer.print(
        \\
        \\    //checks on the input parameters
        \\    if (shape_len == 0) return ;
        \\    if(shape_len != {}) return ;
    , .{parsedInputshape.len});
    //check on dims correspondance
    for (parsedInputshape, 0..) |parsed_dim, i| {
        _ = try writer.print(
            \\
            \\    if( input_shape[{}] != {}) return ;
        , .{ i, parsed_dim });
    }
}

fn write_predictInitialization(writer: std.fs.File.Writer) !void {
    _ = try writer.print(
        \\  
        \\    //computing the size of the input tensor
        \\    var size: u32 = 1;
        \\    for(0..shape_len) |dim_i| {{
        \\        size *= input_shape[dim_i];
        \\    }}
        \\     
        \\    //allocating space in memory for the data
        \\    const data = allocator.alloc(T, size) catch return;
        \\    defer allocator.free(data);
        \\    for (0..size) |i| {{
        \\        data[i] = input[i]; // Copying input elements 
        \\    }}
        \\    
        \\    //converting the shape from [*]u32 to []usize
        \\    const usized_shape: []usize = utils.u32ToUsize(input_shape, shape_len) catch return;
        \\    var tensor_{s} = Tensor(T).fromShape(&allocator, @constCast(usized_shape)) catch return;
        \\    defer allocator.free(usized_shape);
        \\    defer tensor_{s}.deinit();
        \\    @memcpy(tensor_{s}.data, data);
    , .{
        try utils.getSanitizedName(globals.networkInput),
        try utils.getSanitizedName(globals.networkInput),
        try utils.getSanitizedName(globals.networkInput),
    });
}

fn writeOperation(writer: std.fs.File.Writer, readyNode: *ReadyNode) !void {
    try mathGen.write_math_op(writer, readyNode);
}

fn writeReturn(writer: std.fs.File.Writer) !void {
    _ = try writer.print(
        \\
        \\    result.* = tensor_{s}.data.ptr;
        \\
    , .{try utils.getSanitizedName(globals.networkOutput)});

    if (codegen_options.log) {
        _ = try writer.print(
            \\
            \\    if (log_function) |log| {{
            \\        log(@constCast(@ptrCast("Prediction completed.\n")));
            \\    }}
        , .{});
    }
}
