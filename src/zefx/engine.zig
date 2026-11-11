const std = @import("std");

/// Generational subscription handle. The `generation` distinguishes a stale
/// handle from a live one when a slot index is reused after `unwatch`.
pub const Subscription = struct { index: usize, generation: u32 };
pub const Phase = enum { idle, pure, effects };

pub const Thunk = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
    pub fn invoke(self: Thunk) void {
        self.call(self.ctx);
    }
};

/// Per-store hooks driven by the engine during a flush.
/// `propagate` fires the store's `updates` event (derived-store recalculation)
/// during the settle phase, before any view watcher runs.
/// `notify` invokes user/view watchers once the graph has fully settled.
pub const StoreNotifier = struct {
    ctx: *anyopaque,
    propagateFn: *const fn (ctx: *anyopaque) void,
    notifyFn: *const fn (ctx: *anyopaque) void,
};

pub const Engine = struct {
    pub const CleanupFn = *const fn (std.mem.Allocator, *anyopaque) void;
    pub const CleanupEntry = struct { ptr: *anyopaque, dtor: CleanupFn };

    allocator: std.mem.Allocator,
    tick_arena: std.heap.ArenaAllocator,
    phase: Phase = .idle,
    tick_id: u32 = 1,
    pure_queue: std.ArrayListUnmanaged(Thunk) = .empty,
    effect_queue: std.ArrayListUnmanaged(Thunk) = .empty,
    store_notifiers: std.ArrayListUnmanaged(StoreNotifier) = .empty,
    dirty_indices: std.ArrayListUnmanaged(usize) = .empty,
    graph_cleanups: std.ArrayListUnmanaged(CleanupEntry) = .empty,
    /// Persistent hooks invoked after each completed flush (e.g. view render).
    after_flush_hooks: std.ArrayListUnmanaged(Thunk) = .empty,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .tick_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.graph_cleanups.items) |entry| {
            entry.dtor(self.allocator, entry.ptr);
        }
        self.graph_cleanups.deinit(self.allocator);
        self.tick_arena.deinit();
        self.pure_queue.deinit(self.allocator);
        self.effect_queue.deinit(self.allocator);
        self.store_notifiers.deinit(self.allocator);
        self.dirty_indices.deinit(self.allocator);
        self.after_flush_hooks.deinit(self.allocator);
    }

    pub fn tickAllocator(self: *Engine) std.mem.Allocator {
        return self.tick_arena.allocator();
    }

    pub fn registerStore(self: *Engine, notifier: StoreNotifier) usize {
        const idx = self.store_notifiers.items.len;
        self.store_notifiers.append(self.allocator, notifier) catch @panic("OOM");
        return idx;
    }

    /// Register a persistent hook invoked after every completed flush.
    pub fn onAfterFlush(self: *Engine, thunk: Thunk) void {
        self.after_flush_hooks.append(self.allocator, thunk) catch @panic("OOM");
    }

    pub fn markDirty(self: *Engine, store_index: usize) void {
        self.dirty_indices.append(self.allocator, store_index) catch @panic("OOM");
    }

    /// Drain a queue with an index cursor — no alloc/copy. Thunks appended
    /// while draining are processed in the same pass.
    fn drainQueue(queue: *std.ArrayListUnmanaged(Thunk)) void {
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            queue.items[i].invoke();
        }
        queue.clearRetainingCapacity();
    }

    pub fn flush(self: *Engine) void {
        // Drain until stable. Effects may emit new events, which enqueue new
        // pure reducers that must run before ending the tick/resetting arena.
        while (true) {
            // Phase 1: pure — drain reducers (may enqueue more)
            self.phase = .pure;
            drainQueue(&self.pure_queue);

            // Settle phase: propagate each dirty store's `updates` event so
            // derived stores (map/sample/combine) recompute in the pure phase.
            // Repeat until no store is left dirty — chains and diamonds settle
            // before any view watcher observes state.
            while (self.dirty_indices.items.len > 0) {
                var i: usize = 0;
                while (i < self.dirty_indices.items.len) : (i += 1) {
                    const n = self.store_notifiers.items[self.dirty_indices.items[i]];
                    n.propagateFn(n.ctx);
                }
                self.dirty_indices.clearRetainingCapacity();
                self.phase = .pure;
                drainQueue(&self.pure_queue);
            }

            // Phase 2: effects — the graph is fully settled.
            self.phase = .effects;
            // 2a: view watchers on every store dirtied this tick
            for (self.store_notifiers.items) |n| {
                n.notifyFn(n.ctx);
            }

            // 2b: event watchers / scheduled effects
            drainQueue(&self.effect_queue);

            if (self.pure_queue.items.len == 0 and self.effect_queue.items.len == 0 and self.dirty_indices.items.len == 0) {
                break;
            }
        }

        // Reset per-tick arena, advance tick
        _ = self.tick_arena.reset(.retain_capacity);
        self.tick_id +%= 1;
        if (self.tick_id == 0) self.tick_id = 1;
        self.phase = .idle;

        for (self.after_flush_hooks.items) |hook| hook.invoke();
    }

    pub fn trackGraphAlloc(self: *Engine, ptr: *anyopaque, dtor: CleanupFn) void {
        self.graph_cleanups.append(self.allocator, .{ .ptr = ptr, .dtor = dtor }) catch @panic("OOM");
    }

    pub fn schedulePure(self: *Engine, thunk: Thunk) void {
        self.pure_queue.append(self.allocator, thunk) catch @panic("OOM");
    }

    pub fn scheduleEffect(self: *Engine, thunk: Thunk) void {
        self.effect_queue.append(self.allocator, thunk) catch @panic("OOM");
    }
};
