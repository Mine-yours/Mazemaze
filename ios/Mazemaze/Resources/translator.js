// Mazemaze page script. Runs in its own WKContentWorld: page scripts cannot see this code, its
// globals or the native message handler. It only asks Swift to translate text (Swift owns the
// network, the token, the ratio and the allow-list) and rewrites the page DOM with safe DOM APIs
// (never innerHTML). Original text nodes are kept, so everything can be restored exactly.
(function () {
  "use strict";
  if (window.__mazemaze) return;

  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mazemaze;
  if (!bridge) return;

  // ---- constants ----------------------------------------------------------------------------
  var CHUNK_TARGET = 160;            // one request is about one model call (the server batches ~150 chars per call)
  var MAX_SINGLE = 320;              // a single sentence longer than this is split at "、"; longer than this without one is skipped
  var MIN_JA_CHARS = 8;              // a block needs at least this many Japanese characters
  var MAX_REQUESTS_PER_PAGE = 1000;   // safety net only; the native side enforces the user-visible limit
  var MAX_BLOCKS = 600;
  var MAX_NODE_TRIES = 2;
  var MAX_SCAN_NODES = 20000;
  var QUIET_MS = 300, MAX_QUIET_WAIT_MS = 2500;   // start once the DOM has been calm for QUIET_MS (hydration), at most this long
  var SCAN_DEBOUNCE_MS = 250;
  var SWEEP_MS = 2000;
  var PLACEHOLDER = "\u200B";        // keeps the original text node non-empty (normalize() removes empty ones)
  var JA = /[぀-ヿ㐀-䶿一-鿿ｦ-ﾟ]/g;

  var SKIP_SELECTOR = [
    "script", "style", "noscript", "template", "textarea", "input", "select", "option", "button", "a",
    "code", "pre", "kbd", "samp", "svg", "math", "iframe", "object", "embed", "canvas", "video", "audio",
    "head", "title", "nav", "[hidden]", "[aria-hidden='true']", "[translate='no']", ".notranslate",
    "[contenteditable='']", "[contenteditable='true']", "[contenteditable='plaintext-only']",
    "[role='textbox']", "[role='button']", "[role='link']", "[role='menuitem']", "[role='tab']",
    "[role='navigation']", "[role='dialog']", "[role='alertdialog']", "ruby", "rt", "rp", "label", "form",
    "[data-mazemaze]", "[data-mazemaze-ui]"
  ].join(",");
  var BLOCK_SELECTOR = "p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,figcaption,summary,div,section,article,main,body";
  // Post text: the classic markup has data-testid; the newer (logged-out) markup only has a div[dir=auto] inside the <article>.
  // Names, handles and times are links (skipped as "a"), buttons and menus are skipped too.
  var X_ROOTS = "[data-testid='tweetText'],[data-testid='UserDescription'],article div[dir='auto']";
  // Direct messages must never be sent for translation, even if they reuse the tweet markup.
  var X_EXCLUDE = "[data-testid='DMDrawer'],[data-testid*='DmActivity'],[data-testid*='message' i],[data-testid*='conversation' i],[aria-label*='ダイレクトメッセージ'],[aria-label*='Direct Message' i]";

  // ---- state --------------------------------------------------------------------------------
  var state = {
    gen: -1, enabled: false, profile: "generic", blocked: null, requests: 0,
    running: false, started: false, inflight: false, stopped: null, reqId: 0, backoff: 0, lastMutation: 0, resyncing: false, bridgeRejects: 0, paused: false
  };
  var records = new Set();            // active replacements {node, original, wrapper}
  var byNode = new Map();             // text node -> record
  var nodeState = new WeakMap();      // text node -> {tries, status: "failed"}
  var pendingInfo = new WeakMap();    // text node -> {node, original, lead, trail, parts, partPieces, remaining}
  var sources = new WeakMap();        // english span -> original Japanese
  var registered = new Map();         // block element -> true
  var visible = new Set();            // block elements near the viewport
  var reappear = new WeakMap();       // text node -> times the page overwrote our change
  var partial = new Set();            // infos with some parts translated and some still pending
  var io = null, mo = null, popover = null;
  var scanTimer = null, pumpTimer = null, sweepTimer = null, startTimer = null;
  var scanQueue = new Set();

  // Timing, exposed through status() for measurement (no page text, only counts and milliseconds).
  var T0 = performance.now();
  var metrics = { startedAt: null, firstSendAt: null, firstApplyAt: null, maxVisible: 0, reqs: [] };
  function since() { return Math.round(performance.now()); }   // ms since the navigation started

  // ---- helpers ------------------------------------------------------------------------------
  function scalarLength(s) { var n = 0; for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); if (c >= 0xD800 && c <= 0xDBFF) i++; n++; } return n; }
  function jaCount(s) { var m = s.match(JA); return m ? m.length : 0; }
  function isJapaneseEnough(core) {
    var t = core.replace(/\s+/g, "");
    var n = jaCount(t);
    return n >= 4 && t.length >= 6 && n / t.length >= 0.3;
  }
  function setImportant(el, props) { for (var k in props) el.style.setProperty(k, props[k], "important"); }

  function rootSelectorFor(node) {
    var parent = node.parentElement;
    if (!parent) return null;
    if (state.profile === "x") return parent.closest(X_ROOTS);
    return parent.closest("article,main,[role='main']") || (document.querySelector("article,main,[role='main']") ? null : document.body);
  }

  // The nearest element that makes text off limits (links, buttons, dialogs, ...). On X the whole post card is a
  // div[role=link] (the card opens the post), so that one wrapper does not count when it merely contains the
  // post text; real links (<a>), buttons, dialogs and aria-hidden regions still do.
  // Only the outermost role=link around one <article> (the post card itself; it is either just inside the article or
  // just outside it). A role=link nested in another one (a quoted post's card, a profile row) stays off limits.
  function isOuterPostCard(el) {
    var outer = el.parentElement ? el.parentElement.closest("[role='link']") : null;
    if (outer) return false;
    var art = el.closest("article") || el.querySelector("article");
    return !!art && (art.contains(el) || el.contains(art));
  }

  function skippedByPage(parent) {
    var el = parent.closest(SKIP_SELECTOR);
    if (state.profile === "x" && el) {
      var root = parent.closest(X_ROOTS);
      while (el && root && el !== root && el.tagName !== "A" && el.getAttribute("role") === "link" && el.contains(root) && !root.contains(el) && isOuterPostCard(el)) {
        el = el.parentElement ? el.parentElement.closest(SKIP_SELECTOR) : null;
      }
    }
    return !!el;
  }

  function isCandidateNode(node) {
    if (node.nodeType !== 3) return false;
    var value = node.nodeValue;
    if (!value || !/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uff66-\uff9f]/.test(value)) return false;   // cheap Japanese pre-check
    var st = nodeState.get(node);
    if (st && st.status === "failed") return false;      // cheap checks first
    if (byNode.has(node)) return false;
    var parent = node.parentElement;
    if (!parent || !node.isConnected) return false;
    if (skippedByPage(parent)) return false;
    if (parent.isContentEditable) return false;
    if (state.profile === "x" && parent.closest(X_EXCLUDE)) return false;
    if (!rootSelectorFor(node)) return false;
    // A neighbouring text node could be merged with our placeholder by normalize(); flex/grid
    // parents would lay the placeholder out as a separate item. Leave those alone.
    var prev = node.previousSibling, next = node.nextSibling;
    if ((prev && prev.nodeType === 3) || (next && next.nodeType === 3)) return false;
    var display = window.getComputedStyle(parent).display;
    if (display.indexOf("flex") >= 0 || display.indexOf("grid") >= 0) return false;
    return true;
  }

  function blockOf(node) {
    var parent = node.parentElement;
    if (state.profile === "x") return parent.closest(X_ROOTS);
    return parent.closest(BLOCK_SELECTOR) || document.body;
  }

  function hasPasswordField() { return !!document.querySelector("input[type='password']"); }

  // ---- bridge -------------------------------------------------------------------------------
  function ask(message) {
    try { return Promise.resolve(bridge.postMessage(message)); } catch (e) { return Promise.reject(e); }
  }

  // ---- translation of one group of items -----------------------------------------------------
  // Parts: roughly CHUNK_TARGET characters, cut at sentence ends (then at "、" for a very long sentence).
  // Their concatenation is always exactly `core`; null if some piece still cannot be cut small enough.
  function splitParts(core) {
    if (scalarLength(core) <= CHUNK_TARGET) return [core];
    var pieces = core.match(/[^。！？!?\n]*[。！？!?\n]+|[^。！？!?\n]+$/g);
    if (!pieces || pieces.join("") !== core) return null;
    var small = [];
    for (var i = 0; i < pieces.length; i++) {
      if (scalarLength(pieces[i]) <= MAX_SINGLE) { small.push(pieces[i]); continue; }
      var sub = pieces[i].match(/[^、]*、|[^、]+$/g);
      if (!sub || sub.join("") !== pieces[i]) return null;
      for (var k = 0; k < sub.length; k++) { if (scalarLength(sub[k]) > MAX_SINGLE) return null; small.push(sub[k]); }
    }
    var parts = [], cur = "";
    for (var m = 0; m < small.length; m++) {
      if (cur && scalarLength(cur) + scalarLength(small[m]) > CHUNK_TARGET) { parts.push(cur); cur = ""; }
      cur += small[m];
    }
    if (cur) parts.push(cur);
    return parts.join("") === core ? parts : null;
  }

  function infoFor(node) {
    var info = pendingInfo.get(node);
    if (info && info.original === node.nodeValue) return info;
    var original = node.nodeValue;
    var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(original);
    var core = m[2];
    if (!core || !isJapaneseEnough(core)) return null;
    var parts = splitParts(core);
    if (!parts) return null;
    info = { node: node, original: original, lead: m[1], trail: m[3], parts: parts, done: new Array(parts.length), remaining: parts.length, record: null, block: null };
    pendingInfo.set(node, info);
    return info;
  }

  function textNodesOf(block) {
    var out = [];
    var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
    var n, seen = 0;
    while ((n = walker.nextNode()) && seen++ < MAX_SCAN_NODES) {
      if (!isCandidateNode(n)) continue;
      if (blockOf(n) !== block) continue;     // nested blocks are handled on their own
      out.push(n);
    }
    return out;
  }

  // The next request for a block: pending parts (in document order) joined with "\n", about CHUNK_TARGET
  // characters. Nodes that are already partly translated keep contributing their remaining parts.
  function nextGroup(block) {
    var infos = [];
    partial.forEach(function (info) {
      if (info.block === block && info.node.isConnected && info.record) infos.push(info);
    });
    textNodesOf(block).forEach(function (n) { var info = infoFor(n); if (info) { info.block = block; infos.push(info); } });
    infos.sort(function (a, b) {
      var pos = a.node.compareDocumentPosition(b.node);
      return pos & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : (pos & Node.DOCUMENT_POSITION_PRECEDING ? 1 : 0);
    });
    var items = [], total = 0, jaTotal = 0;
    for (var i = 0; i < infos.length; i++) {
      var info = infos[i];
      for (var p = 0; p < info.parts.length; p++) {
        if (info.done[p]) continue;
        var len = scalarLength(info.parts[p]);
        // Stop at about CHUNK_TARGET, but never leave a group too small to be worth sending (a short first node).
        if (items.length && jaTotal >= MIN_JA_CHARS && total + 1 + len > CHUNK_TARGET) return finishGroup(items, jaTotal);
        total += (items.length ? 1 : 0) + len;
        jaTotal += jaCount(info.parts[p]);
        items.push({ info: info, index: p, text: info.parts[p] });
      }
    }
    return finishGroup(items, jaTotal);
  }
  function finishGroup(items, jaTotal) { return items.length && (jaTotal >= MIN_JA_CHARS || items[0].info.record) ? items : null; }

  // Split the server's segments back over the items. English pieces are never split; the "\n"
  // separators must come back as Japanese text. Returns null on any inconsistency.
  function distribute(segments, items) {
    var si = 0, off = 0;
    function take(n) {
      var pieces = [];
      while (n > 0) {
        var seg = segments[si];
        if (!seg) return null;
        var remaining = seg.source.length - off;
        if (remaining <= n) {
          pieces.push({ kind: seg.kind, source: seg.source.slice(off), display: seg.kind === "en" ? seg.display : seg.source.slice(off) });
          n -= remaining; si++; off = 0;
        } else {
          if (seg.kind === "en") return null;
          pieces.push({ kind: "ja", source: seg.source.slice(off, off + n), display: seg.source.slice(off, off + n) });
          off += n; n = 0;
        }
      }
      return pieces;
    }
    var result = [];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) {
        var sep = take(1);
        if (!sep || sep.length !== 1 || sep[0].kind !== "ja" || sep[0].source !== "\n") return null;
      }
      var pieces = take(items[i].text.length);
      if (!pieces) return null;
      var joined = pieces.map(function (p) { return p.source; }).join("");
      if (joined !== items[i].text) return null;
      result.push(pieces);
    }
    if (si !== segments.length || off !== 0) return null;
    return result;
  }

  function validSegments(segments) {
    if (!Array.isArray(segments)) return false;
    for (var i = 0; i < segments.length; i++) {
      var s = segments[i];
      if (!s || (s.kind !== "ja" && s.kind !== "en") || typeof s.source !== "string" || typeof s.display !== "string" || !s.source) return false;
      if (s.kind === "ja" && s.display !== s.source) return false;
      if (s.kind === "en" && (!s.display.trim() || /[\r\n]/.test(s.display) || /[\r\n]/.test(s.source))) return false;
    }
    return true;
  }

  // ---- DOM replacement ----------------------------------------------------------------------
  function makeEnglish(piece) {
    var el = document.createElement("span");
    el.setAttribute("data-mz-en", "1");
    el.lang = "en";
    el.setAttribute("role", "button");
    el.setAttribute("tabindex", "0");
    el.setAttribute("aria-label", piece.display);
    el.textContent = piece.display;       // text only, never HTML
    sources.set(el, piece.source);
    setImportant(el, {
      "text-decoration": "underline", "text-decoration-thickness": "2px", "text-underline-offset": "3px",
      "background-color": "rgba(27,95,209,0.14)", "border-radius": "3px", "padding": "0.2em 0.12em",
      "cursor": "pointer", "-webkit-tap-highlight-color": "transparent"
    });
    return el;
  }

  function fillPart(container, pieces) {
    while (container.firstChild) container.removeChild(container.firstChild);
    var pendingJa = "";
    function flush() { if (pendingJa) { container.appendChild(document.createTextNode(pendingJa)); pendingJa = ""; } }
    for (var k = 0; k < pieces.length; k++) {
      if (pieces[k].kind === "en") { flush(); container.appendChild(makeEnglish(pieces[k])); }
      else pendingJa += pieces[k].display;
    }
    flush();
  }

  // Show the translation of one part right away. The first part replaces the node's text with a wrapper
  // that still shows the untranslated rest in Japanese; later parts fill in their own slot.
  function applyPart(info, index, pieces) {
    var node = info.node;
    if (!info.record) {
      if (!node.isConnected || node.nodeValue !== info.original || byNode.has(node)) return false;
      var wrapper = document.createElement("span");
      wrapper.setAttribute("data-mazemaze", "1");
      if (info.lead) wrapper.appendChild(document.createTextNode(info.lead));
      var slots = [];
      for (var i = 0; i < info.parts.length; i++) {
        var slot = document.createElement("span");
        slot.setAttribute("data-mz-part", String(i));
        slot.appendChild(document.createTextNode(info.parts[i]));
        wrapper.appendChild(slot);
        slots.push(slot);
      }
      if (info.trail) wrapper.appendChild(document.createTextNode(info.trail));
      node.after(wrapper);
      node.nodeValue = PLACEHOLDER;
      var rec = { node: node, original: info.original, wrapper: wrapper, slots: slots, info: info };
      info.record = rec;
      records.add(rec);
      byNode.set(node, rec);
      partial.add(info);
    }
    var record = info.record;
    if (!record.wrapper.isConnected || !node.isConnected) return false;
    fillPart(record.slots[index], pieces);
    if (metrics.firstApplyAt === null) metrics.firstApplyAt = since();
    return true;
  }

  function undoRecord(rec, restoreText) {
    if (rec.wrapper.parentNode) rec.wrapper.remove();
    if (restoreText && rec.node.isConnected) {
      var v = rec.node.nodeValue;
      var at = v.indexOf(PLACEHOLDER);
      if (at >= 0) rec.node.nodeValue = v.slice(0, at) + rec.original + v.slice(at + PLACEHOLDER.length);   // page edited around our placeholder
    }
    records.delete(rec);
    if (rec.info) {
      partial.delete(rec.info);
      // The text is back to what the page had: the node may be translated again from scratch.
      rec.info.record = null; rec.info.done = new Array(rec.info.parts.length); rec.info.remaining = rec.info.parts.length;
    }
    if (byNode.get(rec.node) === rec) byNode.delete(rec.node);
  }

  function restoreAll() {
    hidePopover();
    Array.from(records).forEach(function (rec) { undoRecord(rec, true); });
    if (mo) mo.takeRecords();
    // Anything the page changed in the meantime is its own business; forget our bookkeeping.
    pendingInfo = new WeakMap();
    nodeState = new WeakMap();
  }

  function sweep() {
    // The page may have removed or recycled our text nodes (virtual lists, re-renders).
    Array.from(records).forEach(function (rec) {
      if (!rec.node.isConnected) undoRecord(rec, false);
      else if (!rec.wrapper.isConnected) {
        // The page removed our wrapper: its original text is back, so translate that node again.
        var node = rec.node;
        undoRecord(rec, true);
        var removals = (reappear.get(node) || 0) + 1;       // a page that keeps removing our wrapper must not loop us forever
        reappear.set(node, removals);
        if (removals >= MAX_NODE_TRIES + 1) nodeState.set(node, { tries: MAX_NODE_TRIES, status: "failed" });
        else if (state.running && state.started) { pendingInfo.delete(node); scheduleScan(node); }
      }
    });
    registered.forEach(function (_, el) { if (!el.isConnected) { registered.delete(el); visible.delete(el); if (io) io.unobserve(el); } });
    if (mo) mo.takeRecords();
  }

  // ---- scheduling ---------------------------------------------------------------------------
  function register(block) {
    if (!block || registered.has(block) || registered.size >= MAX_BLOCKS) return;
    registered.set(block, true);
    if (io) io.observe(block);
  }

  function scan(root) {
    if (!state.running || !state.started) return;
    if (hasPasswordField()) { block("password"); return; }
    if (state.blocked === "password") state.blocked = null;
    var walker, n, seen = 0;
    if (root.nodeType === 3) { if (isCandidateNode(root)) register(blockOf(root)); return; }
    if (root.nodeType !== 1 || (root.closest && root.closest("[data-mazemaze],[data-mazemaze-ui]"))) return;
    walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    while ((n = walker.nextNode()) && seen++ < MAX_SCAN_NODES) {
      if (isCandidateNode(n)) register(blockOf(n));
    }
    schedulePump(0);
  }

  function scheduleScan(root) {
    scanQueue.add(root);
    if (scanTimer) return;
    scanTimer = setTimeout(function () {
      scanTimer = null;
      var roots = Array.from(scanQueue); scanQueue.clear();
      roots.forEach(function (r) { scan(r); });
    }, SCAN_DEBOUNCE_MS);
  }

  function block(reason) {
    state.blocked = reason;
    stopWork();
    restoreAll();
  }

  function stopWork() {
    state.running = false;
    state.started = false;
    state.reqId++;
    visible.clear();
    if (scanTimer) { clearTimeout(scanTimer); scanTimer = null; }
    if (pumpTimer) { clearTimeout(pumpTimer); pumpTimer = null; }
    if (startTimer) { clearTimeout(startTimer); startTimer = null; }
    scanQueue.clear();
  }

  function schedulePump(delay) {
    if (!state.running || pumpTimer) return;
    pumpTimer = setTimeout(function () { pumpTimer = null; pump(); }, delay);
  }

  // What to translate next: whatever is on screen (top first), then what is just below, then what is above.
  function pickBlock() {
    if (visible.size > metrics.maxVisible) metrics.maxVisible = visible.size;
    var best = null, bestScore = Infinity, vh = window.innerHeight || 800;
    visible.forEach(function (el) {
      if (!el.isConnected) { visible.delete(el); registered.delete(el); return; }
      var r = el.getBoundingClientRect();
      var score;
      if (r.bottom < 0) score = 1e6 + Math.abs(r.bottom);          // already scrolled past
      else if (r.top >= vh) score = 1e3 + (r.top - vh);            // below the screen: nearest first
      else score = Math.max(r.top, 0) / 10;                        // on screen: top first
      if (score < bestScore) { best = el; bestScore = score; }
    });
    return best;
  }

  function pump() {
    if (!state.running || state.inflight || state.paused) return;
    if (state.requests >= MAX_REQUESTS_PER_PAGE) { state.stopped = "limit"; stopWork(); return; }
    var el = pickBlock();
    if (!el) return;
    var items = nextGroup(el);
    if (!items) {          // nothing (more) to do in this block
      visible.delete(el); registered.delete(el); if (io) io.unobserve(el);
      schedulePump(0);
      return;
    }
    send(el, items);
  }

  function send(el, items) {
    var gen = state.gen;
    var id = ++state.reqId;
    state.inflight = true;
    state.requests++;
    var text = items.map(function (i) { return i.text; }).join("\n");
    var sentAt = performance.now();
    if (metrics.firstSendAt === null) metrics.firstSendAt = since();
    ask({ type: "translate", gen: gen, text: text }).then(function (reply) {
      if (metrics.reqs.length < 200) metrics.reqs.push({ ms: Math.round(performance.now() - sentAt), chars: text.length, ok: !!(reply && reply.ok), at: since() });
      if (id !== state.reqId) return;                      // superseded (page change / reconfigure)
      state.inflight = false;
      if (gen !== state.gen || !state.running) return;
      state.bridgeRejects = 0;
      try { handleReply(reply, items); } catch (e) { failItems(items, "invalid_response"); }
    }, function () {
      if (id !== state.reqId) return;
      state.inflight = false;
      if (gen === state.gen) failItems(items, "bridge");   // Swift refused or the call failed
    });
  }

  function handleReply(reply, items) {
    {
      if (reply && reply.ok === true && validSegments(reply.segments)) {
        var distributed = distribute(reply.segments, items);
        if (distributed) {
          state.backoff = 0;
          items.forEach(function (it, idx) {
            if (it.info.done[it.index]) return;             // already filled
            if (applyPart(it.info, it.index, distributed[idx])) {
              it.info.done[it.index] = true;
              it.info.remaining--;
              if (it.info.remaining === 0) partial.delete(it.info);   // fully translated
            } else {
              nodeState.set(it.info.node, { tries: MAX_NODE_TRIES, status: "failed" });
              partial.delete(it.info);
            }
          });
          if (mo) mo.takeRecords();
          schedulePump(0);
          return;
        }
        failItems(items, "invalid_response");
        return;
      }
      failItems(items, reply && reply.error);
    }
  }

  // Server/network trouble is a property of the page session, not of the text: back off and try
  // again without giving up on the nodes. Only node-specific failures count against a node.
  var TRANSIENT = { busy: 1, paused: 1, unreachable: 1, cancelled: 1 };   // about the connection, not the text
  var MAYBE_TEXT = { server: 1, timeout: 1 };                               // may be caused by this very text
  function resync() {
    // Our generation may be behind Swift's: ask once for the current configuration.
    if (state.resyncing) return;
    state.resyncing = true;
    ask({ type: "ready" }).then(function (cfg) {
      state.resyncing = false;
      if (cfg && typeof cfg.gen === "number" && cfg.gen !== state.gen) configure(cfg);
    }, function () { state.resyncing = false; });
  }
  function failItems(items, code) {
    var fatal = code === "unauthorized" || code === "not_configured" || code === "limit_reached" || code === "not_allowed" || code === "pin_mismatch" || code === "certificate_untrusted";
    if (code === "stale") { resync(); return; }
    if (fatal) { state.stopped = code; stopWork(); return; }
    if (code === "bridge") {
      if (++state.bridgeRejects >= 3) { state.stopped = "bridge"; stopWork(); return; }
    }
    if (TRANSIENT[code] || code === "bridge") {
      state.backoff = Math.min(state.backoff ? state.backoff * 2 : (code === "paused" ? 15000 : 3000), 60000);
      schedulePump(state.backoff);
      return;
    }
    if (MAYBE_TEXT[code]) {
      // Give the same text three tries before leaving it alone; meanwhile back off.
      var gaveUp = false;
      items.forEach(function (it) {
        var st = nodeState.get(it.info.node) || { tries: 0 };
        st.soft = (st.soft || 0) + 1;
        if (st.soft >= 3) { st.status = "failed"; gaveUp = true; }
        nodeState.set(it.info.node, st);
      });
      state.backoff = Math.min(state.backoff ? state.backoff * 2 : 3000, 60000);
      schedulePump(gaveUp ? 500 : state.backoff);
      return;
    }
    items.forEach(function (it) {
      var st = nodeState.get(it.info.node) || { tries: 0 };
      st.tries++;
      if (st.tries >= MAX_NODE_TRIES) st.status = "failed";
      nodeState.set(it.info.node, st);
    });
    schedulePump(1000);
  }

  // ---- observers ----------------------------------------------------------------------------
  function startObservers() {
    if (!io && "IntersectionObserver" in window) {
      io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { if (e.isIntersecting) visible.add(e.target); else visible.delete(e.target); });
        schedulePump(0);
      }, { rootMargin: "0px 0px 150% 0px" });   // read-ahead: one and a half screens below, none above (translated text above would shift the view)
      registered.forEach(function (_, el) { io.observe(el); });
    } else if (io) {
      // Same generation reconfigured: re-observe so visible blocks are reported again.
      registered.forEach(function (_, el) { io.unobserve(el); io.observe(el); });
    }
    if (!mo) {
      mo = new MutationObserver(onMutations);
      mo.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true });
    }
    if (!sweepTimer) sweepTimer = setInterval(sweep, SWEEP_MS);
  }

  function isOurs(node) {
    var el = node.nodeType === 1 ? node : node.parentElement;
    return !!(el && el.closest && el.closest("[data-mazemaze],[data-mazemaze-ui]"));
  }

  function onMutations(list) {
    if (!state.running) return;
    var needSweep = false;
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      if (m.type === "characterData") {
        var rec = byNode.get(m.target);
        if (rec) {
          if (m.target.nodeValue !== PLACEHOLDER) {
            // The page rewrote or merged the node we replaced: drop our copy, keep the page's text.
            undoRecord(rec, m.target.nodeValue.indexOf(PLACEHOLDER) >= 0);
            var n = (reappear.get(m.target) || 0) + 1;
            reappear.set(m.target, n);
            if (n >= MAX_NODE_TRIES) nodeState.set(m.target, { tries: MAX_NODE_TRIES, status: "failed" });
            else { pendingInfo.delete(m.target); scheduleScan(m.target); }
          }
        } else if (!isOurs(m.target)) {
          pendingInfo.delete(m.target);
          scheduleScan(m.target);
        }
      } else {
        if (m.removedNodes.length) needSweep = true;
        for (var j = 0; j < m.addedNodes.length; j++) {
          var added = m.addedNodes[j];
          if ((added.nodeType === 1 || added.nodeType === 3) && !isOurs(added)) scheduleScan(added);
        }
      }
    }
    if (needSweep) sweep();
  }

  // ---- tap on English -> show the original --------------------------------------------------
  function hidePopover() { if (popover && popover.parentNode) popover.remove(); popover = null; }

  function showPopover(el, point) {
    hidePopover();
    var source = sources.get(el);
    if (typeof source !== "string") return;
    var p = document.createElement("div");
    p.setAttribute("data-mazemaze-ui", "1");
    p.setAttribute("role", "status");
    p.textContent = source;
    setImportant(p, {
      "all": "initial", "position": "absolute", "z-index": "2147483647", "box-sizing": "border-box",
      "max-width": "min(90vw, 360px)", "padding": "8px 12px", "border-radius": "10px",
      "background": "#1c1c1e", "color": "#ffffff", "font": "14px/1.5 -apple-system, sans-serif",
      "white-space": "pre-wrap", "overflow-wrap": "anywhere", "box-shadow": "0 4px 16px rgba(0,0,0,.35)",
      "border": "1px solid rgba(255,255,255,0.45)",
      "display": "block", "visibility": "hidden"
    });
    document.documentElement.appendChild(p);
    // Anchor at the tap for a phrase that wraps over several lines; at the element otherwise.
    var r = el.getBoundingClientRect();
    // A synthetic click (VoiceOver) reports 0,0: use the point only when it lies on the element.
    var usePoint = point && (point.x || point.y) && point.x >= r.left - 24 && point.x <= r.right + 24 && point.y >= r.top - 24 && point.y <= r.bottom + 24;
    var ax = usePoint ? point.x : r.left, ayTop = usePoint ? point.y - 12 : r.top, ayBottom = usePoint ? point.y + 14 : r.bottom;
    var left = Math.max(8, Math.min(ax - 16, window.innerWidth - p.offsetWidth - 8));
    var below = ayBottom + 6;
    var top = below + p.offsetHeight + 8 <= window.innerHeight ? below : Math.max(8, ayTop - 6 - p.offsetHeight);
    p.style.setProperty("left", (window.scrollX + left) + "px", "important");
    p.style.setProperty("top", (window.scrollY + top) + "px", "important");
    p.style.setProperty("visibility", "visible", "important");
    popover = p;
  }

  document.addEventListener("click", function (e) {
    var t = e.target;
    var en = t && t.closest ? t.closest("[data-mz-en]") : null;
    if (en && en.closest("[data-mazemaze]")) {
      e.preventDefault();
      e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
      if (popover && popover.__for === en) hidePopover(); else { showPopover(en, { x: e.clientX, y: e.clientY }); if (popover) popover.__for = en; }
    } else if (popover && !(t && popover.contains && popover.contains(t))) {
      hidePopover();
    }
  }, true);
  document.addEventListener("keydown", function (e) {
    var t = e.target;
    var en = t && t.closest ? t.closest("[data-mz-en]") : null;
    if (en && (e.key === "Enter" || e.key === " ")) {
      e.preventDefault();
      if (popover && popover.__for === en) hidePopover(); else { showPopover(en); if (popover) popover.__for = en; }
    } else if (e.key === "Escape") { hidePopover(); }
  }, true);

  // Page activity tracker for waitForQuiet (frameworks hydrate right after load). Only changes inside
  // the article area count: ads and trackers keep changing the rest of the page for seconds.
  try {
    new MutationObserver(function (records) {
      var haveRoot = !!document.querySelector("article,main,[role='main']");
      for (var i = 0; i < records.length; i++) {
        var t = records[i].target;
        var el = t.nodeType === 1 ? t : t.parentElement;
        if (!haveRoot || (el && el.closest && el.closest("article,main,[role='main']"))) { state.lastMutation = performance.now(); break; }
      }
    }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    state.lastMutation = performance.now();
  } catch (e) { /* ignore */ }

  // ---- control (called by Swift) ------------------------------------------------------------
  function configure(cfg) {
    var genChanged = cfg.gen !== state.gen;
    var profile = cfg.profile === "x" ? "x" : "generic";
    // The same configuration again (several pushes for one page) must not restart the start-up wait.
    if (!genChanged && state.running && state.enabled === !!cfg.enabled && state.profile === profile) return status();
    stopWork();
    if (genChanged || !cfg.enabled) {
      restoreAll();
      registered.clear();
      visible.clear();
      if (io) { io.disconnect(); io = null; }
    }
    state.gen = cfg.gen;
    state.enabled = !!cfg.enabled;
    state.profile = profile;
    state.inflight = false;
    state.stopped = null;
    if (genChanged) state.requests = 0;
    if (!state.enabled) {
      if (mo) { mo.disconnect(); mo = null; }
      if (sweepTimer) { clearInterval(sweepTimer); sweepTimer = null; }
      return status();
    }
    state.running = true;
    state.backoff = 0;
    var begun = Date.now();
    (function waitForQuiet() {
      startTimer = setTimeout(function () {
        startTimer = null;
        if (!state.running) return;
        // Wait until the DOM has been calm for QUIET_MS (frameworks hydrate right after load), but not
        // for the whole page to finish loading, and never longer than MAX_QUIET_WAIT_MS.
        var calm = performance.now() - state.lastMutation >= QUIET_MS && document.readyState !== "loading";
        if (!calm && Date.now() - begun < MAX_QUIET_WAIT_MS) { waitForQuiet(); return; }
        state.started = true;
        if (metrics.startedAt === null) metrics.startedAt = since();
        startObservers();
        scan(document.body || document.documentElement);
      }, QUIET_MS / 3);
    })();
    return status();
  }

  function status() {
    return {
      gen: state.gen, enabled: state.enabled, running: state.running, blocked: state.blocked,
      stopped: state.stopped, paused: state.paused, requests: state.requests, replaced: records.size,
      english: document.querySelectorAll("[data-mz-en]").length, metrics: metrics, now: since()
    };
  }

  window.__mazemaze = {
    configure: configure,
    // A tab that is not on screen stops asking for translations (what is shown stays as it is).
    pause: function () { state.paused = true; return status(); },
    resume: function () {
      state.paused = false;
      if (io) registered.forEach(function (_, el) { io.unobserve(el); io.observe(el); });
      schedulePump(0);
      return status();
    },
    restoreAll: function () { stopWork(); state.enabled = false; restoreAll(); if (mo) { mo.disconnect(); mo = null; } return status(); },
    status: status
  };

  // Ask Swift whether (and how) to run on this page. Swift verifies the real URL itself.
  ask({ type: "ready" }).then(function (cfg) {
    if (cfg && typeof cfg.gen === "number") configure(cfg);
  }, function () { /* no native side: stay inert */ });
})();
