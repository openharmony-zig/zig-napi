const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const napi_env = @import("../env.zig");
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const NapiError = @import("./error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const PayloadRegistry = @import("../util/payload_registry.zig").PayloadRegistry;
const Buffer = @import("./buffer.zig").Buffer;
const ArrayBuffer = @import("./arraybuffer.zig").ArrayBuffer;
const options = @import("../options.zig");

pub fn ClassWrapper(comptime T: type, comptime HasInit: bool) type {
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("Class() only support struct type");
    }

    if (type_info.@"struct".is_tuple) {
        @compileError("Class() does not support tuple type");
    }

    const fields = type_info.@"struct".fields;
    const decls = type_info.@"struct".decls;

    const class_name = comptime helper.shortTypeName(T);
    const has_custom_deinit = @hasDecl(T, "deinit");

    return struct {
        pub const WrappedType = T;
        pub const HasConstructorInit = HasInit;
        env: napi.napi_env,
        raw: napi.napi_value,
        const Self = @This();

        // Provenance registries. `napi_unwrap` data and callback data are only
        // interpreted after the pointer has been proven to belong to this exact
        // generic instantiation. A magic value stored inside the payload is not
        // such a proof: another addon may have wrapped a one-byte allocation or
        // an opaque sentinel such as pointer 1, and reading it would already be
        // the bug. `PayloadRegistry` only stores addresses, never dereferences
        // them, and is instantiated per type, so an entry can only come from
        // this class.
        const InstanceRegistry = PayloadRegistry(InstanceData);
        const ContextRegistry = PayloadRegistry(ClassContext);

        /// Type-erased owner for the converted inputs of one instance.
        ///
        /// The wrapper owns **every** converted input, without exception: it
        /// does not guess ownership from buffer addresses, and it never inspects
        /// the instance value after user `deinit` has run.
        const KeepAlive = struct {
            ptr: *anyopaque,
            destroyFn: *const fn (*anyopaque, std.mem.Allocator) void,

            fn destroy(self: KeepAlive, allocator: std.mem.Allocator) void {
                self.destroyFn(self.ptr, allocator);
            }
        };

        const InstanceData = struct {
            allocator: std.mem.Allocator,
            value: T,
            /// `owned_fields[i]` records that the *current* value of field `i`
            /// was produced by a conversion performed by this wrapper. Only
            /// those values may be released when a setter replaces them.
            owned_fields: [fields.len]bool,
            /// Converted `init`/factory inputs. See `retainBorrowedInputs`.
            borrowed_inputs: ?KeepAlive,

            fn create(allocator: std.mem.Allocator) !*InstanceData {
                const instance = try allocator.create(InstanceData);
                errdefer allocator.destroy(instance);
                instance.* = .{
                    .allocator = allocator,
                    // Never expose or finalize this value before construction.
                    // Failed field construction only releases its initialized prefix.
                    .value = undefined,
                    .owned_fields = [_]bool{false} ** fields.len,
                    .borrowed_inputs = null,
                };
                // Registration is what makes `unwrapInstance` a provenance
                // check instead of a memory read of an untrusted pointer.
                try InstanceRegistry.add(instance);
                return instance;
            }

            fn destroyUninitialized(self: *InstanceData) void {
                InstanceRegistry.remove(self);
                self.allocator.destroy(self);
            }

            fn destroy(self: *InstanceData) void {
                const allocator = self.allocator;

                if (comptime has_custom_deinit) {
                    // The type declares ownership of its own fields. Nothing
                    // may be read from `value` after this call: `deinit` is
                    // allowed to clear or release everything it owns.
                    deinitValue(T, self.value, allocator);
                } else {
                    inline for (fields, 0..) |field, i| {
                        if (self.owned_fields[i] or comptime fieldOwnsItself(field.type)) {
                            deinitValue(field.type, @field(self.value, field.name), allocator);
                        }
                    }
                }

                // The converted inputs are released last so that a `deinit`
                // which still reads a borrowed field sees live memory. They are
                // owned by the wrapper, never by the type.
                if (self.borrowed_inputs) |keep_alive| {
                    keep_alive.destroy(allocator);
                }

                InstanceRegistry.remove(self);
                allocator.destroy(self);
            }
        };

        /// Per environment class definition state.
        ///
        /// The constructor reference, the pending factory slot and the
        /// definition itself are only ever valid inside one environment. A
        /// single global reference (as used before) lets a Worker overwrite the
        /// constructor used by the main thread and vice versa.
        ///
        /// One context is created per `define_class` call and handed to every
        /// callback of that definition through callback data, so a callback can
        /// only ever observe a context that belongs to the environment that
        /// invoked it.
        ///
        /// Exactly one mechanism releases it, chosen at compile time so that no
        /// context is ever released twice:
        ///
        /// * `napi_add_env_cleanup_hook` (N-API v3 and newer) releases it
        ///   before the environment is torn down, which is the deterministic
        ///   path. A failed registration is reported instead of being ignored.
        /// * on older N-API versions a finalizer attached with `napi_wrap` to
        ///   the class constructor releases it when the class object is
        ///   collected - at the latest during environment teardown - so those
        ///   environments do not silently retain the context forever. The
        ///   constructor reference is weak (refcount 0) so that the class object
        ///   can actually be collected.
        const ClassContext = struct {
            env: napi.napi_env,
            allocator: std.mem.Allocator,
            constructor_ref: ?napi.napi_ref = null,
            /// Set by a factory callback while it drives the internal
            /// construction channel; consumed by `constructor_callback`.
            pending_factory: ?*InstanceData = null,
        };

        fn createContext(env: napi.napi_env) !*ClassContext {
            const allocator = GlobalAllocator.globalAllocator();
            const context = try allocator.create(ClassContext);
            errdefer allocator.destroy(context);
            context.* = .{
                .env = env,
                .allocator = allocator,
            };
            try ContextRegistry.add(context);

            // A failure to register the deterministic release path has to be
            // reported: silently continuing would leak the context until the
            // constructor is collected.
            if (comptime options.selectedNapiVersion().isAtLeast(.v3)) {
                const status = napi.napi_add_env_cleanup_hook(env, contextCleanupHook, context);
                if (status != napi.napi_ok) {
                    ContextRegistry.remove(context);
                    return NapiError.failStatus(status);
                }
            }

            return context;
        }

        fn contextCleanupHook(data: ?*anyopaque) callconv(.c) void {
            const raw = data orelse return;
            releaseContextRaw(raw);
        }

        /// Finalizer for the class constructor object; see `ClassContext`.
        fn contextFinalizer(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const raw = data orelse return;
            releaseContextRaw(raw);
        }

        fn releaseContextRaw(raw: *anyopaque) void {
            // Provenance first: neither callback owns the pointer it receives.
            if (!ContextRegistry.contains(raw)) return;
            const context: *ClassContext = @ptrCast(@alignCast(raw));
            releaseContext(context);
        }

        fn releaseContext(context: *ClassContext) void {
            ContextRegistry.remove(context);

            if (context.constructor_ref) |reference| {
                _ = napi.napi_delete_reference(context.env, reference);
                context.constructor_ref = null;
            }

            const allocator = context.allocator;
            allocator.destroy(context);
        }

        // ------------------------------------------------------------------
        // Error and conversion helpers
        // ------------------------------------------------------------------

        fn hasPendingException(env: napi.napi_env) bool {
            var pending = false;
            if (napi.napi_is_exception_pending(env, &pending) != napi.napi_ok) return false;
            return pending;
        }

        /// Throws a JavaScript exception for a failed class operation.
        ///
        /// An exception that is already pending (a throwing getter, a Proxy
        /// trap, a callback that threw) is left untouched: N-API aborts when a
        /// second exception is thrown while one is pending, and the original
        /// exception object is the one JavaScript has to observe.
        fn throwError(env: napi.napi_env, err: NapiError.Error) void {
            if (hasPendingException(env)) return;
            err.throwInto(napi_env.Env.from_raw(env));
        }

        fn throwTypeError(env: napi.napi_env, message: []const u8) void {
            throwError(env, NapiError.Error.withTypeError(message));
        }

        /// Converts an error coming out of a conversion into a JavaScript
        /// exception. A pending exception produced by user code (a throwing
        /// getter, a Proxy trap, a revoked proxy) is left untouched so that the
        /// original exception object reaches JavaScript unchanged.
        fn reportConversionFailure(env: napi.napi_env, err: anyerror) void {
            if (err == error.PendingException) return;
            throwError(env, NapiError.mapAnyError(err));
        }

        fn throwAnyAndNull(env: napi.napi_env, err: anyerror) napi.napi_value {
            reportConversionFailure(env, err);
            return null;
        }

        /// Releases a converted value with the allocator that produced it.
        fn deinitValue(comptime V: type, value: V, allocator: std.mem.Allocator) void {
            Napi.deinit_napi_value_with_allocator(V, value, allocator);
        }

        /// Whether a field type can hold native memory that somebody has to
        /// release. This is a property of the *type*, decided at compile time;
        /// no runtime pointer or address range is ever inspected to decide
        /// ownership.
        fn typeCarriesNativeMemory(comptime F: type) bool {
            return switch (@typeInfo(F)) {
                .pointer => true,
                .optional => |optional| typeCarriesNativeMemory(optional.child),
                .array => |array| typeCarriesNativeMemory(array.child),
                .@"struct" => |structure| blk: {
                    // JavaScript handles (Buffer, TypedArray, Function, ...)
                    // reference memory the runtime owns, never native memory of
                    // this instance.
                    if (comptime fieldOwnsItself(F)) break :blk true;
                    if (comptime helper.isNapiFunction(F) or
                        helper.isTypedArray(F) or
                        helper.isDataView(F) or
                        helper.isReference(F) or
                        helper.isExternal(F) or
                        helper.isAbortSignal(F) or
                        F == Buffer or
                        F == ArrayBuffer)
                    {
                        break :blk false;
                    }
                    inline for (structure.fields) |field| {
                        if (comptime typeCarriesNativeMemory(field.type)) break :blk true;
                    }
                    break :blk false;
                },
                .@"union" => |union_info| {
                    inline for (union_info.fields) |field| {
                        if (comptime typeCarriesNativeMemory(field.type)) return true;
                    }
                    return false;
                },
                else => false,
            };
        }

        /// Whether replacing the current value of a field requires an explicit
        /// owner. A type that declares `deinit` claims its fields, so an
        /// implicit JavaScript assignment cannot release the previous value
        /// safely and is rejected instead of leaking it. Plain data and naive
        /// value fields (numbers, flags, structs of them) are always assignable.
        fn replacementNeedsOwner(comptime type_has_deinit: bool, comptime F: type) bool {
            if (!type_has_deinit) return false;
            return typeCarriesNativeMemory(F);
        }

        /// A field type that owns itself (for example `napi.Owned`, a native
        /// list or any struct exposing `deinit`) is always released with the
        /// instance, whether the value was produced by a conversion or handed
        /// over by user code.
        fn fieldOwnsItself(comptime F: type) bool {
            switch (@typeInfo(F)) {
                .@"struct", .@"union", .@"enum" => {},
                else => return false,
            }
            if (comptime helper.isNapiFunction(F) or
                helper.isTypedArray(F) or
                helper.isDataView(F) or
                helper.isReference(F) or
                helper.isExternal(F) or
                helper.isAbortSignal(F))
            {
                return false;
            }
            return @hasDecl(F, "deinit");
        }

        /// Releases the record of converted inputs held by an instance.
        ///
        /// Every input is released here, unconditionally. Ownership is not
        /// inferred from addresses and not delegated to user `deinit`: the
        /// inputs are memory the conversion allocated, so they are memory the
        /// wrapper releases, exactly once.
        fn destroyKeepAlive(comptime V: type) *const fn (*anyopaque, std.mem.Allocator) void {
            return struct {
                fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
                    const typed: *V = @ptrCast(@alignCast(raw));
                    inline for (@typeInfo(V).@"struct".fields) |field| {
                        deinitValue(field.type, @field(typed.*, field.name), allocator);
                    }
                    allocator.destroy(typed);
                }
            }.destroy;
        }

        /// Inputs converted for a user supplied `init` or factory are borrowed
        /// by user code for the lifetime of the instance:
        ///
        /// * storing one of them in a field is supported and safe - the wrapper
        ///   keeps the converted inputs alive until the instance is finalized
        ///   and releases them exactly once after `deinit` has run;
        /// * freeing one of them, in `deinit` or anywhere else, is a double
        ///   free: they are not `self`'s memory;
        /// * a type that has to *own* a resource must clone it explicitly
        ///   (`Napi.clone_napi_value`, `allocator.dupe`, ...) or store it in an
        ///   explicitly owned field (`napi.Owned(T)`), whose `deinit` the
        ///   wrapper calls.
        fn retainBorrowedInputs(comptime V: type, instance: *InstanceData, value: V) !void {
            const allocator = instance.allocator;
            const stored = try allocator.create(V);
            stored.* = value;
            instance.borrowed_inputs = .{
                .ptr = @ptrCast(stored),
                .destroyFn = destroyKeepAlive(V),
            };
        }

        /// Releases the converted inputs `0..initialized`. Called on every
        /// failure path so that a rejected argument list does not leak the
        /// arguments that were converted before the failure.
        fn releaseConvertedArgs(comptime ArgsTuple: type, args: *ArgsTuple, initialized: usize, allocator: std.mem.Allocator) void {
            inline for (0..@typeInfo(ArgsTuple).@"struct".fields.len) |i| {
                if (i < initialized) {
                    deinitValue(@TypeOf(args[i]), args[i], allocator);
                }
            }
        }

        fn constructorArgCount() usize {
            if (HasInit and @hasDecl(T, "init")) {
                return @typeInfo(@TypeOf(T.init)).@"fn".params.len;
            }
            return if (HasInit) fields.len else 0;
        }

        // ------------------------------------------------------------------
        // Callback plumbing
        // ------------------------------------------------------------------

        const CallInfo = struct {
            argc: usize,
            this_obj: napi.napi_value,
            context: ?*ClassContext,
        };

        /// Reads the callback arguments and the per environment class context.
        ///
        /// Every callback defined here receives its `ClassContext` through
        /// callback data, which is what makes the constructor reference
        /// environment scoped. The context is validated before use so that a
        /// callback invoked with a foreign data pointer cannot be reinterpreted.
        fn readCallInfo(
            comptime Argc: usize,
            env: napi.napi_env,
            callback_info: napi.napi_callback_info,
            args_raw: *[Argc]napi.napi_value,
        ) ?CallInfo {
            var argc: usize = Argc;
            var this_obj: napi.napi_value = undefined;
            var data: ?*anyopaque = null;
            const argv = if (Argc == 0) null else args_raw[0..].ptr;
            const status = napi.napi_get_cb_info(env, callback_info, &argc, argv, &this_obj, &data);
            if (status != napi.napi_ok) return null;

            if (Argc > argc) {
                var undefined_raw: napi.napi_value = undefined;
                const undefined_status = napi.napi_get_undefined(env, &undefined_raw);
                if (undefined_status != napi.napi_ok) return null;
                for (argc..Argc) |i| {
                    args_raw[i] = undefined_raw;
                }
            }

            // Callback data comes from this addon's own property descriptors,
            // but the pointer is validated before it is dereferenced: a
            // callback invoked through foreign data must not read or write
            // through it.
            const context: ?*ClassContext = if (data) |raw| blk: {
                if (!ContextRegistry.contains(raw)) break :blk null;
                const candidate: *ClassContext = @ptrCast(@alignCast(raw));
                if (candidate.env != env) break :blk null;
                break :blk candidate;
            } else null;

            return .{
                .argc = argc,
                .this_obj = this_obj,
                .context = context,
            };
        }

        /// Resolves the native instance wrapped into `this_obj`.
        ///
        /// The pointer that `napi_unwrap` reports is a value of another party
        /// until it has been proven to belong to this class: it may be a
        /// sentinel such as `@ptrFromInt(1)`, a one-byte allocation or the
        /// payload of a completely different addon. It is therefore never cast
        /// or dereferenced before `InstanceRegistry` confirms it, and an
        /// unregistered pointer is reported as a receiver mismatch.
        fn unwrapInstance(env: napi.napi_env, this_obj: napi.napi_value) ?*InstanceData {
            var data: ?*anyopaque = null;
            const status = napi.napi_unwrap(env, this_obj, &data);
            if (status != napi.napi_ok) return null;
            const raw = data orelse return null;
            if (!InstanceRegistry.contains(raw)) return null;
            return @ptrCast(@alignCast(raw));
        }

        /// Returns the instance or throws a TypeError when `this` is not an
        /// instance of this class (an unwrapped object, a value of another
        /// class or an already detached receiver).
        fn expectInstance(env: napi.napi_env, this_obj: napi.napi_value, comptime what: []const u8) ?*InstanceData {
            if (unwrapInstance(env, this_obj)) |instance| return instance;
            throwTypeError(env, what ++ " called on an incompatible receiver");
            return null;
        }

        fn returnPayloadType(comptime ReturnType: type) type {
            const payload = switch (@typeInfo(ReturnType)) {
                .error_union => |eu| eu.payload,
                else => ReturnType,
            };
            return if (comptime NapiError.isResult(payload)) NapiError.resultPayload(payload) else payload;
        }

        fn toNapiReturn(env: napi.napi_env, value: anytype, comptime name: []const u8) napi.napi_value {
            defer Napi.disposeOwnedParts(@TypeOf(value), value, GlobalAllocator.capture());
            return Napi.to_napi_value_auto(env, value, name) catch |err| {
                return throwAnyAndNull(env, err);
            };
        }

        /// An init/factory result borrows its converted inputs. On rollback,
        /// release only user-owned fields; the argument owner releases borrows.
        fn cleanupUnwrappedValue(value: T, allocator: std.mem.Allocator) void {
            if (comptime has_custom_deinit) {
                deinitValue(T, value, allocator);
            } else {
                inline for (fields) |field| {
                    if (comptime fieldOwnsItself(field.type)) {
                        deinitValue(field.type, @field(value, field.name), allocator);
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // Factory payload handling
        // ------------------------------------------------------------------

        fn factoryValueFromPayload(payload: anytype) ?T {
            const Payload = @TypeOf(payload);
            if (Payload == T) return payload;
            // A factory returning `*T` moves the pointee into the instance.
            // The allocation holding it stays owned by the factory.
            if (Payload == *T) return payload.*;
            if (Payload == *const T) return payload.*;
            @compileError("Factory method must return " ++ @typeName(T) ++ ", *" ++ @typeName(T) ++ " or *const " ++ @typeName(T) ++ ", got: " ++ @typeName(Payload));
        }

        fn factoryValueFromResult(env: napi.napi_env, result: anytype) ?T {
            if (comptime NapiError.isResult(@TypeOf(result))) {
                return switch (result) {
                    .ok => |payload| factoryValueFromPayload(payload),
                    .err => |err| {
                        throwError(env, err);
                        return null;
                    },
                };
            }
            return factoryValueFromPayload(result);
        }

        // ------------------------------------------------------------------
        // Construction
        // ------------------------------------------------------------------

        /// Builds a native instance for a plain `new Class(...)` call:
        /// either through `T.init` or by converting the constructor arguments
        /// into the struct fields. Returns null after throwing on failure and
        /// leaves no partially initialized allocation behind.
        fn constructFromArguments(env: napi.napi_env, args: []const napi.napi_value) ?*InstanceData {
            const allocator = GlobalAllocator.globalAllocator();
            const instance = InstanceData.create(allocator) catch {
                throwError(env, NapiError.Error.withStatus(NapiError.Status.GenericFailure));
                return null;
            };

            if (comptime HasInit and @hasDecl(T, "init")) {
                if (!buildWithInit(env, args, instance)) {
                    instance.destroyUninitialized();
                    return null;
                }
            } else {
                if (!buildFromFields(env, args, instance)) {
                    instance.destroyUninitialized();
                    return null;
                }
            }

            return instance;
        }

        fn buildWithInit(env: napi.napi_env, args: []const napi.napi_value, instance: *InstanceData) bool {
            const init_fn = T.init;
            const init_type = @TypeOf(init_fn);
            const init_params = @typeInfo(init_type).@"fn".params;
            const allocator = instance.allocator;
            const ArgsTuple = std.meta.ArgsTuple(init_type);

            var tuple_args: ArgsTuple = undefined;
            var initialized: usize = 0;

            inline for (init_params, 0..) |param, i| {
                tuple_args[i] = Napi.from_napi_value_auto_with_allocator(env, args[i], param.type.?, allocator) catch |err| {
                    releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                    reportConversionFailure(env, err);
                    return false;
                };
                initialized = i + 1;
            }

            const init_result = if (@typeInfo(@typeInfo(init_type).@"fn".return_type.?) == .error_union)
                @call(.auto, init_fn, tuple_args) catch |err| {
                    releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                    _ = throwAnyAndNull(env, err);
                    return false;
                }
            else
                @call(.auto, init_fn, tuple_args);

            const value = factoryValueFromResult(env, init_result) orelse {
                releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                return false;
            };

            if (initialized > 0) {
                retainBorrowedInputs(ArgsTuple, instance, tuple_args) catch {
                    cleanupUnwrappedValue(value, allocator);
                    releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                    throwError(env, NapiError.Error.withStatus(NapiError.Status.GenericFailure));
                    return false;
                };
            }

            instance.value = value;
            return true;
        }

        fn buildFromFields(env: napi.napi_env, args: []const napi.napi_value, instance: *InstanceData) bool {
            // Field construction transfers ownership of the converted values
            // to the fields; a failure rolls the successfully converted fields
            // back before the shell is destroyed.
            instance.value = undefined;
            inline for (fields, 0..) |field, i| {
                const converted = Napi.from_napi_value_auto_with_allocator(env, args[i], field.type, instance.allocator) catch |err| {
                    rollbackFields(instance, i);
                    reportConversionFailure(env, err);
                    return false;
                };
                @field(instance.value, field.name) = converted;
                instance.owned_fields[i] = true;
            }
            return true;
        }

        fn rollbackFields(instance: *InstanceData, initialized: usize) void {
            inline for (fields, 0..) |field, i| {
                if (i < initialized and instance.owned_fields[i]) {
                    deinitValue(field.type, @field(instance.value, field.name), instance.allocator);
                    instance.owned_fields[i] = false;
                }
            }
        }

        /// Internal construction channel used by factory methods.
        ///
        /// `napi_new_instance` is still the only N-API way to obtain an object
        /// with the class prototype, so the factory parks the already built
        /// native instance in the context and lets `constructor_callback` adopt
        /// it. User `init` code is not executed again and the fields are not
        /// round-tripped through JavaScript.
        fn constructFromNativeValue(env: napi.napi_env, context: *ClassContext, instance: *InstanceData) napi.napi_value {
            const reference = context.constructor_ref orelse {
                instance.destroy();
                throwTypeError(env, "class constructor is not registered in this environment");
                return null;
            };

            var constructor: napi.napi_value = undefined;
            const ref_status = napi.napi_get_reference_value(env, reference, &constructor);
            if (ref_status != napi.napi_ok) {
                instance.destroy();
                throwError(env, NapiError.Error.withStatus(NapiError.Status.New(ref_status)));
                return null;
            }

            context.pending_factory = instance;
            // The constructor callback consumes the pending instance and marks
            // the slot empty. Whatever is still parked here when this function
            // returns was never adopted (the internal construction channel did
            // not run) and has to be released exactly once.
            defer {
                if (context.pending_factory) |pending| {
                    context.pending_factory = null;
                    pending.destroy();
                }
            }

            var js_instance: napi.napi_value = undefined;
            const status = napi.napi_new_instance(env, constructor, 0, null, &js_instance);
            if (status != napi.napi_ok) {
                throwError(env, NapiError.Error.withStatus(NapiError.Status.New(status)));
                return null;
            }
            return js_instance;
        }

        fn constructor_callback(env: napi.napi_env, callback_info: napi.napi_callback_info) callconv(.c) napi.napi_value {
            var new_target: napi.napi_value = null;
            const target_status = napi.napi_get_new_target(env, callback_info, &new_target);
            if (target_status != napi.napi_ok) return throwAnyAndNull(env, NapiError.failStatus(target_status));
            if (new_target == null) {
                throwTypeError(env, class_name ++ " constructor must be called with 'new'");
                return null;
            }
            const constructor_arg_count = comptime constructorArgCount();
            var args_raw: [constructor_arg_count]napi.napi_value = undefined;
            const call = readCallInfo(constructor_arg_count, env, callback_info, &args_raw) orelse return null;
            const context = call.context orelse {
                throwTypeError(env, "class constructor called without its definition context");
                return null;
            };

            // Factory channel: adopt the instance that was already built by the
            // factory method instead of running `init` or field conversion.
            if (context.pending_factory) |instance| {
                context.pending_factory = null;
                if (napi.napi_wrap(env, call.this_obj, instance, finalize_callback, null, null) != napi.napi_ok) {
                    instance.destroy();
                    throwTypeError(env, class_name ++ " instance could not be wrapped");
                    return null;
                }
                return call.this_obj;
            }

            if (comptime !HasInit) {
                throwTypeError(env, class_name ++ " cannot be constructed from JavaScript; use one of its factory functions");
                return null;
            }

            if (!isConstructibleThis(env, call.this_obj)) {
                throwTypeError(env, class_name ++ " constructor must be called with 'new'");
                return null;
            }

            const instance = constructFromArguments(env, args_raw[0..]) orelse return null;

            if (napi.napi_wrap(env, call.this_obj, instance, finalize_callback, null, null) != napi.napi_ok) {
                instance.destroy();
                throwTypeError(env, class_name ++ " instance could not be wrapped");
                return null;
            }

            return call.this_obj;
        }

        /// `new Class()` produces a fresh object; a plain `Class()` call hands
        /// over the global object (sloppy mode) or `undefined` (strict mode).
        /// Both cases are rejected before anything is wrapped.
        fn isConstructibleThis(env: napi.napi_env, this_obj: napi.napi_value) bool {
            var this_type: napi.napi_valuetype = undefined;
            if (napi.napi_typeof(env, this_obj, &this_type) != napi.napi_ok) return false;
            if (this_type != napi.napi_object) return false;

            var global: napi.napi_value = undefined;
            if (napi.napi_get_global(env, &global) == napi.napi_ok) {
                var is_global = false;
                if (napi.napi_strict_equals(env, this_obj, global, &is_global) == napi.napi_ok and is_global) {
                    return false;
                }
            }
            return true;
        }

        fn finalize_callback(env: napi.napi_env, data: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
            _ = env;
            _ = hint;

            const raw = data orelse return;
            // Provenance before the cast, like every other unwrap path: the
            // finalizer must be harmless if it is ever invoked with data that
            // this class did not register.
            if (!InstanceRegistry.contains(raw)) return;
            const instance: *InstanceData = @ptrCast(@alignCast(raw));
            instance.destroy();
        }

        // ------------------------------------------------------------------
        // Factory method callbacks
        // ------------------------------------------------------------------

        fn factory_method_callback(comptime factory_name: []const u8) type {
            return struct {
                fn call(env: napi.napi_env, callback_info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                    const factory_fn = @field(T, factory_name);
                    const factory_fn_type = @TypeOf(factory_fn);
                    const factory_fn_info = @typeInfo(factory_fn_type);
                    const params = factory_fn_info.@"fn".params;

                    var args_raw: [params.len]napi.napi_value = undefined;
                    const callback = readCallInfo(params.len, env, callback_info, &args_raw) orelse return null;
                    const context = callback.context orelse {
                        throwTypeError(env, "factory called without its class definition context");
                        return null;
                    };

                    const allocator = GlobalAllocator.globalAllocator();
                    var value: T = undefined;
                    var keep_alive: ?KeepAlive = null;

                    if (params.len == 0) {
                        const result = if (@typeInfo(factory_fn_info.@"fn".return_type.?) == .error_union)
                            factory_fn() catch |err| return throwAnyAndNull(env, err)
                        else
                            factory_fn();
                        value = factoryValueFromResult(env, result) orelse return null;
                    } else {
                        if (@typeInfo(factory_fn_info.@"fn".return_type.?) == .void) {
                            @compileError("Factory method " ++ @typeName(T) ++ "." ++ factory_name ++ " must return the class type");
                        }

                        const ArgsTuple = std.meta.ArgsTuple(factory_fn_type);
                        var tuple_args: ArgsTuple = undefined;
                        var initialized: usize = 0;

                        inline for (params, 0..) |param, i| {
                            tuple_args[i] = Napi.from_napi_value_auto_with_allocator(env, args_raw[i], param.type.?, allocator) catch |err| {
                                releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                                reportConversionFailure(env, err);
                                return null;
                            };
                            initialized = i + 1;
                        }

                        const result = if (@typeInfo(factory_fn_info.@"fn".return_type.?) == .error_union)
                            @call(.auto, factory_fn, tuple_args) catch |err| {
                                releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                                return throwAnyAndNull(env, err);
                            }
                        else
                            @call(.auto, factory_fn, tuple_args);

                        value = factoryValueFromResult(env, result) orelse {
                            releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                            return null;
                        };

                        keep_alive = makeKeepAlive(ArgsTuple, tuple_args, allocator) catch {
                            cleanupUnwrappedValue(value, allocator);
                            releaseConvertedArgs(ArgsTuple, &tuple_args, initialized, allocator);
                            throwError(env, NapiError.Error.withStatus(NapiError.Status.GenericFailure));
                            return null;
                        };
                    }

                    const instance = InstanceData.create(allocator) catch {
                        cleanupUnwrappedValue(value, allocator);
                        if (keep_alive) |keep| keep.destroy(allocator);
                        throwError(env, NapiError.Error.withStatus(NapiError.Status.GenericFailure));
                        return null;
                    };
                    instance.value = value;
                    instance.borrowed_inputs = keep_alive;
                    keep_alive = null;

                    return constructFromNativeValue(env, context, instance);
                }
            };
        }

        /// Same contract as `retainBorrowedInputs` but for the factory path,
        /// where the instance shell does not exist yet.
        fn makeKeepAlive(comptime V: type, value: V, allocator: std.mem.Allocator) !KeepAlive {
            const stored = try allocator.create(V);
            stored.* = value;
            return .{
                .ptr = @ptrCast(stored),
                .destroyFn = destroyKeepAlive(V),
            };
        }

        // ------------------------------------------------------------------
        // Class definition
        // ------------------------------------------------------------------

        // Helper function to check if a declaration is a const field
        fn isConstDecl(comptime decl_name: []const u8) bool {
            if (!@hasDecl(T, decl_name)) return false;
            const decl_type = @TypeOf(@field(T, decl_name));
            const decl_type_info = @typeInfo(decl_type);
            // Check if it's not a function and not a type
            return decl_type_info != .@"fn" and decl_type_info != .type;
        }

        // Count const declarations at compile time
        fn countConstDecls() usize {
            var count: usize = 0;
            for (decls) |decl| {
                if (comptime isConstDecl(decl.name)) {
                    count += 1;
                }
            }
            return count;
        }

        /// Instance methods are the ones whose first parameter is the class
        /// type: `self: *T` (mutable receiver) or `self: T` (value receiver, a
        /// copy of the native state). Everything else is a static method, and a
        /// static method never touches `this`.
        fn isInstanceMethod(comptime params: []const std.builtin.Type.Fn.Param) bool {
            if (params.len == 0) return false;
            const self_type = params[0].type orelse return false;
            if (self_type == T) return true;
            const self_info = @typeInfo(self_type);
            if (self_info != .pointer) return false;
            if (self_info.pointer.size != .one) return false;
            if (self_info.pointer.child != T) return false;
            if (self_info.pointer.is_const) {
                // The declaration generator classifies `*const T` as a static
                // method, so accepting it here would produce a runtime that
                // disagrees with the generated `.d.ts`.
                @compileError("Class methods must use `self: *" ++ @typeName(T) ++ "` or `self: " ++ @typeName(T) ++ "`");
            }
            return true;
        }

        fn define_class(env: napi.napi_env) !napi.napi_value {
            const context = try createContext(env);

            // Count instance properties and methods
            comptime var property_count: usize = fields.len;

            // Count methods
            inline for (decls) |decl| {
                const decl_type = @TypeOf(@field(T, decl.name));
                if (@typeInfo(decl_type) == .@"fn") {
                    const fn_name = decl.name;
                    if (comptime !std.mem.eql(u8, fn_name, "init") and
                        !std.mem.eql(u8, fn_name, "deinit"))
                    {
                        property_count += 1;
                    }
                }
            }

            // Add const declarations count
            const const_count = comptime countConstDecls();
            const total_property_count = comptime property_count + const_count;

            var properties: [total_property_count]napi.napi_property_descriptor = undefined;
            var prop_idx: usize = 0;

            // Process instance fields
            inline for (fields, 0..) |field, field_index| {
                const FieldAccessor = struct {
                    fn getter(getter_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                        var args_raw: [0]napi.napi_value = undefined;
                        const callback = readCallInfo(0, getter_env, info, &args_raw) orelse return null;

                        const instance = expectInstance(getter_env, callback.this_obj, class_name ++ "." ++ field.name) orelse return null;
                        const field_value = @field(instance.value, field.name);
                        return Napi.to_napi_value_auto(getter_env, field_value, field.name) catch |err| {
                            return throwAnyAndNull(getter_env, err);
                        };
                    }

                    fn setter(setter_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                        var args_raw: [1]napi.napi_value = undefined;
                        const callback = readCallInfo(1, setter_env, info, &args_raw) orelse return null;

                        const instance = expectInstance(setter_env, callback.this_obj, class_name ++ "." ++ field.name) orelse return null;
                        if (callback.argc == 0) return null;

                        // The new value is converted first. A failed conversion
                        // leaves the previous field value untouched, and the
                        // previous value is only released when this wrapper is
                        // provably its owner. Ownership is never inferred from
                        // the pointer value.
                        //
                        // The current value is only read on the branch where
                        // the wrapper installed it (and therefore initialized
                        // it); on every other branch the field is overwritten
                        // without touching the old contents, so a field a user
                        // `init` never initialized cannot be read here.
                        if (comptime replacementNeedsOwner(has_custom_deinit, field.type)) {
                            // A self owning field type is an explicit owner
                            // contract and may replace itself; anything else
                            // that the type's `deinit` owns cannot.
                            if (comptime !fieldOwnsItself(field.type)) {
                                if (!instance.owned_fields[field_index]) {
                                    // The type owns this field through
                                    // `deinit` and the wrapper cannot know who
                                    // released the previous value: releasing it
                                    // here could free a static literal, and
                                    // keeping it silently would orphan native
                                    // memory.
                                    throwTypeError(
                                        setter_env,
                                        class_name ++ "." ++ field.name ++ " is owned by " ++ @typeName(T) ++ ".deinit: replace it through a method of the type or declare the field as napi.Owned(...)",
                                    );
                                    return null;
                                }
                            }
                        }

                        const new_value = Napi.from_napi_value_auto_with_allocator(setter_env, args_raw[0], field.type, instance.allocator) catch |err| {
                            reportConversionFailure(setter_env, err);
                            return null;
                        };

                        if (instance.owned_fields[field_index] or comptime fieldOwnsItself(field.type)) {
                            // The wrapper installed the current value, or the
                            // field type is explicitly self owning: both are an
                            // owner contract that lets the replaced value be
                            // released.
                            const previous = @field(instance.value, field.name);
                            @field(instance.value, field.name) = new_value;
                            deinitValue(field.type, previous, instance.allocator);
                        } else {
                            // Borrowed or plain data: nothing to release. The
                            // wrapper now owns the value it just installed.
                            @field(instance.value, field.name) = new_value;
                        }
                        instance.owned_fields[field_index] = true;
                        return null;
                    }
                };

                properties[prop_idx] = napi.napi_property_descriptor{
                    .utf8name = @ptrCast(field.name.ptr),
                    .name = null,
                    .method = null,
                    .getter = FieldAccessor.getter,
                    .setter = FieldAccessor.setter,
                    .value = null,
                    .attributes = napi.napi_default,
                    .data = context,
                };
                prop_idx += 1;
            }

            // Process const declarations as static value properties
            // Following napi-rs pattern: use value field with static attribute
            inline for (decls) |decl| {
                if (comptime isConstDecl(decl.name)) {
                    const const_value = @field(T, decl.name);

                    // The value is materialized per environment (and per
                    // definition) so that no handle leaks across environments.
                    const static_value = try Napi.to_napi_value_auto(env, const_value, decl.name);

                    properties[prop_idx] = napi.napi_property_descriptor{
                        .utf8name = @ptrCast(decl.name.ptr),
                        .name = null,
                        .method = null,
                        .getter = null,
                        .setter = null,
                        .value = static_value,
                        .attributes = napi.napi_static | napi.napi_enumerable,
                        .data = null,
                    };
                    prop_idx += 1;
                }
            }

            // Process methods
            inline for (decls) |decl| {
                const decl_type = @TypeOf(@field(T, decl.name));
                if (@typeInfo(decl_type) == .@"fn") {
                    const fn_name = decl.name;
                    if (comptime !std.mem.eql(u8, fn_name, "init") and
                        !std.mem.eql(u8, fn_name, "deinit"))
                    {
                        const method = @field(T, fn_name);
                        const method_info = @typeInfo(@TypeOf(method));
                        const params = method_info.@"fn".params;

                        const is_instance_method = comptime isInstanceMethod(params);
                        const method_args_offset: usize = if (is_instance_method) 1 else 0;

                        const return_type = method_info.@"fn".return_type.?;
                        const return_payload = returnPayloadType(return_type);
                        const is_factory_method = blk: {
                            if (is_instance_method) break :blk false;
                            if (return_payload == T or return_payload == *T or return_payload == *const T) break :blk true;
                            break :blk false;
                        };

                        if (is_factory_method) {
                            const FactoryWrapper = factory_method_callback(fn_name);
                            properties[prop_idx] = napi.napi_property_descriptor{
                                .utf8name = @ptrCast(fn_name.ptr),
                                .name = null,
                                .method = FactoryWrapper.call,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = napi.napi_static,
                                .data = context,
                            };
                        } else {
                            const MethodWrapper = struct {
                                fn cleanupArgs(args: *std.meta.ArgsTuple(@TypeOf(method)), initialized: usize, allocator: std.mem.Allocator) void {
                                    inline for (0..method_info.@"fn".params.len - method_args_offset) |k| {
                                        if (k < initialized) {
                                            deinitValue(@TypeOf(args[method_args_offset + k]), args[method_args_offset + k], allocator);
                                        }
                                    }
                                }

                                fn call(method_env: napi.napi_env, info: napi.napi_callback_info) callconv(.c) napi.napi_value {
                                    const allocator = GlobalAllocator.capture();
                                    const method_arg_count = params.len - method_args_offset;
                                    var args_raw: [method_arg_count]napi.napi_value = undefined;
                                    const callback = readCallInfo(method_arg_count, method_env, info, &args_raw) orelse return null;

                                    var tuple_args: std.meta.ArgsTuple(@TypeOf(method)) = undefined;
                                    var initialized_args: usize = 0;
                                    defer cleanupArgs(&tuple_args, initialized_args, allocator);

                                    // Inject the receiver. Static methods do not
                                    // touch `this` at all: their `this` is the
                                    // constructor itself.
                                    if (comptime is_instance_method) {
                                        const instance = expectInstance(method_env, callback.this_obj, class_name ++ "." ++ fn_name) orelse return null;
                                        const self_type = method_info.@"fn".params[0].type.?;
                                        if (self_type == T) {
                                            // Value receiver: the method works on a
                                            // copy of the native state.
                                            tuple_args[0] = instance.value;
                                        } else {
                                            tuple_args[0] = &instance.value;
                                        }
                                        initialized_args = 1;
                                    }

                                    // Convert and pass the JavaScript arguments.
                                    inline for (0..method_arg_count) |k| {
                                        const param_type = method_info.@"fn".params[method_args_offset + k].type.?;
                                        tuple_args[method_args_offset + k] = Napi.from_napi_value_auto_with_allocator(method_env, args_raw[k], param_type, allocator) catch |err| {
                                            reportConversionFailure(method_env, err);
                                            return null;
                                        };
                                        initialized_args = k + 1;
                                    }

                                    if (@typeInfo(return_type) == .error_union) {
                                        const result = @call(.auto, method, tuple_args) catch |err| {
                                            return throwAnyAndNull(method_env, err);
                                        };
                                        return toNapiReturn(method_env, result, fn_name);
                                    }
                                    const result = @call(.auto, method, tuple_args);
                                    return toNapiReturn(method_env, result, fn_name);
                                }
                            };

                            properties[prop_idx] = napi.napi_property_descriptor{
                                .utf8name = @ptrCast(fn_name.ptr),
                                .name = null,
                                .method = MethodWrapper.call,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = comptime if (is_instance_method) napi.napi_default else napi.napi_static,
                                .data = context,
                            };
                        }
                        prop_idx += 1;
                    }
                }
            }

            var constructor: napi.napi_value = undefined;
            const define_status = napi.napi_define_class(env, class_name.ptr, class_name.len, constructor_callback, context, prop_idx, &properties, &constructor);
            if (define_status != napi.napi_ok) {
                releaseContext(context);
                return NapiError.failStatus(define_status);
            }

            // Weak reference: the class object stays collectible and factories
            // resolve the constructor through it, failing cleanly if the class
            // is already gone.
            var new_constructor_ref: napi.napi_ref = undefined;
            const ref_status = napi.napi_create_reference(env, constructor, 0, &new_constructor_ref);
            if (ref_status != napi.napi_ok) {
                releaseContext(context);
                return NapiError.failStatus(ref_status);
            }
            context.constructor_ref = new_constructor_ref;

            // Environments without cleanup hooks release the context from the
            // constructor finalizer instead (see `ClassContext`). Only one of
            // the two mechanisms is ever active, so a context is released once.
            if (comptime !options.selectedNapiVersion().isAtLeast(.v3)) {
                const wrap_status = napi.napi_wrap(env, constructor, context, contextFinalizer, null, null);
                if (wrap_status != napi.napi_ok) {
                    releaseContext(context);
                    return NapiError.failStatus(wrap_status);
                }
            }

            return constructor;
        }

        fn define_custom_method(_: napi.napi_env, _: napi.napi_value) !void {}

        pub fn to_napi_value(env: napi_env.Env) !napi.napi_value {
            const constructor = try Self.define_class(env.raw);
            try Self.define_custom_method(env.raw, constructor);
            return constructor;
        }
    };
}

test "field ownership policy is decided by type shape, not by addresses" {
    // Add `_ = @import("napi/wrapper/class.zig");` to src/unit_tests.zig to run
    // this with `zig build test`.
    const Wrapper = ClassWrapper(struct {
        text: []const u8,
        count: i32,
    }, true);

    // A type that declares `deinit` owns its fields; a field that can carry
    // native memory therefore needs an explicit owner before it can be
    // replaced, while plain data stays assignable.
    try std.testing.expect(Wrapper.replacementNeedsOwner(true, []const u8));
    try std.testing.expect(Wrapper.replacementNeedsOwner(true, struct { inner: []u8 }));
    try std.testing.expect(!Wrapper.replacementNeedsOwner(true, i32));
    try std.testing.expect(!Wrapper.replacementNeedsOwner(true, bool));
    try std.testing.expect(!Wrapper.replacementNeedsOwner(true, [4]u8));

    // Without `deinit` the type does not own anything, so no replacement is
    // rejected.
    try std.testing.expect(!Wrapper.replacementNeedsOwner(false, []const u8));

    // JavaScript handles reference runtime memory, never native memory of the
    // instance.
    try std.testing.expect(Wrapper.typeCarriesNativeMemory([]u8));
    try std.testing.expect(Wrapper.typeCarriesNativeMemory(?[]const u8));
    try std.testing.expect(Wrapper.typeCarriesNativeMemory(struct { inner: [2]f32, name: []const u8 }));
    try std.testing.expect(!Wrapper.typeCarriesNativeMemory(i32));
    try std.testing.expect(!Wrapper.typeCarriesNativeMemory([8]u8));
    // JavaScript handles reference runtime memory, not native instance memory.
    try std.testing.expect(!Wrapper.typeCarriesNativeMemory(Buffer));
    try std.testing.expect(!Wrapper.typeCarriesNativeMemory(ArrayBuffer));
    try std.testing.expect(!Wrapper.typeCarriesNativeMemory(@import("./typedarray.zig").Uint8Array));

    // A field type with `deinit` owns itself.
    try std.testing.expect(Wrapper.fieldOwnsItself(struct {
        pub fn deinit(_: @This()) void {}
    }));
}

pub fn Class(comptime T: type) type {
    return ClassWrapper(T, true);
}

pub fn ClassWithoutInit(comptime T: type) type {
    return ClassWrapper(T, false);
}

pub fn isClass(T: anytype) bool {
    const type_name = @typeName(T);
    return std.mem.indexOf(u8, type_name, "ClassWrapper") != null;
}
