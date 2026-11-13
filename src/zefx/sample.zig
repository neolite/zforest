const std = @import("std");
const eng_mod = @import("engine.zig");
const Engine = eng_mod.Engine;
const event_mod = @import("event.zig");
const shape_mod = @import("shape.zig");

fn isStorePtr(comptime T: type) bool {
    return shape_mod.isStorePtr(T);
}

/// `*Event(T)`: pointer to a struct declaring `Payload` and `emit`.
fn isEventPtr(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const child = info.pointer.child;
    if (@typeInfo(child) != .@"struct") return false;
    return @hasDecl(child, "Payload") and @hasDecl(child, "emit");
}

/// `*Effect(P,R,E)`: pointer to a struct declaring `ParamT` and `run`.
fn isEffectPtr(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const child = info.pointer.child;
    if (@typeInfo(child) != .@"struct") return false;
    return @hasDecl(child, "ParamT") and @hasDecl(child, "run");
}

/// Clock payload type: `*Event(T)` → T, `*Store(T)` → T (its `Value`).
fn ClockPayloadOf(comptime Clock: type) type {
    const Child = @typeInfo(Clock).pointer.child;
    return if (isStorePtr(Clock)) Child.Value else Child.Payload;
}

/// Source snapshot type: a store's `Value`, or a shape-of-stores snapshot.
/// Event sources are rejected — an event has no readable "latest value";
/// `forward()` covers event→unit payload piping.
fn resolveSourceType(comptime Source: type) type {
    if (shape_mod.isStoreShape(Source)) return shape_mod.SnapshotTypeOf(Source);
    if (isStorePtr(Source)) return @typeInfo(Source).pointer.child.Value;
    @compileError("sample source must be *Store(T) or a shape of *Store(T); *Event sources are unsupported — use forward() to pipe event payloads");
}

fn FnReturnType(comptime F: type) type {
    const info = @typeInfo(F);
    if (info == .@"fn") return info.@"fn".return_type.?;
    if (info == .pointer) {
        const ci = @typeInfo(info.pointer.child);
        if (ci == .@"fn") return ci.@"fn".return_type.?;
    }
    @compileError("expected fn or *const fn");
}

/// Compute result value type (after fn_ transform).
fn ResultOf(comptime Opts: type) type {
    if (@hasField(Opts, "fn_")) return FnReturnType(@FieldType(Opts, "fn_"));
    if (@hasField(Opts, "source")) return resolveSourceType(@FieldType(Opts, "source"));
    // clock-only without fn_: the clock payload passes through
    return ClockPayloadOf(@FieldType(Opts, "clock"));
}

/// Return type of sample():
///   - target provided → returns typeof(target)  (the target pointer itself)
///   - target absent   → returns *Event(ResultType)  (newly created)
fn SampleReturnType(comptime Opts: type) type {
    if (@hasField(Opts, "target")) {
        return @FieldType(Opts, "target");
    }
    return *event_mod.Event(ResultOf(Opts));
}

fn MakeWire(
    comptime SourceField: type,
    comptime FilterField: type,
    comptime FnField: type,
    comptime TargetField: type,
    comptime SourceType: type,
    comptime ClockType: type,
    comptime ResultType: type,
    comptime has_source: bool,
    comptime has_clock: bool,
    comptime has_filter: bool,
    comptime has_fn: bool,
    comptime is_source_shape: bool,
    comptime is_target_store: bool,
    comptime is_target_event: bool,
) type {
    return struct {
        source: SourceField,
        filter: FilterField,
        fn_: FnField,
        target: TargetField,

        const Self = @This();

        /// Runs in the engine's post-settle phase: every reducer and
        /// derived-store propagation has completed, so `source` reads
        /// observe settled state regardless of registration order.
        ///
        /// fn_/filter calling convention (comptime-selected):
        ///   source+clock → fn(source_snapshot, clock_payload)
        ///   source only  → fn(source_snapshot)
        ///   clock only   → fn(clock_payload)
        /// Without fn_, the result is the source snapshot when a source
        /// is present, else the clock payload.
        pub fn run(self: *Self, clk: ClockType) void {
            const src_val: SourceType = blk: {
                if (comptime !has_source) break :blk {};
                if (comptime is_source_shape) break :blk shape_mod.readSnapshot(self.source);
                break :blk self.source.get();
            };

            if (comptime has_filter) {
                if (comptime isStorePtr(@TypeOf(self.filter))) {
                    if (!self.filter.get()) return;
                } else if (comptime has_clock and has_source) {
                    if (!@call(.auto, self.filter, .{ src_val, clk })) return;
                } else if (comptime has_source) {
                    if (!@call(.auto, self.filter, .{src_val})) return;
                } else {
                    if (!@call(.auto, self.filter, .{clk})) return;
                }
            }

            const result: ResultType = if (comptime has_fn) blk: {
                if (comptime has_clock and has_source) break :blk @call(.auto, self.fn_, .{ src_val, clk });
                if (comptime has_source) break :blk @call(.auto, self.fn_, .{src_val});
                break :blk @call(.auto, self.fn_, .{clk});
            } else if (comptime has_source) src_val else clk;

            if (comptime is_target_store) {
                self.target.set(result);
            } else if (comptime is_target_event) {
                self.target.emit(result);
            } else {
                // Effect targets run the effect — they are not events.
                self.target.run(result);
            }
        }
    };
}

/// Track a heap allocation on the engine for cleanup at deinit.
fn track(eng: *Engine, comptime T: type, ptr: *T) void {
    eng.trackGraphAlloc(@ptrCast(ptr), &struct {
        fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
            a.destroy(@as(*T, @ptrCast(@alignCast(p))));
        }
    }.dtor);
}

// ─────────────────────────────────────────────
// sample() — typed, settle-safe sampling
// ─────────────────────────────────────────────
// • clock  (optional): *Event(T) | *Store(T) — store clocks trigger on
//   `store.updates()` and carry the new value as payload.
// • source (optional): *Store(T) | shape of *Store — event sources are
//   rejected (no defined latest-value semantics; use forward()).
// • filter (optional): *Store(bool) | fn — same arity as fn_.
// • fn_    (optional): transform; arity follows the inputs present.
// • target (optional): *Store(R) | *Event(R) | *Effect(R,_,_) —
//   mismatched payload types and unsupported units fail at compile time.
//
// Wires trigger as ordinary reducers but only SCHEDULE the computation;
// the engine runs it in a post-settle phase, so reads see final derived
// state. Returns the target (provided or created *Event(R)).

pub fn sample(eng: *Engine, opts: anytype) SampleReturnType(@TypeOf(opts)) {
    const Opts = @TypeOf(opts);
    const has_source = @hasField(Opts, "source");
    const has_clock = @hasField(Opts, "clock");
    const has_filter = @hasField(Opts, "filter");
    const has_fn = @hasField(Opts, "fn_");
    const has_target = @hasField(Opts, "target");

    if (!has_source and !has_clock) @compileError("sample requires at least `source` or `clock`");

    const is_clock_store = comptime has_clock and isStorePtr(@TypeOf(opts.clock));
    const is_clock_event = comptime has_clock and isEventPtr(@TypeOf(opts.clock));
    if (has_clock and !is_clock_store and !is_clock_event)
        @compileError("sample clock must be *Event(T) or *Store(T)");

    const is_source_store = comptime has_source and isStorePtr(@TypeOf(opts.source));
    const is_source_shape = comptime has_source and shape_mod.isStoreShape(@TypeOf(opts.source));
    if (has_source and !is_source_store and !is_source_shape)
        @compileError("sample source must be *Store(T) or a shape of *Store(T); *Event sources are unsupported — use forward()");

    const SourceType = if (has_source) resolveSourceType(@TypeOf(opts.source)) else void;
    const ClockType = if (has_clock) ClockPayloadOf(@TypeOf(opts.clock)) else void;
    const ResultType = comptime ResultOf(Opts);

    // Ownership: every graph input must belong to this engine.
    if (has_clock) eng.assertSameEngine(opts.clock.eng);
    if (has_source) {
        if (comptime is_source_shape) {
            const ShapeInfo = @typeInfo(@TypeOf(opts.source)).@"struct";
            inline for (ShapeInfo.field_names) |fname| {
                eng.assertSameEngine(@field(opts.source, fname).eng);
            }
        } else {
            eng.assertSameEngine(opts.source.eng);
        }
    }
    if (has_filter) {
        if (comptime isStorePtr(@TypeOf(opts.filter))) eng.assertSameEngine(opts.filter.eng);
    }
    if (has_target) eng.assertSameEngine(opts.target.eng);

    // Resolve or create target
    const target = if (has_target) opts.target else blk: {
        const EvType = event_mod.Event(ResultType);
        const ev = eng.allocator.create(EvType) catch @panic("OOM");
        ev.* = .{ .eng = eng };
        // Track with deinit (frees internal ArrayLists) before destroy
        eng.trackGraphAlloc(@ptrCast(ev), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                const e: *EvType = @ptrCast(@alignCast(p));
                e.deinit();
                a.destroy(e);
            }
        }.dtor);
        break :blk ev;
    };

    // Typed target: store / event / effect, payload-compatible.
    const TargetType = @TypeOf(target);
    if (@typeInfo(TargetType) != .pointer)
        @compileError("sample target must be *Store(T), *Event(T), or *Effect(P,R,E)");
    const TargetChild = @typeInfo(TargetType).pointer.child;
    const is_target_store = comptime isStorePtr(TargetType);
    const is_target_event = comptime isEventPtr(TargetType);
    const is_target_effect = comptime isEffectPtr(TargetType);
    if (!is_target_store and !is_target_event and !is_target_effect)
        @compileError("sample target must be *Store(T), *Event(T), or *Effect(P,R,E)");
    if (comptime is_target_store) {
        if (TargetChild.Value != ResultType)
            @compileError("sample target store value type must match the sampled result type");
    } else if (comptime is_target_event) {
        if (TargetChild.Payload != ResultType)
            @compileError("sample target event payload type must match the sampled result type");
    } else {
        if (TargetChild.ParamT != ResultType)
            @compileError("sample→effect requires the sampled result type to equal the effect params type");
    }

    const SourceField = if (has_source) @TypeOf(opts.source) else void;
    const FilterField = if (has_filter) @TypeOf(opts.filter) else void;
    const FnField = if (has_fn) @TypeOf(opts.fn_) else void;

    const WireCtx = MakeWire(
        SourceField,
        FilterField,
        FnField,
        TargetType,
        SourceType,
        ClockType,
        ResultType,
        has_source,
        has_clock,
        has_filter,
        has_fn,
        is_source_shape,
        is_target_store,
        is_target_event,
    );

    const wire = eng.allocator.create(WireCtx) catch @panic("OOM");
    wire.* = .{
        .source = if (has_source) opts.source else {},
        .filter = if (has_filter) opts.filter else {},
        .fn_ = if (has_fn) opts.fn_ else {},
        .target = target,
    };
    track(eng, WireCtx, wire);

    // Deferred-execution plumbing: triggers run as ordinary reducers in
    // the pure phase but only ENQUEUE the wire; the engine drains
    // sample_queue after the graph settles. The clock payload is copied
    // into the tick arena, which outlives the whole flush.
    const TrigCtx = struct { eng: *Engine, wire: *WireCtx };
    const WireBox = struct { wire: *WireCtx };
    const ClockBox = struct { wire: *WireCtx, payload: ClockType };

    const SrcStep = struct {
        fn go(raw: *anyopaque) void {
            const b: *WireBox = @ptrCast(@alignCast(raw));
            b.wire.run({});
        }
    };
    const ClockStep = struct {
        fn go(raw: *anyopaque) void {
            const b: *ClockBox = @ptrCast(@alignCast(raw));
            b.wire.run(b.payload);
        }
    };

    if (has_clock) {
        // Store clocks fire on updates() — payload is the new value.
        const clock_unit = if (comptime is_clock_store) opts.clock.updates() else opts.clock;
        clock_unit.onReducer(TrigCtx{ .eng = eng, .wire = wire }, &struct {
            fn trig(c: TrigCtx, clk: ClockType) void {
                const box = c.eng.tickAllocator().create(ClockBox) catch @panic("OOM");
                box.* = .{ .wire = c.wire, .payload = clk };
                c.eng.scheduleSample(.{ .ctx = @ptrCast(box), .call = ClockStep.go });
            }
        }.trig);
    } else {
        // Source-only: re-sample on every source store update. A shape
        // fires once per member update — use `clock` to coalesce.
        if (comptime is_source_shape) {
            const ShapeInfo = @typeInfo(@TypeOf(opts.source)).@"struct";
            inline for (ShapeInfo.field_names) |fname| {
                const member = @field(opts.source, fname);
                // Each member's updates() payload type differs — the
                // anonymous call fn is instantiated per field.
                const MV = @typeInfo(@TypeOf(member)).pointer.child.Value;
                member.updates().onReducer(TrigCtx{ .eng = eng, .wire = wire }, &struct {
                    fn trig(c: TrigCtx, _: MV) void {
                        const box = c.eng.tickAllocator().create(WireBox) catch @panic("OOM");
                        box.* = .{ .wire = c.wire };
                        c.eng.scheduleSample(.{ .ctx = @ptrCast(box), .call = SrcStep.go });
                    }
                }.trig);
            }
        } else {
            opts.source.updates().onReducer(TrigCtx{ .eng = eng, .wire = wire }, &struct {
                fn trig(c: TrigCtx, _: SourceType) void {
                    const box = c.eng.tickAllocator().create(WireBox) catch @panic("OOM");
                    box.* = .{ .wire = c.wire };
                    c.eng.scheduleSample(.{ .ctx = @ptrCast(box), .call = SrcStep.go });
                }
            }.trig);
        }
    }

    return target;
}

// ─────────────────────────────────────────────
// attach() — the sample pipeline as a first-class named unit
// ─────────────────────────────────────────────
// attach(eng, opts) accepts the same options as sample() — `source`
// (store or shape of stores), `clock` (event or store), `filter`,
// `fn_`, optional `target`, optional `name` — but ALWAYS returns the
// attached unit itself: a real `*Event(Result)` owned by the engine
// that fires the sampled result on every trigger. Because it is an
// ordinary event it can be watched, mapped, filtered, used as a
// `clock`/`target` in further sample/forward wiring, or fed to
// `onReducer`.
//
// `.target`, when present, is ADDITIONAL fan-out: each result is also
// delivered to it (store → set, event → emit, effect → run), with the
// same compile-time payload checks sample applies. Unlike sample(),
// attach never returns the target — the attached event is the stable
// identity apps hold onto.
//
// Semantics are inherited wholesale from sample(): wires only schedule
// and the engine runs them post-settle, so source reads observe final
// derived state; every input is assertSameEngine-checked.

/// Rebuild a sample options struct with `.target` forced to `AttachedT`:
/// every other field is carried over verbatim (unknown fields like
/// `name` pass through harmlessly — sample ignores them), an existing
/// `target` field's type is replaced, or `target` is appended when the
/// caller didn't provide one.
fn AttachWireOpts(comptime O: type, comptime AttachedT: type) type {
    const info = @typeInfo(O).@"struct";
    const has_t = @hasField(O, "target");
    const N = info.field_names.len + (if (has_t) @as(usize, 0) else 1);
    var names: [N][]const u8 = undefined;
    var types: [N]type = undefined;
    var n: usize = 0;
    inline for (info.field_names, info.field_types) |name, ft| {
        if (comptime std.mem.eql(u8, name, "target")) continue;
        names[n] = name;
        types[n] = ft;
        n += 1;
    }
    names[n] = "target";
    types[n] = AttachedT;
    n += 1;
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub fn attach(eng: *Engine, opts: anytype) *event_mod.Event(ResultOf(@TypeOf(opts))) {
    const O = @TypeOf(opts);
    if (!@hasField(O, "source") and !@hasField(O, "clock"))
        @compileError("attach requires at least `source` or `clock`");
    const ResultT = ResultOf(O);
    const EvT = event_mod.Event(ResultT);

    // The attached unit — tracked like every other graph unit.
    const attached = eng.allocator.create(EvT) catch @panic("OOM");
    attached.* = .{ .eng = eng };
    eng.trackGraphAlloc(@ptrCast(attached), &struct {
        fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
            const e: *EvT = @ptrCast(@alignCast(p));
            e.deinit();
            a.destroy(e);
        }
    }.dtor);
    if (@hasField(O, "name")) attached.name_ = opts.name;

    // Main wire: identical inputs to opts, but the sampled result is
    // emitted on the attached event (an ordinary event target).
    const WireOptsT = AttachWireOpts(O, *EvT);
    var wopts: WireOptsT = undefined;
    inline for (@typeInfo(WireOptsT).@"struct".field_names) |fname| {
        // comptime-known condition: only the taken branch is analyzed,
        // so `attached` is never assigned to a non-target field.
        if (comptime std.mem.eql(u8, fname, "target")) {
            @field(wopts, fname) = attached;
        } else {
            @field(wopts, fname) = @field(opts, fname);
        }
    }
    _ = sample(eng, wopts);

    // Optional fan-out to the caller's target — a clock-only sample
    // forwards the attached event's payload, so store/event/effect
    // targets and their payload checks come from sample for free.
    if (@hasField(O, "target")) {
        _ = sample(eng, .{ .clock = attached, .target = opts.target });
    }

    return attached;
}

// ─────────────────────────────────────────────
// forward(from, to) — clock-only sample: the clock payload passes
// through untouched to the target (event → emit, store → set,
// effect → run). `from` may be *Event or *Store.
// ─────────────────────────────────────────────

pub fn forward(eng: *Engine, from: anytype, to: anytype) @TypeOf(to) {
    return sample(eng, .{ .clock = from, .target = to });
}

// ─────────────────────────────────────────────
// guard() — sample + filter sugar (deprecated in effector v23)
// ─────────────────────────────────────────────

pub fn guard(eng: *Engine, opts: anytype) SampleReturnType(@TypeOf(opts)) {
    const Opts = @TypeOf(opts);
    if (!@hasField(Opts, "filter")) @compileError("guard(): missing 'filter'");
    return sample(eng, opts);
}
