//! Test root for the zsx spike — pulls in the app-dir test file so the
//! module path covers all of `src/` (the h.*/zmeta plain-source imports
//! stay relative, preserving History/Dom/forest type identity — same
//! reason zmeta_demo_main.zig sits flat in src/).
test {
    _ = @import("apps/zsx_spike/tests.zig");
}
