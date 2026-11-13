const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const Subscription = eng_mod.Subscription;

pub fn Event(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Payload = T;
        pub const WatcherFn = *const fn (T) void;

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
        watchers: std.ArrayListUnmanaged(WatcherSlot) = .empty,
        free_watcher_slots: std.ArrayListUnmanaged(usize) = .empty,
        /// Store reducers subscribed via store.on(event, reducer).
        reducers: std.ArrayListUnmanaged(ReducerSlot) = .empty,

        pub const ReducerSlot = struct {
            ctx: *anyopaque,
            trigger: *const fn (ctx: *anyopaque, payload_ptr: *const anyopaque) void,
        };

        // --- fluent builder ---

        pub fn name(self: *Self, n: []const u8) *Self {
            self.name_ = n;
            return self;
        }

        fn addWatcher(self: *Self, slot: WatcherSlot) Subscription {
            var s = slot;
            s.active = true;
            if (self.free_watcher_slots.pop()) |idx| {
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

        /// Generation-checked: a stale handle cannot remove a newer watcher
        /// that reused the same slot.
        pub fn unwatch(self: *Self, sub: Subscription) void {
            if (sub.index >= self.watchers.items.len) return;
            const slot = &self.watchers.items[sub.index];
            if (!slot.active) return;
            if (slot.generation != sub.generation) return;
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

        /// Register a typed pure-phase reducer on this event — the
        /// supported way to subscribe arbitrary logic; `.reducers.append`
        /// remains the low-level escape hatch.
        ///
        /// `call` runs during the pure phase for every emit as
        /// `call(ctx, payload)` — the payload type is inferred from the
        /// event, mismatches fail at compile time. `ctx` is stored BY
        /// VALUE in a box the helper allocates on the engine allocator
        /// and frees via `trackGraphAlloc` at engine deinit; it may be
        /// any type. Pointers are borrowed (the pointee must outlive the
        /// engine — same contract as `watchCtx`); values are copied, so
        /// pass a small struct (e.g. `{ .s = session }`).
        ///
        /// Reducers cannot be unwatched — the slot lives until the event
        /// is deinitialized. The reducer runs on THIS event's engine, so
        /// no cross-engine edge is possible.
        pub fn onReducer(
            self: *Self,
            ctx: anytype,
            comptime call: *const fn (@TypeOf(ctx), T) void,
        ) void {
            const CtxT = @TypeOf(ctx);
            const Box = struct { ctx: CtxT };
            const box = self.eng.allocator.create(Box) catch @panic("OOM");
            box.* = .{ .ctx = ctx };
            self.reducers.append(self.eng.allocator, .{
                .ctx = @ptrCast(box),
                .trigger = &struct {
                    fn trig(raw: *anyopaque, pp: *const anyopaque) void {
                        const b: *Box = @ptrCast(@alignCast(raw));
                        if (comptime T == void) {
                            call(b.ctx, {});
                        } else {
                            const payload: *const T = @ptrCast(@alignCast(pp));
                            call(b.ctx, payload.*);
                        }
                    }
                }.trig,
            }) catch @panic("OOM");
            self.eng.trackGraphAlloc(@ptrCast(box), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    a.destroy(@as(*Box, @ptrCast(@alignCast(p))));
                }
            }.dtor);
        }

        /// Fire the event. Schedules pure (reducers) and effect (watchers) thunks.
        pub fn emit(self: *Self, payload: T) void {
            const tick_alloc = self.eng.tickAllocator();

            // Schedule reducer calls (pure phase)
            for (self.reducers.items) |slot| {
                const Ctx = struct {
                    slot: ReducerSlot,
                    payload: T,
                };
                const ctx = tick_alloc.create(Ctx) catch @panic("OOM");
                ctx.* = .{ .slot = slot, .payload = payload };

                self.eng.schedulePure(.{
                    .ctx = @ptrCast(ctx),
                    .call = &struct {
                        fn thunk(raw: *anyopaque) void {
                            const c: *Ctx = @ptrCast(@alignCast(raw));
                            const payload_opaque: *const anyopaque = @ptrCast(&c.payload);
                            c.slot.trigger(c.slot.ctx, payload_opaque);
                        }
                    }.thunk,
                });
            }

            // Schedule watcher calls (effects phase)
            if (self.watchers.items.len > 0) {
                const WCtx = struct {
                    watchers_ptr: *std.ArrayListUnmanaged(WatcherSlot),
                    payload: T,
                };
                const wctx = tick_alloc.create(WCtx) catch @panic("OOM");
                wctx.* = .{ .watchers_ptr = &self.watchers, .payload = payload };

                self.eng.scheduleEffect(.{
                    .ctx = @ptrCast(wctx),
                    .call = &struct {
                        fn thunk(raw: *anyopaque) void {
                            const c: *WCtx = @ptrCast(@alignCast(raw));
                            // Captured length + by-value slots: callbacks may
                            // unwatch or watch during iteration (realloc).
                            const n = c.watchers_ptr.items.len;
                            var i: usize = 0;
                            while (i < n) : (i += 1) {
                                const slot = c.watchers_ptr.items[i];
                                if (!slot.active) continue;
                                if (slot.ctx_fn) |f| {
                                    f(slot.ctx.?, c.payload);
                                } else if (slot.plain_fn) |f| {
                                    f(c.payload);
                                }
                            }
                        }
                    }.thunk,
                });
            }

            // Auto-flush if engine is idle (top-level emit)
            if (self.eng.phase == .idle) {
                self.eng.flush();
            }
        }

        /// Create a derived event that transforms each payload with mapFn.
        pub fn map(self: *Self, comptime R: type, mapFn: *const fn (T) R) *Event(R) {
            return EventMapHelper(T, R).create(self, mapFn);
        }

        /// Create a derived event that only fires when filterFn returns true.
        pub fn filter(self: *Self, filterFn: *const fn (T) bool) *Self {
            return EventFilterHelper(T).create(self, filterFn);
        }

        pub fn deinit(self: *Self) void {
            self.watchers.deinit(self.eng.allocator);
            self.free_watcher_slots.deinit(self.eng.allocator);
            self.reducers.deinit(self.eng.allocator);
        }
    };
}

fn EventMapHelper(comptime T: type, comptime R: type) type {
    return struct {
        fn create(source: *Event(T), mapFn: *const fn (T) R) *Event(R) {
            const Derived = Event(R);
            const eng = source.eng;
            const derived = eng.allocator.create(Derived) catch @panic("OOM");
            derived.* = .{ .eng = eng };
            eng.trackGraphAlloc(@ptrCast(derived), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const e: *Derived = @ptrCast(@alignCast(p));
                    e.deinit();
                    a.destroy(e);
                }
            }.dtor);

            const MapCtx = struct {
                target: *Derived,
                mapFn: *const fn (T) R,
            };
            source.onReducer(MapCtx{ .target = derived, .mapFn = mapFn }, &struct {
                fn trig(c: MapCtx, payload: T) void {
                    c.target.emit(c.mapFn(payload));
                }
            }.trig);

            return derived;
        }
    };
}

fn EventFilterHelper(comptime T: type) type {
    return struct {
        fn create(source: *Event(T), filterFn: *const fn (T) bool) *Event(T) {
            const eng = source.eng;
            const derived = eng.allocator.create(Event(T)) catch @panic("OOM");
            derived.* = .{ .eng = eng };
            eng.trackGraphAlloc(@ptrCast(derived), &struct {
                fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                    const e: *Event(T) = @ptrCast(@alignCast(p));
                    e.deinit();
                    a.destroy(e);
                }
            }.dtor);

            const FilterCtx = struct {
                target: *Event(T),
                filterFn: *const fn (T) bool,
            };
            source.onReducer(FilterCtx{ .target = derived, .filterFn = filterFn }, &struct {
                fn trig(c: FilterCtx, payload: T) void {
                    if (c.filterFn(payload)) {
                        c.target.emit(payload);
                    }
                }
            }.trig);

            return derived;
        }
    };
}
