const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap(void);
const config = @import("config.zig");

// Helper function to parse a line containing potential dependencies (used by parsePyprojectToml)
// Not marked pub as it's internal to this module
fn parseDependenciesLine(allocator: Allocator, line: []const u8, deps_list: *std.ArrayList([]const u8), count: *usize) !void {
    // Handle quoted strings in arrays: "package1", "package2"
    var pos: usize = 0;
    while (pos < line.len) {
        // Find opening quote
        const quote_start = std.mem.indexOfPos(u8, line, pos, "\"") orelse
            std.mem.indexOfPos(u8, line, pos, "'") orelse
            break;
        const quote_char = line[quote_start];
        pos = quote_start + 1;

        // Find closing quote
        const quote_end = std.mem.indexOfPos(u8, line, pos, &[_]u8{quote_char}) orelse break;

        // Extract package name with version
        if (quote_end > pos) {
            const quoted_content = std.mem.trim(u8, line[pos..quote_end], " \t\r");
            if (quoted_content.len > 0) {
                // Keep the version specifier for pip compatibility
                const dep = try allocator.dupe(u8, quoted_content);
                // errdefer allocator.free(dep); // Ensure cleanup if append fails - handled by caller's defer usually
                std.log.info("  - TOML array dependency: {s}", .{dep});
                try deps_list.append(dep);
                count.* += 1;
            }
        }

        pos = quote_end + 1;
    }
}

// Parse dependencies from pyproject.toml file
// Returns the number of dependencies found
pub fn parsePyprojectToml(allocator: Allocator, content: []const u8, deps_list: *std.ArrayList([]const u8)) !usize {
    std.log.info("Parsing pyproject.toml for dependencies...", .{});

    var count: usize = 0;
    var in_dependencies_section = false;
    var in_dependencies_array = false;
    var bracket_depth: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Check for the dependencies section in different possible formats
        if (!in_dependencies_section) {
            // Match [project.dependencies] or [tool.poetry.dependencies]
            if (std.mem.indexOf(u8, trimmed, "[project.dependencies]") != null or
                std.mem.indexOf(u8, trimmed, "[tool.poetry.dependencies]") != null)
            {
                std.log.info("Found project dependencies section", .{});
                in_dependencies_section = true;
                continue;
            }

            // Match dependencies = [ ... on a single line
            if (std.mem.indexOf(u8, trimmed, "dependencies") != null and
                std.mem.indexOf(u8, trimmed, "=") != null and
                std.mem.indexOf(u8, trimmed, "[") != null)
            {
                std.log.info("Found dependencies array declaration", .{});
                in_dependencies_section = true;
                in_dependencies_array = true;
                bracket_depth = 1;

                // If the line contains deps, process them
                const opening_bracket = std.mem.indexOf(u8, trimmed, "[") orelse continue;
                const line_after_bracket = trimmed[opening_bracket + 1 ..];
                try parseDependenciesLine(allocator, line_after_bracket, deps_list, &count);
                continue;
            }

            // If we see another section after looking for dependencies, we've gone too far
            if (std.mem.indexOf(u8, trimmed, "[") == 0 and
                std.mem.indexOf(u8, trimmed, "]") != null)
            {
                continue; // Skip to next section
            }
        }
        // Already in dependencies section
        else {
            // Check if we've hit a new section
            if (std.mem.indexOf(u8, trimmed, "[") == 0 and
                std.mem.indexOf(u8, trimmed, "]") != null)
            {
                std.log.info("End of dependencies section", .{});
                in_dependencies_section = false;
                in_dependencies_array = false;
                continue;
            }

            // If we're in a dependencies array, look for the array elements
            if (in_dependencies_array) {
                // Update bracket depth
                for (trimmed) |c| {
                    if (c == '[') bracket_depth += 1;
                    if (c == ']') {
                        bracket_depth -= 1;
                        if (bracket_depth == 0) {
                            in_dependencies_array = false;
                            break;
                        }
                    }
                }

                try parseDependenciesLine(allocator, trimmed, deps_list, &count);
            }
            // If we're in the dependencies section but haven't found the array yet
            else if (std.mem.indexOf(u8, trimmed, "dependencies") != null and
                std.mem.indexOf(u8, trimmed, "=") != null)
            {
                std.log.info("Found dependencies array", .{});
                in_dependencies_array = true;

                // Check if array starts on this line
                if (std.mem.indexOf(u8, trimmed, "[") != null) {
                    bracket_depth = 1;
                    const opening_bracket = std.mem.indexOf(u8, trimmed, "[") orelse continue;
                    const line_after_bracket = trimmed[opening_bracket + 1 ..];
                    try parseDependenciesLine(allocator, line_after_bracket, deps_list, &count);
                }
            }
            // If we're not in an array but in dependencies section, look for individual dependencies
            else if (std.mem.indexOf(u8, trimmed, "=") != null) {
                // This is for the format: package = "version" or package = {version="1.0"}
                var parts = std.mem.splitScalar(u8, trimmed, '=');
                if (parts.next()) |package_name| {
                    const package = std.mem.trim(u8, package_name, " \t\r");
                    if (package.len > 0) {
                        // Create a valid pip-style dependency (keep version specifiers)
                        const dep = try allocator.dupe(u8, package);
                        // errdefer allocator.free(dep); // Handled by caller's defer
                        std.log.info("  - TOML individual dependency: {s}", .{dep});
                        try deps_list.append(dep);
                        count += 1;
                    }
                }
            }
        }
    }

    std.log.info("Found {d} dependencies in pyproject.toml", .{count});
    return count;
}

// Parse dependencies from requirements.txt format content
// Returns the number of dependencies found
pub fn parseRequirementsTxt(allocator: Allocator, content: []const u8, deps_list: *std.ArrayList([]const u8)) !usize {
    std.log.info("Parsing requirements.txt for dependencies...", .{});
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            // Skip empty lines and comments
            std.log.debug("Skipping comment or empty line: '{s}'", .{trimmed_line});
            continue;
        }

        // Log each dependency being added
        std.log.info("  - Requirements file dependency: {s}", .{trimmed_line});

        // Create a duplicate of the trimmed line to ensure it persists
        const trimmed_dupe = try allocator.dupe(u8, trimmed_line);
        errdefer allocator.free(trimmed_dupe); // Clean up if append fails

        // Add the dependency
        try deps_list.append(trimmed_dupe);
        count += 1;
    }
    std.log.info("Found {d} dependencies in requirements.txt format", .{count});
    return count;
}

// Validate raw dependencies, remove duplicates and invalid entries
pub fn validateDependencies(allocator: Allocator, raw_deps: []const []const u8, env_name: []const u8) !std.ArrayList([]const u8) {
    std.log.info("Validating dependencies for '{s}':", .{env_name});
    var valid_deps = std.ArrayList([]const u8).init(allocator);
    errdefer valid_deps.deinit(); // Clean up if an error occurs during allocation

    // Create a hashmap to track seen package names (case-insensitive) with owned keys
    var seen_packages = StringHashMap.init(allocator);
    defer {
        // Free all the keys we've stored
        var keys_iter = seen_packages.keyIterator();
        while (keys_iter.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        seen_packages.deinit();
    }

    for (raw_deps) |dep| {
        if (dep.len == 0) {
            std.log.warn("Skipping empty dependency", .{});
            continue;
        }

        // Skip deps that look like file paths
        if (std.mem.indexOf(u8, dep, "/") != null) {
            std.log.warn("Skipping dependency that looks like a path: '{s}'", .{dep});
            continue;
        }

        // Skip deps without a valid package name (only allow common Python package name chars)
        var valid = true;
        var has_alpha = false;
        for (dep) |c| {
            // Allow alphanumeric, hyphen, underscore, dot, and comparison operators/brackets
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                has_alpha = true;
            } else if (!((c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or
                c == '>' or c == '<' or c == '=' or c == '~' or c == ' ' or c == '[' or c == ']'))
            {
                valid = false;
                break;
            }
        }

        if (!valid or !has_alpha) {
            std.log.warn("Skipping invalid dependency: '{s}'", .{dep});
            continue;
        }

        // Extract the package name to check for duplicates (case-insensitive check)
        var package_name_raw: []const u8 = undefined;
        if (std.mem.indexOfAny(u8, dep, "<>=~")) |op_idx| {
            package_name_raw = std.mem.trim(u8, dep[0..op_idx], " ");
        } else if (std.mem.indexOfScalar(u8, dep, '[')) |bracket_idx| {
            package_name_raw = std.mem.trim(u8, dep[0..bracket_idx], " ");
        } else {
            // Just the package name without version
            package_name_raw = std.mem.trim(u8, dep, " ");
        }

        // Convert package name to lowercase for case-insensitive duplicate check
        // We need to own the lowercase string to put it in the hash map
        const package_name_lower_owned = try allocator.alloc(u8, package_name_raw.len);
        // Need a defer to free this if putting into the map fails or we continue
        // However, if put succeeds, the map owns it, so it's complex.
        // Let's allocate, put, and handle freeing in the map's defer.
        _ = std.ascii.lowerString(package_name_lower_owned, package_name_raw);

        // Check if we've already seen this package (case-insensitive)
        if (seen_packages.contains(package_name_lower_owned)) {
            std.log.warn("Skipping duplicate package '{s}' (already included in dependencies)", .{dep});
            allocator.free(package_name_lower_owned); // Free if duplicate
            continue;
        }

        // Accept this dependency as valid
        std.log.info("Including dependency: '{s}'", .{dep});
        // Note: valid_deps contains slices pointing to the original `deps` argument OR
        // slices pointing to duplicated strings from parseRequirementsTxt/parsePyprojectToml.
        // The caller needs to manage the lifetime of these strings.
        try valid_deps.append(dep);

        // Add the owned lowercase name to the seen set. If put fails, free the key.
        seen_packages.put(package_name_lower_owned, {}) catch |err| {
            allocator.free(package_name_lower_owned);
            return err;
        };
    }

    return valid_deps;
}

// Helper function to determine if a dependency was provided in the config
// Used for memory management to avoid double freeing strings
// Requires access to EnvironmentConfig, which needs to be imported by the caller.
pub fn isConfigProvidedDependency(env_config: *const config.EnvironmentConfig, dep: []const u8) bool {
    for (env_config.dependencies.items) |config_dep| {
        if (std.mem.eql(u8, config_dep, dep)) {
            return true;
        }
    }
    return false;
}
