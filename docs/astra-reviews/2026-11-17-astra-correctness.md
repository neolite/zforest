<!-- Astra (gpt-6-astra) review: framework correctness — module identity / diamond propagation / memory / loop safety across zforest + zforest-examples. Session 01a1e850-6c68-7480-9504-2f4609590233. Complements 2026-11-17-framework-correctness.md (Devin pass). -->

Static review completed across both repositories. **No files were modified; builds and tests were not run.** Findings below are supported by source-level execution paths, not live reproductions.

**Critical:** None confirmed.

**High**

1. **Request-controlled session keys can terminate the server.**  
   [http.zig:111](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:111)  
   `lookup()` uses a 320-byte buffer; `keyInto()` panics when `token.len + 1 + route.len` exceeds it. Cookie tokens and the `/events?r=` route are not length-validated before lookup. An oversized cookie on an otherwise valid GET, or an oversized SSE route, reaches this panic without authentication. Reject oversized inputs before constructing the key, or allocate the key dynamically.

2. **Response cookie headers can reference freed or concurrently overwritten session memory.**  
   [http.zig:368](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:368), [http.zig:619](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:619)  
   `handle()` appends borrowed `s.out_cookie` and `s.outCookie2()` slices to response headers, then releases the mutex. `req.respond()` consumes them afterward. Another worker can evict the session or overwrite its cookie buffers in that interval. This creates a use-after-free/data race on response bytes, including board authentication cookies. Duplicate these values into the request arena while holding the lock.

3. **Removing an island can free branch trees while leaving their subscriptions alive.**  
   [dom.zig:157](/Users/rafkat/Apps/tmp/zforest/src/forest/dom.zig:157), [view.zig:1291](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:1291), [view.zig:1044](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:1044)  
   Cleanup identifies descendants solely through ID prefixes, but nodes inside an island may use absolute `.id` values. For example, an island under `row/island` containing a live variant with `.id = "branch"` registers two unrelated ID prefixes. Removing `row` destroys the island’s arena but does not unsubscribe `"branch"`. Its binder retains `variant_nodes` pointing into that freed arena; a subsequent key notification dereferences them. Ownership needs explicit subtree membership, or absolute descendants must be rejected/enforced consistently. This is a supported-API construction; I did not find this exact arrangement in the shipped apps.

4. **User-created comment depth is unbounded and reaches recursive rendering.**  
   [model.zig:843](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/entities/model.zig:843), [components.zig:367](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/shared/components.zig:367)  
   `addComment()` checks that the parent exists in the same post, but imposes no depth limit. `commentNode()` recursively constructs every descendant, followed by recursive Forest serialization/diffing. Repeated valid replies can therefore create a persisted chain that exhausts the worker stack when rendered. New-parent validation prevents cycles, but does not bound recursion depth.

**Medium**

5. **Samples can observe a partially propagated diamond.**  
   [engine.zig:157](/Users/rafkat/Apps/tmp/zforest/src/zefx/engine.zig:157), [sample.zig:140](/Users/rafkat/Apps/tmp/zforest/src/zefx/sample.zig:140)  
   The engine drains the entire sample queue before re-settling stores. Consider two samples on one clock: the first writes store `a`; the second samples `{a, doubled}`, where `doubled = a.map(...)`. The first changes `a` immediately, but its derived propagation waits until the queue finishes. The second therefore reads new `a` with old `doubled`. This violates the documented settled-source guarantee. Re-settle between sample writes and dependent reads, or define and implement coherent snapshot semantics.

6. **Nested keyed-list tracking survives subtree removal.**  
   [dom.zig:310](/Users/rafkat/Apps/tmp/zforest/src/forest/dom.zig:310), [components.zig:372](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/shared/components.zig:372)  
   `removeTracked()` removes texts, attributes, conditional state and bindings, but never removes entries from `orders`. Every board comment seeds a nested `cm-N/kids` order. Removing comments leaves those allocations behind until the whole Dom is destroyed. Descendants with absolute IDs also escape prefix cleanup. A long-lived render group can consequently retain state proportional to deleted comments, rather than its current DOM.

7. **Saving an empty todo title deletes the row without advancing the revision.**  
   [todo/app.zig:503](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/todo/app.zig:503)  
   The empty `edit_save` branch removes the todo and persists the deletion, then returns before `s.bumpSeq()`. The after-flush render can generate removal patches, but they carry the previous revision, which connected clients discard. The derived remaining count also does not recompute. The database and browser diverge after an ordinary supported action.

8. **A rejected first action permanently loses the newly minted persistence cookie.**  
   [todo/app.zig:204](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/todo/app.zig:204), [todo/app.zig:403](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/todo/app.zig:403), [http.zig:345](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:345)  
   Dispatch mints `client_id` and stages `Set-Cookie` before action validation. On validation failure, the server returns before emitting that header. The next dispatch clears `out_cookie`, while `ensureIdentity()` sees an existing ID and does not stage it again. Later successful todos are saved under an identity the browser never received; eviction/restart makes them inaccessible to that browser. Board’s first-contact `zfxu` path has the same sequencing defect.

9. **Board auth-dependent structure is invisible to the diff.**  
   [pages/_layout.zig:40](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/pages/_layout.zig:40), [components.zig:202](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/shared/components.zig:202), [view.zig:757](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:757)  
   Login/logout links, logout buttons and ownership-dependent delete buttons use ordinary Zig conditionals producing unkeyed children. Forest does not reconcile insertion/removal of ordinary children. A clone-fork after login updates bound `#who`, but cannot replace the auth controls; logout can leave delete controls visible. The navbar is also outside a keyed snapshot replacement, so reconnecting does not repair it. These branches need `when`/`variant` or another structural boundary.

10. **Deleting a post does not replace an already-open thread with its not-found view.**  
    [pages/t/[post]/index.zig:22](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/pages/t/[post]/index.zig:22), [components.zig:395](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/shared/components.zig:395)  
    Once the post disappears, the page returns a new ordinary `<p id="not-found">` instead of its previous fragment. There is no conditional anchor or keyed wrapper around that transition. Diff neither removes the old thread nor creates the paragraph; snapshot operations likewise cannot reconstruct this missing scaffold. The scope bump occurs, but the browser continues displaying deleted content. Comment-permalink deletion has the analogous structural problem.

11. **Cascade deletions are not atomic across SQLite and the in-memory model.**  
    [model.zig:959](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/entities/model.zig:959), [model.zig:1030](/Users/rafkat/Apps/tmp/zforest-examples/src/apps/board/entities/model.zig:1030)  
    Post/comment deletion executes multiple independently committed DELETE statements, updating memory only after all succeed. If a later statement fails, earlier deletions remain committed while the function returns with old in-memory rows/indexes and no corresponding notification. Wrap the database cascade in a transaction, then update memory after commit.

12. **Queued actions can be sent to the wrong route-session after navigation.**  
    [client.js:246](/Users/rafkat/Apps/tmp/zforest/src/client.js:246), [client.js:376](/Users/rafkat/Apps/tmp/zforest/src/client.js:376)  
    `send()` captures the action payload immediately, but reads global `route` and `csrfToken` only when its queued callback executes. Soft navigation changes both without draining or invalidating the queue. An action queued on route A can therefore execute against route B’s session, potentially mutating the wrong per-route state. Capture routing/authentication context alongside the payload.

13. **Browser Back/Forward leaves the displayed page and server route out of sync.**  
    [client.js:379](/Users/rafkat/Apps/tmp/zforest/src/client.js:379)  
    Soft navigation calls `history.pushState()`, but the client has no `popstate` handler. Back/Forward changes the URL without changing `<main>`, the SSE subscription or the action route. Subsequent actions still target the page that was displayed before the history traversal.

14. **The client silently rejects valid server-generated attribute updates.**  
    [client.js:10](/Users/rafkat/Apps/tmp/zforest/src/client.js:10), [client.js:99](/Users/rafkat/Apps/tmp/zforest/src/client.js:99), [view.zig:798](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:798)  
    Forest emits arbitrary bound attributes, while the client accepts only eight names. A bound `href`, `title`, `aria-*` or other `data-*` attribute renders correctly in SSR but stops updating afterward. Revisions still advance, and snapshots use the same rejecting handler. The framework needs a consistent attribute contract on both sides.

**Low**

15. **The session-eviction test itself reads freed memory.**  
    [http.zig:729](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:729)  
    The test compares `a2.incarnation` with `a.incarnation` after the fill loop has evicted and destroyed `a`. This can fault or compare against reused allocation contents. Save the original incarnation value before eviction.

16. **Framework test optimization settings are ignored for the main modules.**  
    [build.zig:29](/Users/rafkat/Apps/tmp/zforest/build.zig:29), [build.zig:80](/Users/rafkat/Apps/tmp/zforest/build.zig:80)  
    `optimize` is read, but passed only to the generator/scaffolder modules. The framework modules used as test roots omit it. Consequently, selecting release optimization does not apply it to the core framework test binaries.

**Type identity and lifecycle conclusions**

- **No relative cross-module import violation found.** The import audit covered 311 import occurrences outside the separately inspected generator/scaffolder templates. Framework-internal relative imports remain within their module; app shims re-export named `zmeta`.
- **The diamond wiring is sound in the current graph.** Examples obtain the same dependency-owned `*Module` objects through `dep.module(...)`. `History`, `Dom`, and reactive types are not reconstructed through alternate source roots. The hand-declared board Session is a distinct application type by design, not a duplicate framework compilation.
- **Generator/scaffolder output preserves that boundary.** Generated routes import the app-local shim; the scaffolded shim imports named `zmeta`. No emitted relative import reaches framework implementation files.
- **No duplicate SQLite linkage found.** The amalgamation is attached once to `zdb`; consumers reuse that module. Separate executable/test binaries each linking SQLite is expected.
- **Ordinary teardown paths look consistent.** Dom bindings unsubscribe before engine destruction; subscription handles check generations; PatchLog copies strings; History bounds retained bytes/entries and duplicates fetched payloads. Inspected SQLite call sites finalize statements and copy retained column strings.
- **Settle-loop termination is not bounded.** A watcher that continually toggles its source, or a cyclic forwarding graph, never returns from `flush()`. Equality suppression does not stop alternating values. No such cycle was found in the shipped apps; this remains an explicit framework limitation.
- **SSE and render-group paths:** polling releases the mutex before network writes, checks session incarnation, and handles incompatible group transitions through epochs. Clone-fork copies Dom/history before releasing the source group. No additional lineage or teardown defect was confirmed there. However, `serve()` swallows every `accept()` error with `catch continue`, including cancellation, so cancellation does not reach its deferred worker/session cleanup.
- **Middleware ordering is finite and direct:** generated ancestor middleware calls precede page preparation; no recursive ordering cycle was found.