// zforest client — app-agnostic DOM patch renderer over SSE. No framework.
// The server drives the DOM with a declarative view: elements declare an
// action via data-on-<event> attributes and a payload via data-arg. This
// file contains no app knowledge — only the wire protocol below.
(function () {
  "use strict";

  // Only these attributes may be patched by attr ops; data-on-*/data-arg
  // and friends are static markup and never appear here.
  var ATTR_WHITELIST = {
    checked: true,
    value: true,
    "data-active": true,
    hidden: true,
    disabled: true,
    "class": true,
    type: true,
    points: true,
  };

  // Comment anchors for "when" ops: id -> {start, end} Comment nodes.
  // Marker comments are never removed while their anchor is live, so a
  // hit is cached forever; entries whose markers were replaced (branch
  // markup can carry nested anchors) are re-found via isConnected.
  var whenAnchors = {};

  function whenRange(id) {
    var r = whenAnchors[id];
    if (r && r.start.isConnected && r.end.isConnected) return r;
    var start = null;
    var want = "z-when:" + id;
    var wantEnd = "/z-when:" + id;
    var w = document.createTreeWalker(document.body, NodeFilter.SHOW_COMMENT);
    for (var n = w.nextNode(); n; n = w.nextNode()) {
      var v = (n.nodeValue || "").trim();
      if (!start) {
        if (v === want) start = n;
      } else if (v === wantEnd) {
        whenAnchors[id] = { start: start, end: n };
        return whenAnchors[id];
      }
    }
    // Don't cache a miss — the anchor may be mounted by a later op.
    delete whenAnchors[id];
    return null;
  }

  function applyPatch(p) {
    var el;
    switch (p.op) {
      case "create": {
        var parent = document.getElementById(p.parent);
        if (!parent) return;
        var before = p.before ? document.getElementById(p.before) : null;
        var tpl = document.createElement("template");
        tpl.innerHTML = p.html; // trusted server-generated, data escaped
        var node = tpl.content.firstElementChild;
        if (node) parent.insertBefore(node, before);
        break;
      }
      case "remove":
        el = document.getElementById(p.id);
        if (el) el.remove();
        break;
      case "move": {
        var par = document.getElementById(p.parent);
        el = document.getElementById(p.id);
        var ref = p.before ? document.getElementById(p.before) : null;
        if (par && el) par.insertBefore(el, ref);
        break;
      }
      case "text":
        el = document.getElementById(p.id);
        if (el) el.textContent = p.text;
        else console.debug("zforest: text target missing: " + p.id);
        break;
      case "html":
        el = document.getElementById(p.id);
        if (el) el.innerHTML = p.html; // trusted server-generated, data escaped
        else console.debug("zforest: html target missing: " + p.id);
        break;
      case "when": {
        // Idempotent "set content strictly between the z-when markers".
        var range = whenRange(p.id);
        if (!range) break;
        var node = range.start.nextSibling;
        while (node && node !== range.end) {
          var next = node.nextSibling;
          node.parentNode.removeChild(node);
          node = next;
        }
        var wtpl = document.createElement("template");
        wtpl.innerHTML = p.html; // trusted server-generated, data escaped
        range.end.before(wtpl.content);
        break;
      }
      case "attr":
        el = document.getElementById(p.id);
        if (!el || !ATTR_WHITELIST[p.name]) {
          if (!el) console.debug("zforest: attr target missing: " + p.id);
          return;
        }
        if (p.value === null) {
          el.removeAttribute(p.name);
          if (p.name === "checked") el.checked = false;
        } else {
          el.setAttribute(p.name, p.value);
          if (p.name === "checked") el.checked = true;
          if (p.name === "value") el.value = p.value;
        }
        break;
    }
  }

  function applyOps(ops) {
    if (!ops) return;
    for (var i = 0; i < ops.length; i++) {
      try {
        applyPatch(ops[i]);
      } catch (e) {
        console.error("zforest: op failed", ops[i], e);
      }
    }
  }

  function showError(msg) {
    var el = document.getElementById("error");
    if (!el) {
      el = document.createElement("div");
      el.id = "error";
      el.setAttribute("role", "alert");
      var main = document.querySelector(".app");
      if (main) main.insertBefore(el, main.children[1]);
    }
    el.textContent = msg;
    el.hidden = !msg;
  }

  // The stashed draft lives in the first editable named input of a
  // [data-on-submit] form — generic, and enough to preserve the
  // pre-reload behaviour. Hidden inputs carry fixed payload values
  // (board slug, post id), never user drafts.
  function draftInput() {
    return document.querySelector("[data-on-submit] [name]:not([type=hidden])");
  }

  function stashDraft() {
    try {
      var inp = draftInput();
      if (inp && inp.value) sessionStorage.setItem("zforest-draft", inp.value);
    } catch (_) {}
  }

  // Reload once on session loss; guard against reload loops if the session
  // keeps expiring (e.g. server refuses to persist a cookie).
  function reloadOnce() {
    stashDraft();
    try {
      var last = Number(sessionStorage.getItem("zforest-reload") || 0);
      if (Date.now() - last < 10000) {
        showError("session expired; reload the page");
        return;
      }
      sessionStorage.setItem("zforest-reload", String(Date.now()));
    } catch (_) {}
    location.reload();
  }

  var csrfMeta = document.querySelector('meta[name="zforest-csrf"]');
  var csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : "";
  var revMeta = document.querySelector('meta[name="zforest-rev"]');
  var lastRev = revMeta ? Number(revMeta.getAttribute("content")) || 0 : 0;
  var ready = false;

  // Controls inside [data-on-submit] forms stay disabled until the first
  // SSE snapshot confirms the stream.
  function gatedControls() {
    return document.querySelectorAll("[data-on-submit] input, [data-on-submit] button");
  }
  var gated = gatedControls();
  for (var gi = 0; gi < gated.length; gi++) gated[gi].disabled = true;

  function applySnapshot(d) {
    applyOps(d.ops); // full-state dump: html + attr + text ops
    lastRev = d.rev;
    if (!ready) {
      ready = true;
      var ctrls = gatedControls();
      for (var i = 0; i < ctrls.length; i++) ctrls[i].disabled = false;
      var af = document.querySelector("[data-on-submit] [autofocus]");
      if (af) af.focus();
    }
  }

  // Sessions are keyed (cookie token, route) server-side: the stream and
  // every action must name this page's route so they hit the right view.
  var route = location.pathname;
  var es = null;

  function connect() {
    if (es) es.close();
    es = new EventSource("/events?r=" + route);
    es.addEventListener("snapshot", function (ev) {
      var d;
      try {
        d = JSON.parse(ev.data);
      } catch (e) {
        console.error("zforest: bad snapshot json", e);
        return;
      }
      applySnapshot(d);
    });
    es.addEventListener("patch", function (ev) {
      var d;
      try {
        d = JSON.parse(ev.data);
      } catch (e) {
        console.error("zforest: bad patch json", e);
        return;
      }
      if (d.rev > lastRev) { // ignore obsolete batches
        applyOps(d.patches);
        lastRev = d.rev;
      } else {
        console.debug("zforest: skipping patch rev " + d.rev + " (lastRev " + lastRev + ")");
      }
    });
    es.addEventListener("session_expired", function () {
      es.close();
      reloadOnce();
    });
  }
  // EventSource auto-reconnects on any drop; every fresh connection gets a
  // full snapshot first, which always resyncs the DOM.
  connect();

  // Serialize actions through a promise queue so revisions stay ordered.
  // The response is an ACK {rev} only — patches arrive via the SSE stream.
  var queue = Promise.resolve();

  function send(action, extra) {
    var payload = { action: action };
    if (extra) for (var k in extra) {
      if (extra[k] !== null && extra[k] !== undefined) payload[k] = extra[k];
    }
    var job = queue.then(function () {
      return fetch("/action", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-zforest-csrf": csrfToken,
          "x-zforest-route": route,
        },
        body: JSON.stringify(payload),
        credentials: "same-origin",
      }).then(function (r) {
        if (r.status === 403) {
          // Session lost (server restart/eviction) or token mismatch:
          // reload — GET / issues a fresh cookie, token, and snapshot.
          reloadOnce();
          return new Promise(function () {}); // suspend; page is reloading
        }
        if (!r.ok) {
          return r.text().then(function (body) {
            throw new Error(action + " failed: HTTP " + r.status + " " + body);
          });
        }
        return r.json();
      }).then(function (ack) {
        // ACK means accepted, not rendered — the patch arrives via SSE.
        showError("");
      });
    });
    // Keep the queue alive even when an action fails. No auto-retry —
    // a network-ambiguous POST must not be duplicated.
    queue = job.catch(function () {});
    return job;
  }

  function fail(msg, revert) {
    var text = String(msg && msg.message ? msg.message : msg);
    console.error(text);
    showError(text);
    if (revert) revert();
  }

  // Delegated listeners: any element may declare data-on-<event> plus an
  // optional data-arg payload; the listener turns it into an action POST.
  document.addEventListener("click", function (ev) {
    var el = ev.target.closest("[data-on-click]");
    if (!el) return;
    send(el.getAttribute("data-on-click"), { arg: el.getAttribute("data-arg") }).catch(fail);
  });

  document.addEventListener("dblclick", function (ev) {
    var el = ev.target.closest("[data-on-dblclick]");
    if (!el) return;
    send(el.getAttribute("data-on-dblclick"), { arg: el.getAttribute("data-arg") }).catch(fail);
  });

  document.addEventListener("change", function (ev) {
    var el = ev.target.closest("[data-on-change]");
    if (!el) return;
    var isBox = el.type === "checkbox";
    // Explicit desired state for checkboxes, not a blind toggle.
    var desired = isBox ? el.checked : undefined;
    send(el.getAttribute("data-on-change"), {
      arg: el.getAttribute("data-arg"),
      value: isBox ? String(el.checked) : el.value,
    }).catch(function (e) {
      fail(e, function () { if (isBox) el.checked = !desired; });
    });
  });

  document.addEventListener("submit", function (ev) {
    var form = ev.target.closest("[data-on-submit]");
    if (!form) return;
    ev.preventDefault();
    if (!ready) return;
    var inputs = form.querySelectorAll("[name]");
    var fields = {};
    for (var i = 0; i < inputs.length; i++) {
      fields[inputs[i].getAttribute("name")] = inputs[i].value;
    }
    send(form.getAttribute("data-on-submit"), { fields: fields }).then(function () {
      // Clear only editable fields still equal to what was sent — hidden
      // inputs hold fixed payload values (board/post/parent ids) that
      // must survive for the next submit.
      for (var i = 0; i < inputs.length; i++) {
        if (inputs[i].type === "hidden") continue;
        var n = inputs[i].getAttribute("name");
        if (inputs[i].value === fields[n]) inputs[i].value = "";
      }
      var af = form.querySelector("[autofocus]") || form.querySelector("input:not([type=hidden]), textarea");
      if (af) af.focus();
    }).catch(fail);
  });

  // ── soft navigation ─────────────────────────────────────────
  // Internal links swap <main> + reconnect the stream instead of a
  // full reload. The GET still hits the server — it mints/looks up
  // the route-session and returns SSR HTML; we lift <main>, <title>
  // and the CSRF meta out of the response, pushState the URL, then
  // reopen EventSource: its snapshot reconciles any drift (snapshot
  // ops are state dumps — idempotent over matching markup).
  // Opt out per-link with data-reload, per-gesture with modifier keys.
  var navSeq = 0;

  function softNav(url, href) {
    var my = ++navSeq;
    stashDraft();
    fetch(href, { credentials: "same-origin" }).then(function (r) {
      if (!r.ok) {
        location.href = href; // 404/500 → let the browser navigate
        return null;
      }
      return r.text();
    }).then(function (html) {
      if (html === null || my !== navSeq) return; // superseded or failed
      var doc = new DOMParser().parseFromString(html, "text/html");
      var fresh = doc.querySelector("main");
      var cur = document.querySelector("main");
      if (!fresh || !cur) {
        location.href = href;
        return;
      }
      cur.innerHTML = fresh.innerHTML;
      var t = doc.querySelector("title");
      if (t) document.title = t.textContent;
      var cm = doc.querySelector('meta[name="zforest-csrf"]');
      var lm = document.querySelector('meta[name="zforest-csrf"]');
      if (cm && lm) {
        csrfToken = cm.getAttribute("content");
        lm.setAttribute("content", csrfToken);
      }
      route = url.pathname;
      lastRev = 0; // new route-session numbers revisions independently
      ready = false; // re-gate submit controls until the snapshot lands
      history.pushState(null, "", href);
      window.scrollTo(0, 0);
      connect();
    }).catch(function () {
      location.href = href;
    });
  }

  document.addEventListener("click", function (ev) {
    if (ev.defaultPrevented || ev.button !== 0) return;
    if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
    var a = ev.target.closest("a[href]");
    if (!a || a.hasAttribute("download") || a.target) return;
    if (a.hasAttribute("data-reload")) return;
    var href = a.getAttribute("href");
    if (!href || href.charAt(0) !== "/") return;
    var url;
    try {
      url = new URL(href, location.href);
    } catch (e) {
      return;
    }
    if (url.origin !== location.origin) return;
    if (url.pathname === location.pathname && url.search === location.search) return;
    ev.preventDefault();
    softNav(url, href);
  });

  // Restore a draft stashed before a session-loss reload.
  document.addEventListener("DOMContentLoaded", function () {
    try {
      var draft = sessionStorage.getItem("zforest-draft");
      if (draft) {
        var inp = draftInput();
        if (inp) inp.value = draft;
        sessionStorage.removeItem("zforest-draft");
      }
    } catch (_) {}
  });
})();
