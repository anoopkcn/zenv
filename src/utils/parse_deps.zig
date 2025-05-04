const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap(void);
const config = @import("config.zig");
const errors = @import("errors.zig");
const output = @import("output.zig");

// Helper function to parse a line containing potential dependencies (used by parsePyprojectToml)
// Not marked pub as it's internal to this module
fn parseDependenciesLine(
    allocator: Allocator,
    line: []const u8,
    deps_list: *std.ArrayList([]const u8),
    count: *usize,
) !void {
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
            if (quoted_content.len > 0 and isLikelyPythonPackageName(quoted_content)) {
                // Keep the version specifier for pip compatibility
                const dep = try allocator.dupe(u8, quoted_content);
                // errdefer allocator.free(dep); // Ensure cleanup if append fails - handled by caller's defer usually
                try output.print("  - TOML array dependency: {s}", .{dep});
                try deps_list.append(dep);
                count.* += 1;
            } else if (quoted_content.len > 0) {
                try output.print("  - Skipping non-package entry: {s}", .{quoted_content});
            }
        }

        pos = quote_end + 1;
    }
}

// Helper to check if a string is a common metadata field, not a dependency
fn isLikelyPythonPackageName(package_name: []const u8) bool {
    // Skip common metadata fields
    const meta_fields = [_][]const u8{
        "name", "version", "description", "authors", "license",
        "keywords", "classifiers", "readme", "homepage", "repository",
        "documentation", "requires-python", "python-requires", "url",
        "project", "tool", "build-system", "dev-dependencies"
    };

    // If it's a known metadata field, it's not a package
    for (meta_fields) |field| {
        if (std.mem.eql(u8, package_name, field)) {
            return false;
        }
    }

    // If the string starts with a bracket or brace, not a package name
    if (package_name.len > 0 and (package_name[0] == '{' or package_name[0] == '[')) {
        return false;
    }

    // If the string contains spaces, probably not a package name
    if (std.mem.indexOf(u8, package_name, " ") != null) {
        return false;
    }

    return true;
}

// Improved TOML parsing function
pub fn parsePyprojectToml(
    allocator: Allocator,
    content: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    try output.print("Parsing pyproject.toml for dependencies...", .{});

    var count: usize = 0;

    // Create a state machine for parsing
    const ParseState = enum {
        searching,          // Looking for dependency sections
        in_project_deps,    // In [project.dependencies] section (PEP 621)
        in_poetry_deps,     // In [tool.poetry.dependencies] section
        in_deps_array,      // Inside a dependencies = [...] array
        in_table,           // In a table like dependencies = { ... }
    };

    var state = ParseState.searching;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var in_multiline_string: bool = false;
    var multiline_delimiter: ?u8 = null;
    var found_content = false;

    // Store table fields for later processing
    var table_entries = std.ArrayList([]const u8).init(allocator);
    defer {
        for (table_entries.items) |entry| {
            allocator.free(entry);
        }
        table_entries.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Track multiline string state
        if (in_multiline_string) {
            // Check for closing delimiter
            if (multiline_delimiter) |delim| {
                const delim_str = if (delim == '"') "\"\"\"" else "'''";
                if (std.mem.indexOf(u8, trimmed, delim_str)) |_| {
                    in_multiline_string = false;
                    multiline_delimiter = null;
                }
            }
            continue; // Skip processing inside multiline strings
        } else {
            // Check for opening triple quotes
            if (std.mem.indexOf(u8, trimmed, "\"\"\"")) |_| {
                in_multiline_string = true;
                multiline_delimiter = '"';
                continue;
            } else if (std.mem.indexOf(u8, trimmed, "'''")) |_| {
                in_multiline_string = true;
                multiline_delimiter = '\'';
                continue;
            }
        }

        // Track bracket and brace depth for arrays and tables
        for (trimmed) |c| {
            if (c == '[') bracket_depth += 1;
            if (c == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
                // If we're in a dependencies array and closing the last bracket
                if (state == ParseState.in_deps_array and bracket_depth == 0) {
                    state = ParseState.searching;
                }
            }
            if (c == '{') brace_depth += 1;
            if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
                // If we're in a dependencies table and closing the last brace
                if (state == ParseState.in_table and brace_depth == 0) {
                    state = ParseState.searching;
                }
            }
        }

        // Check for dependency section headers based on current state
        switch (state) {
            .searching => {
                // Match various dependency section patterns
                if (std.mem.indexOf(u8, trimmed, "[project.dependencies]") != null) {
                    try output.print("Found PEP 621 dependencies section at line {d}", .{line_number});
                    state = ParseState.in_project_deps;
                    found_content = true;
                    continue;
                } else if (std.mem.indexOf(u8, trimmed, "[tool.poetry.dependencies]") != null) {
                    try output.print("Found Poetry dependencies section at line {d}", .{line_number});
                    state = ParseState.in_poetry_deps;
                    found_content = true;
                    continue;
                } else if (isStandaloneDepArray(trimmed)) {
                    try output.print("Found standalone dependencies array at line {d}", .{line_number});
                    state = ParseState.in_deps_array;
                    bracket_depth = 1; // We're inside one array bracket

                    // Process any deps on this line
                    const opening_bracket = std.mem.indexOf(u8, trimmed, "[") orelse continue;
                    const line_after_bracket = trimmed[opening_bracket + 1 ..];
                    try parseDependenciesLine(allocator, line_after_bracket, deps_list, &count);
                    found_content = true;
                    continue;
                } else if (isStandaloneDepTable(trimmed)) {
                    try output.print("Found dependencies table at line {d}", .{line_number});
                    state = ParseState.in_table;
                    brace_depth = 1; // We're inside one table brace
                    found_content = true;
                    continue;
                }

                // Exit current section if we reach a new section header
                if (std.mem.indexOf(u8, trimmed, "[") == 0 and std.mem.indexOf(u8, trimmed, "]") != null) {
                    continue;
                }
            },

            .in_project_deps, .in_poetry_deps => {
                // Exit section if new section starts
                if (std.mem.indexOf(u8, trimmed, "[") == 0 and std.mem.indexOf(u8, trimmed, "]") != null) {
                    state = ParseState.searching;
                    continue;
                }

                // Check for package = "version" or package = {version = "1.0"}
                if (std.mem.indexOf(u8, trimmed, "=") != null) {
                    try processPackageLine(allocator, trimmed, deps_list, &count, &table_entries);
                    found_content = true;
                }
            },

            .in_deps_array => {
                // Process array elements
                try parseDependenciesLine(allocator, trimmed, deps_list, &count);
                found_content = true;
            },

            .in_table => {
                // Store table entry for later processing
                if (trimmed.len > 0 and bracket_depth == 0) {
                    // Capture the whole table entry line
                    const entry_copy = try allocator.dupe(u8, trimmed);
                    try table_entries.append(entry_copy);
                    found_content = true;
                }
            },
        }
    }

    // Process any collected table entries
    if (table_entries.items.len > 0) {
        try processTableEntries(allocator, table_entries.items, deps_list, &count);
    }

    if (count > 0) {
        try output.print("Found {d} dependencies in pyproject.toml", .{count});
    } else if (found_content) {
        try output.print("Processed TOML content but found no valid dependencies", .{});
    } else {
        try output.print("No recognized dependency sections found in pyproject.toml", .{});
    }

    return count;
}

// Helper to check if a line is a standalone dependencies array declaration
fn isStandaloneDepArray(line: []const u8) bool {
    // Match patterns like "dependencies = [" or "dependencies=[" but not "dev-dependencies = ["
    const deps_str = "dependencies";

    if (std.mem.indexOf(u8, line, deps_str)) |pos| {
        // Ensure it's at the start of the line or after whitespace
        if (pos == 0 or std.ascii.isWhitespace(line[pos-1])) {
            // Check that = and [ appear after dependencies
            const eq_pos = std.mem.indexOfPos(u8, line, pos + deps_str.len, "=");
            if (eq_pos) |eq| {
                const bracket_pos = std.mem.indexOfPos(u8, line, eq + 1, "[");
                return bracket_pos != null;
            }
        }
    }
    return false;
}

// Helper to check if a line is a standalone dependencies table declaration
fn isStandaloneDepTable(line: []const u8) bool {
    // Match patterns like "dependencies = {" or "dependencies={"
    const deps_str = "dependencies";

    if (std.mem.indexOf(u8, line, deps_str)) |pos| {
        // Ensure it's at the start of the line or after whitespace
        if (pos == 0 or std.ascii.isWhitespace(line[pos-1])) {
            // Check that = and { appear after dependencies
            const eq_pos = std.mem.indexOfPos(u8, line, pos + deps_str.len, "=");
            if (eq_pos) |eq| {
                const brace_pos = std.mem.indexOfPos(u8, line, eq + 1, "{");
                return brace_pos != null;
            }
        }
    }
    return false;
}

// Process a single package entry line from a dependency section
fn processPackageLine(
    allocator: Allocator,
    line: []const u8,
    deps_list: *std.ArrayList([]const u8),
    count: *usize,
    table_entries: *std.ArrayList([]const u8),
) !void {
    var parts = std.mem.splitScalar(u8, line, '=');
    if (parts.next()) |package_name_raw| {
        const package_name = std.mem.trim(u8, package_name_raw, " \t\r");

        if (package_name.len > 0 and isLikelyPythonPackageName(package_name)) {
            // Check for inline table with version field
            if (std.mem.indexOf(u8, line, "{") != null) {
                // Store for processing in batch
                const line_copy = try allocator.dupe(u8, line);
                try table_entries.append(line_copy);
            } else {
                // Simple dependency, no inline table
                const dep = try allocator.dupe(u8, package_name);
                try output.print("  - TOML individual dependency: {s}", .{dep});
                try deps_list.append(dep);
                count.* += 1;
            }
        } else if (package_name.len > 0) {
            try output.print("  - Skipping non-package key: {s}", .{package_name});
        }
    }
}

// Process collected table entries to extract package names
fn processTableEntries(
    allocator: Allocator,
    entries: []const []const u8,
    deps_list: *std.ArrayList([]const u8),
    count: *usize,
) !void {
    for (entries) |entry| {
        var parts = std.mem.splitScalar(u8, entry, '=');
        if (parts.next()) |package_name_raw| {
            const package_name = std.mem.trim(u8, package_name_raw, " \t\r");

            if (package_name.len > 0 and isLikelyPythonPackageName(package_name)) {
                const dep = try allocator.dupe(u8, package_name);
                try output.print("  - TOML table dependency: {s}", .{dep});
                try deps_list.append(dep);
                count.* += 1;
            }
        }
    }
}

// Parse dependencies from requirements.txt format content
// Returns the number of dependencies found
pub fn parseRequirementsTxt(
    allocator: Allocator,
    content: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    try output.print("Parsing requirements.txt for dependencies...", .{});
    var count: usize = 0;

    // Create a reusable buffer to minimize allocations
    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    // Split lines more efficiently with iterator directly
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    
    while (line_iter.next()) |line| {
        // Skip empty lines and comments early
        if (line.len == 0) continue;
        
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        // For valid dependencies, add directly
        try output.print("  - Requirements file dependency: {s}", .{trimmed_line});

        // Create a duplicate of the trimmed line
        const trimmed_dupe = try allocator.dupe(u8, trimmed_line);
        
        // Add the dependency
        try deps_list.append(trimmed_dupe);
        count += 1;
    }
    try output.print("Found {d} dependencies in requirements.txt format", .{count});
    return count;
}

// Validate raw dependencies, remove duplicates and invalid entries
pub fn validateDependencies(
    allocator: Allocator,
    raw_deps: []const []const u8,
    env_name: []const u8,
) !std.ArrayList([]const u8) {
    try output.print("Validating dependencies for '{s}':", .{env_name});
    var valid_deps = std.ArrayList([]const u8).init(allocator);
    // Improved error handling with explicit cleanup of any added items
    errdefer {
        // Only free items we owned and added to valid_deps
        valid_deps.deinit();
    }

    // Create a hashmap to track seen package names (case-insensitive)
    var seen_packages = StringHashMap.init(allocator);
    defer seen_packages.deinit();

    // Reuse a buffer for lowercase string conversion to reduce allocations
    var lowercase_buf = std.ArrayList(u8).init(allocator);
    defer lowercase_buf.deinit();

    for (raw_deps) |dep| {
        if (dep.len == 0) {
            try output.print("Warning: Skipping empty dependency", .{});
            continue;
        }

        // Skip deps that look like file paths
        if (std.mem.indexOf(u8, dep, "/") != null) {
            try output.print("Warning: Skipping dependency that looks like a path: '{s}'", .{dep});
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
            try output.print("Warning: Skipping invalid dependency: '{s}'", .{dep});
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
        // Reuse the same buffer to avoid repeated allocations
        lowercase_buf.clearRetainingCapacity();
        try lowercase_buf.ensureTotalCapacity(package_name_raw.len);
        for (package_name_raw) |c| {
            try lowercase_buf.append(std.ascii.toLower(c));
        }

        // Check if we've already seen this package (case-insensitive)
        if (seen_packages.contains(lowercase_buf.items)) {
            try output.print("Warning: Skipping duplicate package '{s}' (already included in dependencies)", .{dep});
            continue;
        }

        // Accept this dependency as valid
        try output.print("Including dependency: '{s}'", .{dep});
        try valid_deps.append(dep);

        // Add the lowercase name to the seen set using a key we create and own
        const lowercase_key = try allocator.dupe(u8, lowercase_buf.items);
        errdefer allocator.free(lowercase_key);
        try seen_packages.put(lowercase_key, {});
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
