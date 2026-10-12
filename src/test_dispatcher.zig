const std = @import("std");
const napi = @import("napi-sys").napi_sys;

pub const Dispatcher = struct {
    context: ?*anyopaque,
    finalize: napi.napi_finalize,
    dispose: napi.napi_threadsafe_function_call_js,
    status: napi.napi_status = napi.napi_ok,
    queued: bool = false,
    calls: usize = 0,
    releases: usize = 0,

    pub fn raw(self: *@This()) napi.napi_threadsafe_function {
        return @ptrCast(self);
    }
    pub fn finish(self: *@This()) void {
        self.finalize.?(env, self.context, null);
        if (self.queued) self.dispose.?(null, null, self.context, null);
    }
};

pub const env: napi.napi_env = @ptrFromInt(1);
pub var deleted_references: usize = 0;
pub var removed_hooks: usize = 0;

export fn napi_call_threadsafe_function(raw: napi.napi_threadsafe_function, _: ?*anyopaque, mode: napi.napi_threadsafe_function_call_mode) callconv(.c) napi.napi_status {
    std.debug.assert(mode == napi.napi_tsfn_nonblocking);
    const dispatcher: *Dispatcher = @ptrCast(@alignCast(raw.?));
    dispatcher.calls += 1;
    dispatcher.queued = dispatcher.status == napi.napi_ok;
    return dispatcher.status;
}

export fn napi_release_threadsafe_function(raw: napi.napi_threadsafe_function, _: napi.napi_threadsafe_function_release_mode) callconv(.c) napi.napi_status {
    const dispatcher: *Dispatcher = @ptrCast(@alignCast(raw.?));
    dispatcher.releases += 1;
    return napi.napi_ok;
}

export fn napi_remove_env_cleanup_hook(inner_env: napi.node_api_basic_env, _: napi.napi_cleanup_hook, _: ?*anyopaque) callconv(.c) napi.napi_status {
    std.debug.assert(inner_env != null);
    removed_hooks += 1;
    return napi.napi_ok;
}

export fn napi_delete_reference(inner_env: napi.node_api_basic_env, _: napi.napi_ref) callconv(.c) napi.napi_status {
    std.debug.assert(inner_env != null);
    deleted_references += 1;
    return napi.napi_ok;
}
