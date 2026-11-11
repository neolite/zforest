// zforest client — minimal DOM patch renderer over SSE. No framework.
(function () {
  "use strict";

  var ATTR_WHITELIST = {
    checked: true,
    value: true,
    "data-active": true,
    hidden: true,
    disabled: true,
    "class": true,
    type: true,
  };

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
        break;
      case "attr":
        el = document.getElementById(p.id);
        if (!el || !ATTR_WHITELIST[p.name]) return;
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

  function applyBatch(resp) {
    if (resp && resp.patches) {
      for (var i = 0; i < resp.patches.length; i++) applyPatch(resp.patches[i]);
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

  function stashDraft() {
    try {
      var inp = document.getElementById("new-title");
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

  var input = document.getElementById("new-title");
  var addBtn = document.querySelector("#add-form button");
  // Actions are disabled until the first SSE snapshot confirms the stream.
  input.disabled = true;
  addBtn.disabled = true;

  function applySnapshot(d) {
    document.getElementById("list").innerHTML = d.html; // trusted, escaped
    document.getElementById("count").textContent = d.count;
    var btns = document.querySelectorAll("[data-filter]");
    for (var i = 0; i < btns.length; i++) {
      if (btns[i].getAttribute("data-filter") === d.filter) {
        btns[i].setAttribute("data-active", "1");
      } else {
        btns[i].removeAttribute("data-active");
      }
    }
    lastRev = d.rev;
    if (!ready) {
      ready = true;
      input.disabled = false;
      addBtn.disabled = false;
      input.focus();
    }
  }

  var es = new EventSource("/events");
  es.addEventListener("snapshot", function (ev) {
    applySnapshot(JSON.parse(ev.data));
  });
  es.addEventListener("patch", function (ev) {
    var d = JSON.parse(ev.data);
    if (d.rev > lastRev) { // ignore obsolete batches
      applyBatch(d);
      lastRev = d.rev;
    }
  });
  es.addEventListener("session_expired", function () {
    es.close();
    reloadOnce();
  });
  // EventSource auto-reconnects on any drop; every fresh connection gets a
  // full snapshot first, which always resyncs the DOM.

  // Serialize actions through a promise queue so revisions stay ordered.
  // The response is an ACK {rev} only — patches arrive via the SSE stream.
  var queue = Promise.resolve();

  function send(action, extra) {
    var payload = { action: action };
    if (extra) for (var k in extra) payload[k] = extra[k];
    var job = queue.then(function () {
      return fetch("/action", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-zforest-csrf": csrfToken,
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

  document.addEventListener("DOMContentLoaded", function () {
    var form = document.getElementById("add-form");
    var list = document.getElementById("list");

    // Restore a draft stashed before a session-loss reload.
    try {
      var draft = sessionStorage.getItem("zforest-draft");
      if (draft) {
        input.value = draft;
        sessionStorage.removeItem("zforest-draft");
      }
    } catch (_) {}

    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (!ready) return;
      var v = input.value;
      if (!v.trim()) return;
      send("add", { value: v })
        .then(function () {
          // Clear only on success, and only if the user hasn't typed more.
          if (input.value === v) input.value = "";
          input.focus();
        })
        .catch(function (e) {
          fail(e); // rejected: draft stays in the input
        });
    });

    list.addEventListener("click", function (ev) {
      var btn = ev.target.closest("[data-delete]");
      if (btn) send("delete", { id: Number(btn.getAttribute("data-delete")) }).catch(function (e) { fail(e); });
    });

    list.addEventListener("change", function (ev) {
      var cb = ev.target.closest("[data-toggle]");
      if (!cb) return;
      // Explicit desired state, not a blind toggle.
      var want = cb.checked;
      send("set_checked", { id: Number(cb.getAttribute("data-toggle")), value: want ? "true" : "false" }).catch(function (e) {
        fail(e, function () {
          cb.checked = !want;
        });
      });
    });

    document.querySelector(".filters").addEventListener("click", function (ev) {
      var b = ev.target.closest("[data-filter]");
      if (b) send("filter", { value: b.getAttribute("data-filter") }).catch(function (e) { fail(e); });
    });
  });
})();
