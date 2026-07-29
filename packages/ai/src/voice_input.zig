//! Voice Input — speech-to-text for agent prompt input.
//! Uses platform-specific speech recognition:
//! - macOS: NSSpeechRecognizer / SFSpeechRecognizer
//! - Linux: pocketsphinx / Google Speech (via subprocess)
//! - Windows: System.Speech.Recognition
//!
//! This module provides the interface; actual speech recognition
//! is done via platform backends that may not be available on all
//! systems. The feature gracefully degrades to "not available".
const std = @import("std");

pub const VoiceState = enum {
    idle, // Not listening
    listening, // Actively capturing audio
    processing, // Transcribing audio
    error_, // Error occurred
};

pub const VoiceResult = struct {
    text: []const u8,
    confidence: f32, // 0.0 - 1.0
    is_final: bool, // true when transcription is complete

    pub fn deinit(self: *VoiceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const VoiceInput = struct {
    allocator: std.mem.Allocator,
    state: VoiceState = .idle,
    partial_text: std.ArrayList(u8),
    error_msg: ?[]const u8 = null,
    /// Whether voice input is available on this platform.
    available: bool = false,

    pub fn init(allocator: std.mem.Allocator) VoiceInput {
        return .{
            .allocator = allocator,
            .partial_text = .empty,
            .available = detectAvailability(),
        };
    }

    pub fn deinit(self: *VoiceInput) void {
        self.partial_text.deinit(self.allocator);
        if (self.error_msg) |msg| self.allocator.free(msg);
    }

    /// Check if speech recognition is available on this platform.
    fn detectAvailability() bool {
        // On macOS, SFSpeechRecognizer is available on 10.15+.
        // On Linux, check for pocketsphinx or google speech binary.
        // On Windows, System.Speech is available on .NET Framework.
        // For now, we report availability based on platform.
        const builtin = @import("builtin");
        return switch (builtin.os.tag) {
            .macos => true, // SFSpeechRecognizer
            .linux => false, // pocketsphinx check deferred to runtime
            .windows => true, // System.Speech
            else => false,
        };
    }

    /// Start listening for voice input.
    /// In production, this would call the platform speech API.
    /// For now, it sets the state and returns.
    pub fn startListening(self: *VoiceInput) !void {
        if (!self.available) {
            self.setError("Voice input is not available on this platform");
            return error.NotAvailable;
        }
        self.state = .listening;
        self.partial_text.clearRetainingCapacity();
    }

    /// Stop listening and return the transcribed text.
    pub fn stopListening(self: *VoiceInput) !VoiceResult {
        if (self.state != .listening) return error.NotListening;
        self.state = .processing;

        // In production, this would finalize the transcription.
        // For now, return whatever partial text was accumulated.
        const text = try self.allocator.dupe(u8, self.partial_text.items);
        self.state = .idle;
        self.partial_text.clearRetainingCapacity();

        return .{
            .text = text,
            .confidence = 0.9,
            .is_final = true,
        };
    }

    /// Cancel listening without returning a result.
    pub fn cancel(self: *VoiceInput) void {
        self.state = .idle;
        self.partial_text.clearRetainingCapacity();
    }

    /// Feed partial transcription results (called by platform backend).
    pub fn feedPartial(self: *VoiceInput, text: []const u8) !void {
        if (self.state != .listening) return;
        self.partial_text.clearRetainingCapacity();
        try self.partial_text.appendSlice(self.allocator, text);
    }

    fn setError(self: *VoiceInput, msg: []const u8) void {
        if (self.error_msg) |old| self.allocator.free(old);
        self.error_msg = self.allocator.dupe(u8, msg) catch null;
        self.state = .error_;
    }

    /// Get the current state as a display string.
    pub fn stateLabel(self: VoiceInput) []const u8 {
        return switch (self.state) {
            .idle => "Idle",
            .listening => "Listening...",
            .processing => "Processing...",
            .error_ => "Error",
        };
    }

    /// Get the microphone icon state for UI.
    pub fn micIconActive(self: VoiceInput) bool {
        return self.state == .listening or self.state == .processing;
    }
};

test "VoiceInput init and state" {
    const allocator = std.testing.allocator;
    var voice = VoiceInput.init(allocator);
    defer voice.deinit();
    try std.testing.expectEqual(VoiceState.idle, voice.state);
    try std.testing.expectEqualStrings("Idle", voice.stateLabel());
}

test "VoiceInput feedPartial" {
    const allocator = std.testing.allocator;
    var voice = VoiceInput.init(allocator);
    defer voice.deinit();

    // Can't test actual listening without platform support,
    // but we can test the partial text accumulation.
    voice.state = .listening;
    try voice.feedPartial("hello world");
    try std.testing.expectEqualStrings("hello world", voice.partial_text.items);

    try voice.feedPartial("updated text");
    try std.testing.expectEqualStrings("updated text", voice.partial_text.items);
}

test "VoiceInput cancel" {
    const allocator = std.testing.allocator;
    var voice = VoiceInput.init(allocator);
    defer voice.deinit();

    voice.state = .listening;
    try voice.feedPartial("some text");
    voice.cancel();
    try std.testing.expectEqual(VoiceState.idle, voice.state);
    try std.testing.expectEqual(@as(usize, 0), voice.partial_text.items.len);
}
