//! Forge Cloud module — backend integration for model catalog, LLM proxy,
//! and user authentication.

pub const config = @import("config.zig");
pub const models = @import("models.zig");

const std = @import("std");

pub const CloudConfig = config.CloudConfig;
pub const CloudModel = models.CloudModel;
pub const CloudModelList = models.CloudModelList;
pub const CloudError = models.CloudError;
pub const fetchModels = models.fetchModels;
pub const resolveConfig = config.resolve;
pub const isConfigured = config.isConfigured;

test {
    std.testing.refAllDecls(@This());
}
