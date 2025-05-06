const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const fs = std.fs;
const paths = @import("paths.zig");
const output = @import("output.zig");
const download = @import("download.zig");
const json = std.json;

/// Metadata about a cached package
const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
    url: []const u8,
    pypi_url: []const u8,
    requires_python: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    cache_path: []const u8,
    timestamp: i64,
};

/// Package cache manager
pub const PackageCache = struct {
    allocator: Allocator,
    cache_dir: []const u8,
    files_dir: []const u8,
    index_path: []const u8,
    packages: std.StringHashMap(PackageInfo),
    
    /// Initialize the package cache
    pub fn init(allocator: Allocator) !*PackageCache {
        // Get the ZENV_DIR path
        const zenv_dir = try paths.ensureZenvDir(allocator);
        defer allocator.free(zenv_dir);
        
        // Create cache directory paths
        const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ zenv_dir, "packages" });
        const files_dir = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, "files" });
        const index_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, "index.json" });
        
        // Create directories if they don't exist
        std.fs.makeDirAbsolute(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        std.fs.makeDirAbsolute(files_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        // Allocate the cache manager
        var cache = try allocator.create(PackageCache);
        cache.* = .{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .files_dir = files_dir,
            .index_path = index_path,
            .packages = std.StringHashMap(PackageInfo).init(allocator),
        };
        
        // Load existing index
        try cache.loadIndex();
        
        return cache;
    }
    
    /// Clean up all resources
    pub fn deinit(self: *PackageCache) void {
        // Free packages hashmap entries
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.version);
            self.allocator.free(entry.value_ptr.filename);
            self.allocator.free(entry.value_ptr.url);
            self.allocator.free(entry.value_ptr.pypi_url);
            if (entry.value_ptr.requires_python) |rp| {
                self.allocator.free(rp);
            }
            if (entry.value_ptr.sha256) |sha| {
                self.allocator.free(sha);
            }
            self.allocator.free(entry.value_ptr.cache_path);
        }
        self.packages.deinit();
        
        // Free directories
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.files_dir);
        self.allocator.free(self.index_path);
        
        // Free self
        self.allocator.destroy(self);
    }
    
    /// Load the existing package index
    fn loadIndex(self: *PackageCache) !void {
        // Try to open the index file
        const file = std.fs.openFileAbsolute(self.index_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Create an empty index if it doesn't exist
                return self.saveIndex();
            }
            return err;
        };
        defer file.close();
        
        // Read and parse the index JSON
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        
        var parsed = try json.parseFromSlice(json.Value, self.allocator, content, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        
        // Load packages from the parsed JSON
        const root = parsed.value;
        if (root.object.get("packages")) |packages_value| {
            if (packages_value != .object) return;
            
            var it = packages_value.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                
                const package_obj = entry.value_ptr.*.object;
                
                // Extract package info
                const name_val = package_obj.get("name") orelse continue;
                const version_val = package_obj.get("version") orelse continue;
                const filename_val = package_obj.get("filename") orelse continue;
                const url_val = package_obj.get("url") orelse continue;
                const pypi_url_val = package_obj.get("pypi_url") orelse continue;
                const cache_path_val = package_obj.get("cache_path") orelse continue;
                const timestamp_val = package_obj.get("timestamp") orelse continue;
                
                if (name_val != .string or version_val != .string or 
                    filename_val != .string or url_val != .string or 
                    pypi_url_val != .string or cache_path_val != .string or 
                    timestamp_val != .integer) {
                    continue;
                }
                
                const name = try self.allocator.dupe(u8, name_val.string);
                const version = try self.allocator.dupe(u8, version_val.string);
                const filename = try self.allocator.dupe(u8, filename_val.string);
                const url = try self.allocator.dupe(u8, url_val.string);
                const pypi_url = try self.allocator.dupe(u8, pypi_url_val.string);
                const cache_path = try self.allocator.dupe(u8, cache_path_val.string);
                const timestamp = timestamp_val.integer;
                
                // Optional fields
                var requires_python: ?[]const u8 = null;
                if (package_obj.get("requires_python")) |rp| {
                    if (rp == .string) {
                        requires_python = try self.allocator.dupe(u8, rp.string);
                    }
                }
                
                var sha256: ?[]const u8 = null;
                if (package_obj.get("sha256")) |sha| {
                    if (sha == .string) {
                        sha256 = try self.allocator.dupe(u8, sha.string);
                    }
                }
                
                // Create and store package info
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                try self.packages.put(key, .{
                    .name = name,
                    .version = version,
                    .filename = filename,
                    .url = url,
                    .pypi_url = pypi_url,
                    .requires_python = requires_python,
                    .sha256 = sha256,
                    .cache_path = cache_path,
                    .timestamp = timestamp,
                });
            }
        }
    }
    
    /// Save the package index to disk
    fn saveIndex(self: *PackageCache) !void {
        var root = std.json.ObjectMap.init(self.allocator);
        defer root.deinit();
        
        var packages = std.json.ObjectMap.init(self.allocator);
        defer packages.deinit();
        
        // Add each package to the packages object
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            var pkg = std.json.ObjectMap.init(self.allocator);
            
            try pkg.put("name", std.json.Value{ .string = entry.value_ptr.name });
            try pkg.put("version", std.json.Value{ .string = entry.value_ptr.version });
            try pkg.put("filename", std.json.Value{ .string = entry.value_ptr.filename });
            try pkg.put("url", std.json.Value{ .string = entry.value_ptr.url });
            try pkg.put("pypi_url", std.json.Value{ .string = entry.value_ptr.pypi_url });
            try pkg.put("cache_path", std.json.Value{ .string = entry.value_ptr.cache_path });
            try pkg.put("timestamp", std.json.Value{ .integer = entry.value_ptr.timestamp });
            
            if (entry.value_ptr.requires_python) |rp| {
                try pkg.put("requires_python", std.json.Value{ .string = rp });
            }
            
            if (entry.value_ptr.sha256) |sha| {
                try pkg.put("sha256", std.json.Value{ .string = sha });
            }
            
            try packages.put(entry.key_ptr.*, std.json.Value{ .object = pkg });
        }
        
        // Add packages to root
        try root.put("packages", std.json.Value{ .object = packages });
        
        // Serialize to JSON
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        
        try std.json.stringify(
            std.json.Value{ .object = root },
            .{ .whitespace = .indent_2 },
            buf.writer(),
        );
        
        // Write to file
        var file = try std.fs.createFileAbsolute(self.index_path, .{});
        defer file.close();
        
        try file.writeAll(buf.items);
    }
    
    /// Check if a package is already cached
    pub fn isPackageCached(self: *PackageCache, package_name: []const u8, version: ?[]const u8) bool {
        // If no version specified, we can't check without an API call
        if (version == null) {
            return false;
        }
        
        // Create cache key
        const key_buf = std.fmt.allocPrintZ(self.allocator, "{s}-{s}", .{
            package_name, version.?
        }) catch return false;
        defer self.allocator.free(key_buf);
        
        return self.packages.contains(key_buf);
    }
    
    /// Download a Python package from PyPI
    pub fn downloadPackage(self: *PackageCache, package_spec: []const u8, version_arg: ?[]const u8) !void {
        try output.print("Fetching package info for {s}", .{package_spec});
        
        // Parse package name and version from package_spec (e.g., "package>=1.0.0")
        const package_name = package_spec;
        var version_constraint: ?[]const u8 = version_arg;
        
        // Extract base name without version specifier for PyPI URL
        var base_name = package_spec;
        if (std.mem.indexOfAny(u8, package_spec, "<>=~^")) |idx| {
            base_name = std.mem.trim(u8, package_spec[0..idx], " \t");
            if (version_constraint == null) {
                version_constraint = std.mem.trim(u8, package_spec[idx..], " \t");
            }
        }
        
        // Construct PyPI URL with base name only
        const pypi_url = try std.fmt.allocPrint(
            self.allocator,
            "https://pypi.org/pypi/{s}/json",
            .{base_name}
        );
        defer self.allocator.free(pypi_url);
        
        // Use client.fetch to get package info from PyPI
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();
        
        const response = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = pypi_url },
            .response_storage = .{ .dynamic = &response_body },
        });
        
        if (response.status != .ok) {
            try output.printError("Package '{s}' not found on PyPI (status: {d})", .{
                package_name, @intFromEnum(response.status)
            });
            return error.PackageNotFound;
        }
        
        // Parse JSON response
        var parsed = try json.parseFromSlice(json.Value, self.allocator, response_body.items, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        
        const root = parsed.value;
        
        // Get the latest version if none specified, or use the one from version constraint
        const target_version = if (version_constraint == null) blk: {
            const info = root.object.get("info") orelse return error.InvalidResponse;
            if (info != .object) return error.InvalidResponse;
            
            const latest_version = info.object.get("version") orelse return error.InvalidResponse;
            if (latest_version != .string) return error.InvalidResponse;
            
            break :blk latest_version.string;
        } else if (version_arg != null) version_arg.? else blk: {
            // Handle version constraint like >=1.0.0
            // For now, just use latest version as a simple approach
            const info = root.object.get("info") orelse return error.InvalidResponse;
            if (info != .object) return error.InvalidResponse;
            
            const latest_version = info.object.get("version") orelse return error.InvalidResponse;
            if (latest_version != .string) return error.InvalidResponse;
            
            break :blk latest_version.string;
        };
        
        try output.print("Looking for version {s} of {s}", .{target_version, base_name});
        
        // Check if we already have this package version
        const cache_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}",
            .{base_name, target_version}
        );
        defer self.allocator.free(cache_key);
        
        if (self.packages.contains(cache_key)) {
            try output.print("Package {s} version {s} already cached", .{
                package_name, target_version
            });
            return;
        }
        
        // Find the distribution files
        const releases = root.object.get("releases") orelse return error.InvalidResponse;
        if (releases != .object) return error.InvalidResponse;
        
        // Try to find the specified version
        const version_releases = releases.object.get(target_version) orelse {
            try output.printError("Version {s} not found for package {s}", .{
                target_version, package_name
            });
            return error.VersionNotFound;
        };
        
        if (version_releases != .array) return error.InvalidResponse;
        
        const release_files = version_releases.array;
        if (release_files.items.len == 0) {
            try output.printError("No files found for package {s} version {s}", .{
                package_name, target_version
            });
            return error.NoFilesFound;
        }
        
        // Look for a wheel file first, then source distribution
        var selected_file: ?json.Value = null;
        
        // First pass: look for a wheel file for the current platform
        for (release_files.items) |file| {
            if (file != .object) continue;
            
            const packagetype = file.object.get("packagetype") orelse continue;
            if (packagetype != .string) continue;
            
            const filename = file.object.get("filename") orelse continue;
            if (filename != .string) continue;
            
            if (std.mem.eql(u8, packagetype.string, "bdist_wheel") and 
                (std.mem.indexOf(u8, filename.string, "any") != null or 
                 std.mem.indexOf(u8, filename.string, "linux") != null or
                 std.mem.indexOf(u8, filename.string, "macosx") != null)) {
                selected_file = file;
                break;
            }
        }
        
        // Second pass: look for any wheel file
        if (selected_file == null) {
            for (release_files.items) |file| {
                if (file != .object) continue;
                
                const packagetype = file.object.get("packagetype") orelse continue;
                if (packagetype != .string) continue;
                
                if (std.mem.eql(u8, packagetype.string, "bdist_wheel")) {
                    selected_file = file;
                    break;
                }
            }
        }
        
        // Third pass: accept any source distribution
        if (selected_file == null) {
            for (release_files.items) |file| {
                if (file != .object) continue;
                
                const packagetype = file.object.get("packagetype") orelse continue;
                if (packagetype != .string) continue;
                
                if (std.mem.eql(u8, packagetype.string, "sdist")) {
                    selected_file = file;
                    break;
                }
            }
        }
        
        if (selected_file == null) {
            try output.printError("No suitable distribution found for {s} version {s}", .{
                package_name, target_version
            });
            return error.NoSuitableDistribution;
        }
        
        // Get file info
        const file = selected_file.?.object;
        
        const filename = file.get("filename") orelse return error.InvalidResponse;
        if (filename != .string) return error.InvalidResponse;
        
        const url = file.get("url") orelse return error.InvalidResponse;
        if (url != .string) return error.InvalidResponse;
        
        var sha256_val: ?[]const u8 = null;
        if (file.get("digests")) |digests| {
            if (digests == .object) {
                if (digests.object.get("sha256")) |sha256| {
                    if (sha256 == .string) {
                        sha256_val = sha256.string;
                    }
                }
            }
        }
        
        // Download the file
        const cache_path = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ self.files_dir, filename.string }
        );
        errdefer self.allocator.free(cache_path);
        
        try download.downloadFile(self.allocator, url.string, cache_path, .{
            .show_progress = true,
        });
        
        // Add package to cache
        const cache_info = PackageInfo{
            .name = try self.allocator.dupe(u8, base_name),
            .version = try self.allocator.dupe(u8, target_version),
            .filename = try self.allocator.dupe(u8, filename.string),
            .url = try self.allocator.dupe(u8, url.string),
            .pypi_url = try self.allocator.dupe(u8, pypi_url),
            .sha256 = if (sha256_val) |sha| try self.allocator.dupe(u8, sha) else null,
            .cache_path = cache_path,
            .timestamp = std.time.milliTimestamp(),
        };
        
        const key_duped = try self.allocator.dupe(u8, cache_key);
        errdefer self.allocator.free(key_duped);
        
        try self.packages.put(key_duped, cache_info);
        
        // Save the updated index
        try self.saveIndex();
        
        try output.print("Successfully cached {s} version {s}", .{
            base_name, target_version
        });
    }
    
    /// Return the path to the packages cache directory
    pub fn getCacheDir(self: *const PackageCache) []const u8 {
        return self.files_dir;
    }
};