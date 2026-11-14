# `.zsx` template syntax — adoption spike

Time-boxed spike: does a JSX-like `.zsx` template surface earn its keep
in zforest view code? A minimal transpiler (`src/zmeta/zsx.zig`,
`zig build zsx` / `zig build zsx-check`) lowers `.zsx` templates to
`forest.el` calls — **never `h.*`** — and the spike app
(`src/apps/zsx_spike/`) proves parity against handwritten `h.*` and
`forest.el` versions of the same two views.

**Verdict up front: the precommitted bar is met — `.zsx` is adopt-worthy
on the measured evidence, with caveats.** See [Verdict](#verdict).

> **Post-review update:** a hostile Astra review of this spike
> recommended **against adoption** — the −36% figure depends on
> anonymous `ctx:` literals (named-ctx style measures −22%), the
> transpiler is a second compiler (~1k lines + build steps) whose
> diagnostics/IDE costs were never measured, whitespace rules can
> change rendered content, and `forest.el`/`h.*` already cover the
> ergonomic need. The spike is preserved as an experiment; the
> transpiler is NOT part of the supported view surface. `h.*`'s
> `Bound.live` gap cited below was fixed afterwards via `forest.bind`,
> removing zsx's one real advantage.

## Grammar

One root element per file. No HTML error recovery, no components, no
spread, no loops/conditionals in markup (use `forest.when`/`eachOf`
holes for those).

```text
template  := element EOF
element   := open_elem children ("</" name ">" | "/>")
open_elem := "<" name (S attr)* ">"
selfclose := "<" name (S attr)* "/>"
attr      := name "=" (quoted | "{" zig_expr "}")
           | "on:" event "=" "{" zig_expr "}"
children  := (text | "{" zig_expr "}" | element)*
text      := any chars except "<" and "{"   (see whitespace rule)
quoted    := '"' (any except '"')* '"'  |  "'" (any except "'")* "'"
zig_expr  := Zig tokens with balanced () [] {} — strings, char
             literals, line/block comments and multiline strings
             are skipped while scanning for the closing "}"
```

Whitespace rule: a whitespace-only text run **containing a newline** is
dropped as formatting indentation; every other text (including
same-line `" "` and `" · "` separators) is emitted verbatim as
`forest.text`.

Entities: **none** — `&amp;` etc. are emitted literally. Write literal
UTF-8 or a `{…}` hole. Documented limitation, not a bug.

Tags are validated against `forest.Tag`; void elements
(`area base br col embed hr img input link meta source track wbr`)
must self-close and reject children. `on:<event>` names are checked
against forest's six-event whitelist (`click dblclick change input
submit keydown`).

## Attribute → forest mapping

| `.zsx` attr            | generated field                          |
|------------------------|------------------------------------------|
| `on:click={expr}`      | merged into `.on = .{ .click = expr, … }` (all `on:*` on one element combine) |
| `id=` `lid=` `arg=` `text=` | `.id` / `.lid` / `.arg` / `.text` (bound-operand capable) |
| `class=` `href=` `type=` `value=` `name=` `placeholder=` `for_=` `disabled=` `checked=` | same-named `forest.Element` fields |
| any other `name=`      | generic attr: valid Zig idents emit `.name`, others emit `.@"name"` |
| `attr={expr}` / `attr="lit"` | literal strings emit as `[]const u8`; `{…}` emits the expression verbatim (store pointers, `computed`, `Bound` all work) |

Child holes emit the expression **directly** — a sole `{forest.eachOf(…)}`
hole passes the keyed `Children` through unwrapped; multiple children
become a tuple. `{forest.when(…)}` / `{forest.variant(…)}` nodes work
as ordinary children.

Generated shape (abridged):

```zig
pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node {
    return forest.el(a, .li, .{ .id = ctx.id_str, .class = "comment" }, .{
        forest.el(a, .div, .{ .class = "cmeta" }, .{
            forest.el(a, .a, .{ .class = "plink", .href = ctx.permalink }, ctx.hash),
            forest.text(" · "),
            // …
        }),
        forest.el(a, .div, .{ .class = "ctext" }, ctx.c.text),
        forest.when(a, .{ .id = ctx.rep_id }, ctx.replying, ctx.reply_form),
        forest.el(a, .ul, .{ .lid = "kids", .class = "kids" },
            forest.eachOf(a, ctx.c.children, ctx.env, ctx.kid_row)),
    });
}
```

`a`, `ctx`, `std`, `forest` are in scope inside `{…}` holes; `ctx` is
`anytype` so callers pass plain struct literals — no ctx types to
declare.

## Diagnostics

Parse errors are positioned and abort generation before any Zig is
emitted. Real CLI output (`zig run src/zmeta/zsx.zig -- <app-dir>`):

```text
zsx: templates/bad1.zsx:2:19: mismatched delimiter '}' in {…} expression (expected ')')
zsx: templates/bad2.zsx:1:1:  unknown tag '<blink>' — not a forest.Tag member
zsx: templates/bad3.zsx:1:1:  void element <input> must self-close — write '<input … />'
zsx: templates/bad4.zsx:1:9:  unknown event 'bogus' in on:bogus — forest allows click/dblclick/change/input/submit/keydown
```

Also covered by unit tests: mismatched close tag, unterminated
`{`, unterminated quote, stray text after root, duplicate attrs.

**Type errors inside holes** are Zig's, cited at the generated file —
`app/gen/bad.zig:11:19: error: no field named 'nope' in tuple …` —
with the expression verbatim and the `.zsx` source named in the file's
header comment. One hop removed, expression visible: tolerable, but
line numbers do not map back to template lines.

## Parity evidence (`src/apps/zsx_spike/tests.zig`)

Two representative views — a post form (bound textarea `value`,
submit handler) and a comment row (bound like-count `.text`,
`w-rep-N` `when` inline reply, nested keyed `<ul>` of child rows) —
each implemented three ways: `.zsx`→gen, handwritten `h.*`, handwritten
`forest.el`. All tests pass (`zig build test`).

- **SSR**: `writeHtml` output byte-identical across all three, for
  both views, including the reply-mounted state.
- **Snapshot**: `writeSnapshotOps` JSON identical (carries `when`,
  keyed `html`, and bound `text` ops).
- **Patch cycle**: identical `PatchLog.writeJson` across four diff
  steps — seed; like-count text patch + `when` mount + keyed reorder;
  `when` unmount + keyed removal; stable re-render (empty batch).
- **Live binding**: the `computed` like label survives lowering —
  `bindTree` subscribes all three rows' stores; `emit` produces the
  `text` patch (`"▲ 9"`) with no rebuild.
- **h.* divergence, documented**: a raw `*T.get()` attr keeps
  `Bound.live` through the `forest.el` path (zsx and handwritten el:
  1 binding, patch on `emit`) but `h.*`'s ported `bindGet` leaves
  `live = null` (0 bindings, silent). This is exactly why the
  transpiler emits `forest.el`, not `h.*`.

## LOC — handwritten view code

Counted: non-blank, non-`//`-comment lines. `.zsx` side = templates +
handwritten ctx glue (`zsx_app.zig`); generated `gen/*.zig` (128
lines) is machine-maintained and excluded. `model.zig`/`tests.zig`
are shared scaffolding, excluded from all three.

| view                          | `.zsx` (tpl+glue) | `h.*` | `forest.el` | vs `h.*` |
|-------------------------------|-------------------|-------|-------------|----------|
| post form                     | 5 + 3 = **8**     | 26    | 28          | −69%     |
| comment row + inline reply    | 8+7 + 33 = **48** | 74    | 69          | −35%     |
| **total (both examples)**     | **64**            | 100   | 97          | **−36%** |

Sensitivity, disclosed: an earlier cut declared a named `RowCtx`
struct (~20 extra lines) instead of passing an anonymous ctx literal;
that variant measures 78 vs 100 = **−22%**, under the bar. `ctx:
anytype` exists precisely so callers can pass struct literals — the
lean form is the intended usage, but ctx factoring is the dominant
cost on complex rows, not the markup.

## Verdict

Precommitted criteria:

1. **≥25% less handwritten view code than `h.*` across both examples** —
   **met**: −69% (post form), −35% (comment row), −36% aggregate.
2. **SSR and patch parity** — **met**: byte-identical SSR, snapshot
   ops, and `PatchLog` streams across all steps and all three
   implementations.
3. **Type-error diagnosis tolerable** — **met with caveat**: parse
   diagnostics are excellent (`path:line:col`, clean messages); type
   errors inside holes cite `gen/*.zig` with the verbatim expression,
   one hop from the `.zsx` source.

**Recommendation: adopt-worthy.** `.zsx` lowers to `forest.el`,
preserves `Bound.live` (unlike `h.*` for raw store bindings), cuts
handwritten view code by ~⅓ on realistic markup, and its failure
modes are clean. Caveats for a real adoption: no entities, no
components/loops in markup, ctx plumbing dominates on data-heavy rows
(keep holes thin or ctx rich — the metric is sensitive to that
choice), and generated-file type errors need the header-comment hop.
The prior "codegen rejected" note in ARCHITECTURE.md should be
revisited: the parser is ~700 lines of plain Zig, deterministic,
checked-in output, `zig build zsx-check` freshness — the complexity
cost the old note feared is real but bounded, and the parity/live-
binding evidence removes the semantic objection.
