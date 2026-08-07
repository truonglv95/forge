//! Forge Cloud module — backend integration for model catalog, LLM proxy,
//! and user authentication.

pub const config = @import("config.zig");
pub const models = @import("models.zig");
pub const prepare = @import("prepare.zig");

const std = @import("std");

pub const CloudConfig = config.CloudConfig;
pub const CloudModel = models.CloudModel;
pub const CloudModelList = models.CloudModelList;
pub const CloudError = models.CloudError;
pub const fetchModels = models.fetchModels;
pub const resolveConfig = config.resolve;
pub const isConfigured = config.isConfigured;

pub const PrepareRequest = prepare.PrepareRequest;
pub const PrepareResponse = prepare.PrepareResponse;
pub const PlanStep = prepare.PlanStep;
pub const PrepareError = prepare.PrepareError;
pub const callPrepare = prepare.prepare;

test {
    std.testing.refAllDecls(@This());
}
