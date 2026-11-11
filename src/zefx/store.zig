const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const Subscription = eng_mod.Subscription;
const StoreNotifier = eng_mod.StoreNotifier;
const event_mod = @import("event.zig");

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        pub const WatcherFn = *const fn (T) void;
        const CleanupSlot = struct {
            ptr: *anyopaque,
            destroyFn: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) void,
        };

        pub const CtxWatcherFn = *const fn (ctx: *anyopaque, T) void;
        pub const WatcherSlot = struct {
            generation: u32 = 1,
            active: bool = false,
            ctx: ?*anyopaque = null,
            plain_fn: ?WatcherFn = null,
            ctx_fn: ?CtxWatcherFn = null,
        };

        eng: *Engine,
        name_: []const u8 = "",
        value: T,
        prev: T,
        initial: T,
        /// Pending propagation: index is queued in engine.dirty_indices.
        dirty_pending: bool = false,
        /// Value changed this tick; view watchers still need to run.
        view_pending: bool = false,
        store_index: ?usize = null,
        watchers: std.ArrayListUnmanaged(WatcherSlot) = .empty,
        free_watcher_slots: std.ArrayListUnmanaged(usize) = .empty,
        reducer_cleanups: std.ArrayListUnmanaged(CleanupSlot) = .empty,
        updates_event: ?*event_mod.Event(T) = null,

        // --- fluent builder ---

        pub fn name(self: *Self, n: []const u8) *Self {
            self.name_ = n;
            return self;
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        /// JS-like alias for get().
        pub fn getState(self: *const Self) T {
            return self.get();
        }

        /// Imperatively set a new value. Marks dirty and flushes if idle.
        pub fn set(self: *Self, val: T) void {
            self.prev = self.value;
            self.value = val;
            self.markDirty();
            if (self.eng.phase == .idle) {
                self.eng.flush();
            }
        }

        /// JS-like alias for set().
        pub fn setState(self: *Self, val: T) void {
            self.set(val);
        }

        fn addWatcher(self: *Self, slot: WatcherSlot) Subscription {
            self.ensureRegistered();
            var s = slot;
            s.active = true;
            if (self.free_watcher_slots.pop()) |idx| {
                // Reuse keeps the bumped generation so stale handles miss.
                s.generation = self.watchers.items[idx].generation;
                self.watchers.items[idx] = s;
                return .{ .index = idx, .generation = s.generation };
            }
            const idx = self.watchers.items.len;
            self.watchers.append(self.eng.allocator, s) catch @panic("OOM");
            return .{ .index = idx, .generation = s.generation };
        }

        pub fn watch(self: *Self, cb: WatcherFn) Subscription {
            return self.addWatcher(.{ .plain_fn = cb });
        }

        /// Watch with an explicit context pointer — no closure allocation.
        /// `cb` is comptime so the trampoline can cast ctx back to its
        /// concrete type instead of relying on fn-pointer ABI punning.
        pub fn watchCtx(
            self: *Self,
            ctx: anytype,
            comptime cb: *const fn (@TypeOf(ctx), T) void,
        ) Subscription {
            const CtxT = @TypeOf(ctx);
            const S = struct {
                fn call(raw: *anyopaque, v: T) void {
                    const c: CtxT = @ptrCast(@alignCast(raw));
                    cb(c, v);
                }
            };
            return self.addWatcher(.{
                .ctx = @ptrCast(ctx),
                .ctx_fn = &S.call,
            });
        }

        /// JS-like alias for watch().
        pub fn subscribe(self: *Self, cb: WatcherFn) Subscription {
            return self.watch(cb);
        }

        /// Unwatch is generation-checked: a stale handle cannot remove a
        /// newer watcher that reused the same slot.
        pub fn unwatch(self: *Self, sub: Subscription) void {
            if (sub.index >= self.watchers.items.len) return;
            const slot = &self.watchers.items[sub.index];
            if (!slot.active) return;
            if (slot.generation != sub.generation) return; // stale handle
            slot.active = false;
            slot.plain_fn = null;
            slot.ctx_fn = null;
            slot.ctx = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.free_watcher_slots.append(self.eng.allocator, sub.index) catch @panic("OOM");
        }

        /// JS-like alias for unwatch().
        pub fn unsubscribe(self: *Self, sub: Subscription) void {
            self.unwatch(sub);
        }

        /// Returns an Event(T) that fires whenever this store updates.
        pub fn updates(self: *Self) *event_mod.Event(T) {
            if (self.updates_event) |ev| return ev;
            const ev = self.eng.allocator.create(event_mod.Event(T)) catch @panic("OOM");
            ev.* = .{ .eng = self.eng };
            self.updates_event = ev;
            return ev;
        }

        /// Subscribe this store to an event with a reducer.
        /// Reducer: fn(state: T, payload: E) ?T — return null to skip update.
        pub fn on(
            self: *Self,
            ev: anytype, // *Event(SomePayload)
            reduce: *const fn (T, @TypeOf(ev.*).Payload) ?T,
        ) *Self {
            self.ensureRegistered();

            const EvPayload = @TypeOf(ev.*).Payload;

            const ReducerCtx = struct {
                store: *Self,
                reducer: *const fn (T, EvPayload) ?T,
            };

            const ctx = self.eng.allocator.create(ReducerCtx) catch @panic("OOM");
            ctx.* = .{ .store = self, .reducer = reduce };

            // Track for cleanup
            self.reducer_cleanups.append(self.eng.allocator, .{
                .ptr = @ptrCast(ctx),
                .destroyFn = &struct {
                    fn destroy(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                        const typed: *ReducerCtx = @ptrCast(@alignCast(ptr));
                        alloc.destroy(typed);
                    }
                }.destroy,
            }) catch @panic("OOM");

            ev.reducers.append(self.eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw_ctx: *anyopaque, payload_ptr: *const anyopaque) void {
                        const c: *ReducerCtx = @ptrCast(@alignCast(raw_ctx));
                        const payload: *const EvPayload = @ptrCast(@alignCast(payload_ptr));
                        if (c.reducer(c.store.value, payload.*)) |new_val| {
                            c.store.prev = c.store.value;
                            c.store.value = new_val;
                            c.store.markDirty();
                        }
                    }
                }.trigger,
            }) catch @panic("OOM");

            return self;
        }

        /// Reset this store to its initial value when the given event fires.
        pub fn reset(
            self: *Self,
            ev: anytype,
        ) *Self {
            const EvPayload = @TypeOf(ev.*).Payload;

            const ResetCtx = struct {
                store: *Self,
            };

            const ctx = self.eng.allocator.create(ResetCtx) catch @panic("OOM");
            ctx.* = .{ .store = self };

            self.ensureRegistered();
            self.reducer_cleanups.append(self.eng.allocator, .{
                .ptr = @ptrCast(ctx),
                .destroyFn = &struct {
                    fn destroy(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                        const typed: *ResetCtx = @ptrCast(@alignCast(ptr));
                        alloc.destroy(typed);
                    }
                }.destroy,
            }) catch @panic("OOM");

            ev.reducers.append(self.eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw_ctx: *anyopaque, _: *const anyopaque) void {
                        const c: *ResetCtx = @ptrCast(@alignCast(raw_ctx));
                        _ = EvPayload; // keep comptime param alive
                        c.store.prev = c.store.value;
                        c.store.value = c.store.initial;
                        c.store.markDirty();
                    }
                }.trigger,
            }) catch @panic("OOM");

            return self;
        }

        /// Derive a new store by applying mapFn to each update.
        pub fn map(self: *Self, comptime R: type, mapFn: *const fn (T) R) *Store(R) {
            return MapHelper(T, R).create(self, mapFn);
        }

        pub fn ensureRegistered(self: *Self) void {
            if (self.store_index != null) return;
            self.store_index = self.eng.registerStore(.{
                .ctx = @ptrCast(self),
                .propagateFn = &struct {
                    fn propagate(raw: *anyopaque) void {
                        const s: *Self = @ptrCast(@alignCast(raw));
                        s.propagateIfDirty();
                    }
                }.propagate,
                .notifyFn = &struct {
                    fn notify(raw: *anyopaque) void {
                        const s: *Self = @ptrCast(@alignCast(raw));
                        s.notifyIfDirty();
                    }
                }.notify,
            });
        }

        pub fn markDirty(self: *Self) void {
            // Lazily self-register so derived stores created via map/combine
            // propagate even without explicit watchers.
            self.ensureRegistered();
            self.view_pending = true;
            if (self.dirty_pending) return; // already queued for propagation
            self.dirty_pending = true;
            if (self.store_index) |idx| {
                self.eng.markDirty(idx);
            }
        }

        /// Called by the engine during the settle phase: fire the updates
        /// event so derived stores recompute in the pure phase, before any
        /// view watcher runs. Clears `dirty_pending` so a store re-dirtied
        /// later in the same tick (e.g. by a watcher) is queued again.
        pub fn propagateIfDirty(self: *Self) void {
            self.dirty_pending = false;
            if (self.updates_event) |ev| {
                ev.emit(self.value);
            }
        }

        /// Called by engine during effects phase, after the graph settled.
        pub fn notifyIfDirty(self: *Self) void {
            if (!self.view_pending) return;
            self.view_pending = false;
            // Copy slots by value over a captured length: callbacks may
            // unwatch (inactive slot) or watch (realloc) during iteration.
            const n = self.watchers.items.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const slot = self.watchers.items[i];
                if (!slot.active) continue;
                if (slot.ctx_fn) |f| {
                    f(slot.ctx.?, self.value);
                } else if (slot.plain_fn) |f| {
                    f(self.value);
                }
            }
        }

        pub fn deinit(self: *Self) void {
            self.watchers.deinit(self.eng.allocator);
            self.free_watcher_slots.deinit(self.eng.allocator);
            for (self.reducer_cleanups.items) |slot| {
                slot.destroyFn(self.eng.allocator, slot.ptr);
            }
            self.reducer_cleanups.deinit(self.eng.allocator);
            if (self.updates_event) |ev| {
                ev.deinit();
                self.eng.allocator.destroy(ev);
            }
        }
    };
}

fn MapHelper(comptime T: type, comptime R: type) type {
    return struct {
        fn create(source: *Store(T), mapFn: *const fn (T) R) *Store(R) {
            const Derived = Store(R);
            const eng = source.eng;
            const derived = eng.allocator.create(Derived) catch @panic("OOM");
            const init_val = mapFn(source.value);
            derived.* = .{ .eng = eng, .value = init_val, .prev = init_val, .initial = init_val };
            eng.trackGraphAlloc(@ptrCast(derived), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const s: *Derived = @ptrCast(@alignCast(p));
                    s.deinit();
                    a.destroy(s);
                }
            }.dtor);

            const MapCtx = struct {
                target: *Derived,
                mapFn: *const fn (T) R,
            };
            const ctx = eng.allocator.create(MapCtx) catch @panic("OOM");
            ctx.* = .{ .target = derived, .mapFn = mapFn };
            eng.trackGraphAlloc(@ptrCast(ctx), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const c: *MapCtx = @ptrCast(@alignCast(p));
                    a.destroy(c);
                }
            }.dtor);

            source.updates().reducers.append(eng.allocator, .{
                .ctx = @ptrCast(ctx),
                .trigger = &struct {
                    fn trigger(raw: *anyopaque, payload_ptr: *const anyopaque) void {
                        const c: *MapCtx = @ptrCast(@alignCast(raw));
                        const payload: *const T = @ptrCast(@alignCast(payload_ptr));
                        const new_val = c.mapFn(payload.*);
                        c.target.prev = c.target.value;
                        c.target.value = new_val;
                        c.target.markDirty();
                    }
                }.trigger,
            }) catch @panic("OOM");

            return derived;
        }
    };
}
