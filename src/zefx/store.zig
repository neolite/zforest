const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const Thunk = eng_mod.Thunk;
const Subscription = eng_mod.Subscription;
const StoreNotifier = eng_mod.StoreNotifier;
const event_mod = @import("event.zig");

/// Default equality for `Store.eq`: scalar types (ints, bools, enums,
/// floats) compare with `==`. Compound values — slices, strings,
/// structs — get `null` (always written) unless the caller opts into an
/// explicit comparator. No automatic deep equality.
fn defaultEq(comptime T: type) ?*const fn (T, T) bool {
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .float => struct {
            fn eq(a: T, b: T) bool {
                return a == b;
            }
        }.eq,
        else => null,
    };
}

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        /// Opt-in content comparator `eq(old, new) -> bool`, used by the
        /// common write boundary (`writeValue`) on EVERY mutation path —
        /// `.set`/`.on`/`.reset` and derived writes. Default is comptime
        /// scalar equality; set `st.eq = &myEq` (or `= null` to disable).
        /// The comparison runs at WRITE time, before the caller may
        /// recycle the old value's backing storage — slice-valued stores
        /// backed by reset-on-refresh arenas must keep stable storage or
        /// skip `eq` (see zmon's fmt_arena (apps/mon/app.zig) stores).
        pub const EqFn = *const fn (T, T) bool;
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
        /// Equality policy — see `EqFn`/`defaultEq`. `null` = always write.
        eq: ?EqFn = defaultEq(T),
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

        /// Common write boundary: every mutation path (.set/.on/.reset/
        /// map/combine/sample targets) funnels here. When `eq` reports
        /// old == new the write is suppressed entirely — no prev/value
        /// update, no markDirty, no watcher or settle propagation.
        /// Returns true when the value was actually written. Public so
        /// root.zig operators (combine) share the same boundary.
        pub fn writeValue(self: *Self, new_val: T) bool {
            if (self.eq) |eq| {
                if (eq(self.value, new_val)) return false;
            }
            self.prev = self.value;
            self.value = new_val;
            self.markDirty();
            return true;
        }

        /// Imperatively set a new value. Equality-suppressed writes are
        /// dropped silently (no dirty, no flush); otherwise marks dirty
        /// and flushes if idle.
        pub fn set(self: *Self, val: T) void {
            if (!self.writeValue(val)) return;
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
            self.eng.assertSameEngine(ev.eng);
            self.ensureRegistered();

            const EvPayload = @TypeOf(ev.*).Payload;

            const ReducerCtx = struct {
                store: *Self,
                reducer: *const fn (T, EvPayload) ?T,
            };

            // The reducer ctx box is engine-tracked by onReducer — it
            // lives exactly as long as the graph, like every other unit.
            ev.onReducer(ReducerCtx{ .store = self, .reducer = reduce }, &struct {
                fn trig(c: ReducerCtx, payload: EvPayload) void {
                    if (c.reducer(c.store.value, payload)) |new_val| {
                        _ = c.store.writeValue(new_val);
                    }
                }
            }.trig);

            return self;
        }

        /// Reset this store to its initial value when the given event fires.
        pub fn reset(
            self: *Self,
            ev: anytype,
        ) *Self {
            const EvPayload = @TypeOf(ev.*).Payload;
            self.eng.assertSameEngine(ev.eng);

            const ResetCtx = struct {
                store: *Self,
            };

            self.ensureRegistered();
            ev.onReducer(ResetCtx{ .store = self }, &struct {
                fn trig(c: ResetCtx, _: EvPayload) void {
                    _ = c.store.writeValue(c.store.initial);
                }
            }.trig);

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
            source.updates().onReducer(MapCtx{ .target = derived, .mapFn = mapFn }, &struct {
                fn trig(c: MapCtx, payload: T) void {
                    _ = c.target.writeValue(c.mapFn(payload));
                }
            }.trig);

            return derived;
        }
    };
}
