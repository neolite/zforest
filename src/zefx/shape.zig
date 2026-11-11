const std = @import("std");
const store_mod = @import("store.zig");

/// Check if a type is a pointer to a Store(T).
pub fn isStorePtr(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const child_info = @typeInfo(info.pointer.child);
    if (child_info != .@"struct") return false;
    return @hasDecl(info.pointer.child, "Value") and @hasDecl(info.pointer.child, "notifyIfDirty");
}

/// Check if a type is a struct/tuple where all fields are *Store(T).
pub fn isStoreShape(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_types) |ft| {
        if (!isStorePtr(ft)) return false;
    }
    return info.@"struct".field_names.len > 0;
}

/// Given a shape type (struct of *Store), produce the snapshot type (struct of values).
pub fn SnapshotTypeOf(comptime Shape: type) type {
    if (!isStoreShape(Shape)) return void;
    const info = @typeInfo(Shape).@"struct";
    var field_names: [info.field_names.len][]const u8 = undefined;
    var field_types: [info.field_names.len]type = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, ft, i| {
        field_names[i] = name;
        field_types[i] = @typeInfo(ft).pointer.child.Value;
    }
    if (info.is_tuple) return @Tuple(&field_types);
    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

/// Read current values from a shape (struct/tuple of *Store).
pub fn readSnapshot(shape: anytype) SnapshotTypeOf(@TypeOf(shape)) {
    const Shape = @TypeOf(shape);
    const info = @typeInfo(Shape).@"struct";
    var result: SnapshotTypeOf(Shape) = undefined;
    inline for (info.field_names) |name| {
        @field(result, name) = @field(shape, name).get();
    }
    return result;
}
