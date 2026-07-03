const std = @import("std");

pub const SecretError = error{
    ContainsSecret,
};

/// Scans a text buffer for common secret patterns.
/// Returns error.ContainsSecret if a known pattern is detected.
pub fn scan(buffer: []const u8) SecretError!void {
    const known_patterns = &[_][]const u8{
        "AIza",            // Google API Key prefix
        "sk-",             // Stripe, OpenAI, etc.
        "BEGIN PRIVATE KEY", // PEM Private Key
        "BEGIN RSA PRIVATE KEY",
        "ghp_",            // GitHub Personal Access Token
    };

    for (known_patterns) |pattern| {
        if (std.mem.indexOf(u8, buffer, pattern) != null) {
            return error.ContainsSecret;
        }
    }
}

/// Helper function to check if a filename is inherently secret (e.g., .env)
pub fn isSecretFile(filename: []const u8) bool {
    const secret_names = &[_][]const u8{
        ".env",
        ".env.local",
        "id_rsa",
        "id_ed25519",
        "credentials.json",
    };
    
    const basename = std.fs.path.basename(filename);
    
    for (secret_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    
    if (std.mem.endsWith(u8, basename, ".pem")) return true;
    if (std.mem.endsWith(u8, basename, ".key")) return true;
    
    return false;
}

test "secret_scanner detects API keys" {
    try std.testing.expectError(error.ContainsSecret, scan("Here is my key: AIzaSyB_12345_abc"));
    try std.testing.expectError(error.ContainsSecret, scan("sk-abcdefg123456"));
    try std.testing.expectError(error.ContainsSecret, scan("-----BEGIN PRIVATE KEY-----\nMIIC..."));
    
    try scan("This is safe text without secrets.");
}

test "secret_scanner detects secret files" {
    try std.testing.expect(isSecretFile("/path/to/.env"));
    try std.testing.expect(isSecretFile("credentials.json"));
    try std.testing.expect(isSecretFile("cert.pem"));
    try std.testing.expect(!isSecretFile("main.zig"));
    try std.testing.expect(!isSecretFile("config.json"));
}
