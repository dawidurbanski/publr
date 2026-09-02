const sdk = @import("../sdk.zig");
const contract = @import("../sdk/plugin.zig");
const status_registry = @import("../model/status.zig");
const heartbeat = @import("../operations/heartbeat.zig");
const site = @import("../operations/site.zig");
const user = @import("../operations/user.zig");
const sign_in = @import("../operations/sign_in.zig");
const status = @import("../operations/status.zig");
const content_type = @import("../operations/content_type.zig");
const record = @import("../operations/record.zig");
const snapshot = @import("../operations/snapshot.zig");
const plugin_types = @import("../sdk/plugin/types.zig");

pub const plugins = contract.Merged(@import("plugins").all);

const core_operations = heartbeat.operations ++ site.operations ++ user.operations ++
    sign_in.operations ++ status.operations ++ content_type.operations ++
    record.operations ++ snapshot.operations;
const core_namespaces = [_]sdk.operation.Namespace{
    heartbeat.namespace,
    site.namespace,
    user.namespace,
    status.namespace,
    content_type.namespace,
    record.namespace,
    snapshot.namespace,
};

pub const registry: sdk.Registry = .{
    .operations = &core_operations ++ plugins.merged_operations,
    .namespaces = &core_namespaces ++ plugins.merged_namespaces,
    .policies = plugins.merged_policies,
    .middleware = plugins.merged_middleware,
    .schemas = plugins.merged_schemas,
    .bootstrap = &plugin_types.apply_all,
};

pub const SDK = sdk.SDK(registry);

pub const Statuses = status_registry.Registry(
    &status_registry.core_statuses ++ plugins.merged_statuses,
    &status_registry.core_transitions ++ plugins.merged_transitions,
);
