const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const aux = @import("auxiliary.zig");
const configurations = @import("config.zig");
const EnvironmentRegistry = configurations.EnvironmentRegistry;

pub const JupyterError = error{
    JupyterNotFound,
    KernelNotFound,
    KernelExists,
    InvalidKernelName,
    PermissionDenied,
    InvalidPath,
};

pub const KernelSpec = struct {
    name: []const u8,
    display_name: []const u8,
    python_path: []const u8,
    env_vars: ?std.StringHashMap([]const u8) = null,
};

/// Check if Jupyter is installed and available
pub fn isJupyterAvailable(allocator: Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "jupyter", "--version" },
        .cwd = null,
        .env_map = null,
        .max_output_bytes = 1024,
    }) catch return false;
    
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    return result.term.Exited == 0;
}

/// Get the Jupyter data directory path
pub fn getJupyterDataDir(allocator: Allocator) ![]const u8 {
    // First try to get from environment variable
    if (std.process.getEnvVarOwned(allocator, "JUPYTER_DATA_DIR")) |data_dir| {
        return data_dir;
    } else |_| {
        // Fall back to default locations
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return try std.fmt.allocPrint(allocator, "{s}/.local/share/jupyter", .{home});
        } else |_| {
            return error.InvalidPath;
        }
    }
}

/// Get the kernel directory path for a given kernel name
pub fn getKernelDir(allocator: Allocator, kernel_name: []const u8) ![]const u8 {
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);
    
    return try std.fmt.allocPrint(allocator, "{s}/kernels/{s}", .{ jupyter_data_dir, kernel_name });
}

/// Generate kernel.json content
pub fn generateKernelJson(allocator: Allocator, spec: KernelSpec) ![]const u8 {
    const template =
        \\{{
        \\  "display_name": "{s}",
        \\  "language": "python",
        \\  "argv": [
        \\    "{s}",
        \\    "-m",
        \\    "ipykernel_launcher",
        \\    "-f",
        \\    "{{connection_file}}"
        \\  ],
        \\  "env": {{}}
        \\}}
    ;
    
    return try std.fmt.allocPrint(allocator, template, .{ spec.display_name, spec.python_path });
}

/// Create a Jupyter kernel for the given environment
pub fn createKernel(allocator: Allocator, env_name: []const u8, custom_name: ?[]const u8, custom_display_name: ?[]const u8) !void {
    // Check if Jupyter is available
    if (!isJupyterAvailable(allocator)) {
        try output.printError(allocator, "Jupyter is not installed or not available in PATH", .{});
        return JupyterError.JupyterNotFound;
    }
    
    // Get environment info from registry
    var registry = EnvironmentRegistry.load(allocator) catch |err| {
        try output.printError(allocator, "Failed to load environment registry: {s}", .{@errorName(err)});
        return;
    };
    defer registry.deinit();
    
    // Find the environment
    const env_info = registry.lookup(env_name) orelse {
        try output.printError(allocator, "Environment '{s}' not found in registry", .{env_name});
        return;
    };
    
    // Determine kernel name and display name
    const kernel_name = custom_name orelse try std.fmt.allocPrint(allocator, "zenv-{s}", .{env_name});
    defer if (custom_name == null) allocator.free(kernel_name);
    
    const display_name = custom_display_name orelse try std.fmt.allocPrint(allocator, "Python ({s})", .{env_name});
    defer if (custom_display_name == null) allocator.free(display_name);
    
    // Get Python path from environment
    const python_path = try std.fmt.allocPrint(allocator, "{s}/bin/python", .{env_info.venv_path});
    defer allocator.free(python_path);
    
    // Check if Python executable exists
    std.fs.accessAbsolute(python_path, .{}) catch |err| {
        try output.printError(allocator, "Python executable not found at {s}: {s}", .{ python_path, @errorName(err) });
        return;
    };
    
    // Create kernel directory
    const kernel_dir = try getKernelDir(allocator, kernel_name);
    defer allocator.free(kernel_dir);
    
    // Check if kernel already exists
    if (std.fs.accessAbsolute(kernel_dir, .{})) |_| {
        // File exists, that's an error
        try output.printError(allocator, "Kernel '{s}' already exists", .{kernel_name});
        return JupyterError.KernelExists;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Good, kernel doesn't exist, continue
        },
        else => {
            try output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)});
            return;
        },
    }
    
    // Ensure jupyter data directory exists
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);
    
    std.fs.makeDirAbsolute(jupyter_data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => {
            try output.printError(allocator, "Failed to create jupyter data directory: {s}", .{@errorName(err)});
            return;
        },
    };
    
    // Ensure kernels directory exists
    const kernels_dir = try std.fmt.allocPrint(allocator, "{s}/kernels", .{jupyter_data_dir});
    defer allocator.free(kernels_dir);
    
    std.fs.makeDirAbsolute(kernels_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => {
            try output.printError(allocator, "Failed to create kernels directory: {s}", .{@errorName(err)});
            return;
        },
    };
    
    // Create kernel directory
    std.fs.makeDirAbsolute(kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to create kernel directory: {s}", .{@errorName(err)});
        return;
    };
    
    // Create kernel spec
    const spec = KernelSpec{
        .name = kernel_name,
        .display_name = display_name,
        .python_path = python_path,
    };
    
    // Generate kernel.json content
    const kernel_json = try generateKernelJson(allocator, spec);
    defer allocator.free(kernel_json);
    
    // Write kernel.json file
    const kernel_json_path = try std.fmt.allocPrint(allocator, "{s}/kernel.json", .{kernel_dir});
    defer allocator.free(kernel_json_path);
    
    const file = std.fs.createFileAbsolute(kernel_json_path, .{}) catch |err| {
        try output.printError(allocator, "Failed to create kernel.json: {s}", .{@errorName(err)});
        return;
    };
    defer file.close();
    
    file.writeAll(kernel_json) catch |err| {
        try output.printError(allocator, "Failed to write kernel.json: {s}", .{@errorName(err)});
        return;
    };
    
    try output.print(allocator, "Created Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
    try output.print(allocator, "Kernel location: {s}", .{kernel_dir});
}

/// Remove a Jupyter kernel for the given environment
pub fn removeKernel(allocator: Allocator, env_name: []const u8) !void {
    const kernel_name = try std.fmt.allocPrint(allocator, "zenv-{s}", .{env_name});
    defer allocator.free(kernel_name);
    
    const kernel_dir = try getKernelDir(allocator, kernel_name);
    defer allocator.free(kernel_dir);
    
    // Check if kernel exists
    std.fs.accessAbsolute(kernel_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try output.printError(allocator, "Kernel '{s}' not found", .{kernel_name});
            return JupyterError.KernelNotFound;
        },
        else => {
            try output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)});
            return;
        },
    };
    
    // Remove kernel directory recursively
    std.fs.deleteTreeAbsolute(kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to remove kernel directory: {s}", .{@errorName(err)});
        return;
    };
    
    try output.print(allocator, "Removed Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
}

/// List all zenv-managed Jupyter kernels
pub fn listKernels(allocator: Allocator) !void {
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);
    
    const kernels_dir = try std.fmt.allocPrint(allocator, "{s}/kernels", .{jupyter_data_dir});
    defer allocator.free(kernels_dir);
    
    var dir = std.fs.openDirAbsolute(kernels_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try output.print(allocator, "No Jupyter kernels directory found", .{});
            return;
        },
        else => {
            try output.printError(allocator, "Failed to access kernels directory: {s}", .{@errorName(err)});
            return;
        },
    };
    defer dir.close();
    
    var iterator = dir.iterate();
    var found_kernels = false;
    
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        
        // Only show zenv-managed kernels
        if (std.mem.startsWith(u8, entry.name, "zenv-")) {
            if (!found_kernels) {
                try output.print(allocator, "Zenv-managed Jupyter kernels:", .{});
                found_kernels = true;
            }
            
            const env_name = entry.name[5..]; // Remove "zenv-" prefix
            try output.print(allocator, "  - {s} (environment: {s})", .{ entry.name, env_name });
        }
    }
    
    if (!found_kernels) {
        try output.print(allocator, "No zenv-managed Jupyter kernels found", .{});
    }
}

/// Check Jupyter installation and show status
pub fn checkJupyter(allocator: Allocator) !void {
    if (isJupyterAvailable(allocator)) {
        try output.print(allocator, "Jupyter is installed and available", .{});
        
        const jupyter_data_dir = try getJupyterDataDir(allocator);
        defer allocator.free(jupyter_data_dir);
        
        try output.print(allocator, "Jupyter data directory: {s}", .{jupyter_data_dir});
        
        const kernels_dir = try std.fmt.allocPrint(allocator, "{s}/kernels", .{jupyter_data_dir});
        defer allocator.free(kernels_dir);
        
        if (std.fs.accessAbsolute(kernels_dir, .{})) |_| {
            try output.print(allocator, "Kernels directory: {s}", .{kernels_dir});
        } else |err| switch (err) {
            error.FileNotFound => {
                try output.print(allocator, "Kernels directory does not exist (will be created when needed)", .{});
            },
            else => {
                try output.printError(allocator, "Cannot access kernels directory: {s}", .{@errorName(err)});
            },
        }
    } else {
        try output.printError(allocator, "Jupyter is not installed or not available in PATH", .{});
        try output.print(allocator, "Install Jupyter with: pip install jupyter", .{});
    }
}