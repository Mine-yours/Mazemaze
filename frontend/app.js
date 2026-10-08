"use strict";
// All user/LLM text goes through textContent (no HTML string building). Offsets from the API are
// not used; segments are rendered in order from `source` and `display`.
(function () {
  const $ = (id) => document.getElementById(id);
  const input = $("input"), runBtn = $("run"), progress = $("progress"), elapsed = $("elapsed");
  const errorBox = $("error"), errorMsg = $("error-msg"), retryBtn = $("retry");
  const resultSection = $("result-section"), resultHeading = $("result-h"), resultEl = $("result");
  const detail = $("detail"), summary = $("summary");
  const copyBtn = $("copy"), toggleBtn = $("toggle"), copyStatus = $("copy-status");
  const copyFallback = $("copy-fallback");
  const warningsEl = $("warnings"), statsEl = $("stats");
  const ratio = $("ratio"), ratioOut = $("ratio-out"), count = $("count"), countNote = $("count-note");

  const MAX_CHARS = 1000;
  let clientTimeoutMs = 200000;  // replaced by the server deadline + margin (see /api/status)
  const DETAIL_HINT = "下線の英語部分を押すと、元の日本語が表示されます。";
  let current = null;       // last successful response
  let showingOriginal = false;
  let timer = null;
  let busy = false;

  // Optional access token (LAN mode): taken from the URL fragment, kept for this tab only.
  let token = null;
  try {
    const m = /(?:^#|&)t=([^&]+)/.exec(location.hash);
    if (m) {
      token = decodeURIComponent(m[1]);
      sessionStorage.setItem("mazemaze-token", token);
      history.replaceState(null, "", location.pathname + location.search);
    } else {
      token = sessionStorage.getItem("mazemaze-token");
    }
  } catch (e) { /* storage may be unavailable */ }

  // Unsent draft survives an iOS tab discard (this tab's session only; never sent anywhere).
  try {
    const draft = sessionStorage.getItem("mazemaze-draft");
    if (draft && !input.value) input.value = draft;
  } catch (e) { /* ignore */ }

  fetch("/api/status", { headers: token ? { "X-Mazemaze-Token": token } : {} })
    .then((r) => (r.ok ? r.json() : null))
    .then((st) => { if (st && st.deadline_seconds) {
      clientTimeoutMs = (st.deadline_seconds + 30) * 1000;
      $("progress-msg").textContent = "変換しています。最大約 " + Math.ceil(st.deadline_seconds / 60) +
        " 分かかります。途中でやめることはできません。";
    } })
    .catch(() => { /* keep the default */ });

  function updateCount() {
    const n = Array.from(input.value).length;
    count.textContent = String(n);
    countNote.textContent = n >= MAX_CHARS ? "（上限です。超えた分は入力できません）" : "";
    countNote.className = n >= MAX_CHARS ? "count-over" : "";
    try { sessionStorage.setItem("mazemaze-draft", input.value); } catch (e) { /* ignore */ }
  }
  input.addEventListener("input", updateCount);
  ratio.addEventListener("input", () => { ratioOut.textContent = ratio.value + "%"; });
  updateCount();

  function setBusy(on) {
    busy = on;
    runBtn.disabled = on;
    retryBtn.disabled = on;
    input.readOnly = on;
    runBtn.textContent = on ? "変換中…" : "変換する";
    if (!on && timer) { clearInterval(timer); timer = null; }
  }

  function showError(message, retryable) {
    errorMsg.textContent = message;
    retryBtn.hidden = !retryable;
    errorBox.hidden = false;
    errorBox.focus({ preventScroll: true });
    errorBox.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  function clearError() { errorBox.hidden = true; errorMsg.textContent = ""; }

  function showDetail(seg, el) {
    resultEl.querySelectorAll(".en").forEach((b) => b.setAttribute("aria-expanded", "false"));
    el.setAttribute("aria-expanded", "true");
    detail.textContent = "";
    const dl = document.createElement("dl");
    for (const [label, value] of [["元の日本語", seg.source], ["英語", seg.display]]) {
      const dt = document.createElement("dt"), dd = document.createElement("dd");
      dt.textContent = label; dd.textContent = value;
      dl.append(dt, dd);
    }
    detail.append(dl);
  }

  function resetDetail() {
    detail.textContent = "";
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = DETAIL_HINT;
    detail.append(p);
  }

  function makeEnglish(seg) {
    // A real inline element (a <button> is laid out as inline-block and wraps badly in WebKit).
    const el = document.createElement("span");
    el.className = "en";
    el.lang = "en";
    el.tabIndex = 0;
    el.setAttribute("role", "button");
    el.setAttribute("aria-expanded", "false");
    el.textContent = seg.display;
    el.addEventListener("click", () => showDetail(seg, el));
    el.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); showDetail(seg, el); }
    });
    return el;
  }

  function render() {
    resultEl.textContent = "";
    resetDetail();
    if (!current) return;
    if (showingOriginal) {
      resultEl.textContent = current.original;
      return;
    }
    for (const seg of current.segments) {
      resultEl.append(seg.kind === "en" ? makeEnglish(seg) : document.createTextNode(seg.display));
    }
  }

  function currentText() {
    if (!current) return "";
    return showingOriginal ? current.original : current.segments.map((s) => s.display).join("");
  }

  function hideCopyFallback() { copyFallback.hidden = true; copyFallback.value = ""; }

  function showResult(data) {
    current = data;
    showingOriginal = false;
    toggleBtn.textContent = "元の文章に戻す";
    copyStatus.textContent = "";
    hideCopyFallback();
    warningsEl.textContent = "";
    for (const w of data.warnings || []) {
      const li = document.createElement("li");
      li.textContent = w;
      warningsEl.append(li);
    }
    const st = data.stats || {};
    const n = st.accepted_spans || 0, req = st.requested_spans || 0;
    summary.textContent = n + " 箇所を英語にしました。" +
      (req > n ? "残りの " + (req - n) + " 箇所は日本語のままです。" : "");
    statsEl.textContent =
      "英語化率 " + Math.round((st.actual_ratio || 0) * 100) + "%（目標 " +
      Math.round((st.target_ratio || 0) * 100) + "%・目安です）／ " +
      ((st.elapsed_ms || 0) / 1000).toFixed(1) + " 秒";
    resultSection.hidden = false;
    render();
    resultHeading.focus({ preventScroll: true });
    resultSection.scrollIntoView({ block: "start", behavior: "smooth" });
  }

  async function translate(payload) {
    clearError();
    resultSection.hidden = true;   // an old result must not look like the answer to the new request
    current = null;
    setBusy(true);
    const started = Date.now();
    const tick = () => { elapsed.textContent = Math.floor((Date.now() - started) / 1000) + " 秒"; };
    progress.hidden = false;
    tick();
    timer = setInterval(tick, 1000);
    const controller = new AbortController();
    const abortTimer = setTimeout(() => controller.abort(), clientTimeoutMs);
    try {
      const headers = { "Content-Type": "application/json" };
      if (token) headers["X-Mazemaze-Token"] = token;
      const res = await fetch("/api/translate", {
        method: "POST", headers, body: JSON.stringify(payload), signal: controller.signal,
      });
      let body = null;
      try { body = await res.json(); } catch (e) { /* not JSON */ }
      if (!res.ok) {
        const msg = body && body.error && body.error.message;
        // Re-sending the same input cannot help for these; fix the input or the URL instead.
        const retryable = ![400, 401, 403, 411, 413, 415, 422].includes(res.status);
        showError((msg || "変換に失敗しました。") + "（入力した文章は消えていません）", retryable);
        return;
      }
      if (!body || !Array.isArray(body.segments)) {
        showError("サーバーからの応答を読み取れませんでした。（入力した文章は消えていません）", true);
        return;
      }
      showResult(body);
    } catch (e) {
      showError(e && e.name === "AbortError"
        ? "時間内に応答がありませんでした。Mac 側では処理が続いている可能性があります。1〜2 分待ってから再試行してください。（入力した文章は消えていません）"
        : "通信が中断されました（別のアプリに切り替えた場合などに起こります）。Mac 側では処理が続いている可能性があります。1〜2 分待ってから再試行してください。アプリが止まっていないかも確認してください。（入力した文章は消えていません）",
        true);
    } finally {
      clearTimeout(abortTimer);
      progress.hidden = true;
      setBusy(false);
    }
  }

  function run() {
    if (busy) return;
    const text = input.value;
    if (!text.trim()) {
      showError("文章を入力してください。", false);
      input.focus();
      return;
    }
    const unit = document.querySelector('input[name="unit"]:checked').value;
    translate({ text, ratio: Number(ratio.value) / 100, unit });
  }

  runBtn.addEventListener("click", run);
  retryBtn.addEventListener("click", run);  // always the current input and settings

  toggleBtn.addEventListener("click", () => {
    if (!current) return;
    showingOriginal = !showingOriginal;
    toggleBtn.textContent = showingOriginal ? "英語を表示する" : "元の文章に戻す";
    copyStatus.textContent = "";
    hideCopyFallback();
    render();
  });

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); return true; } catch (e) { /* fall through */ }
    }
    // A plain-HTTP LAN address is not a secure context, so the Clipboard API is unavailable there.
    const previous = document.activeElement;
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;top:0;left:0;opacity:0;font-size:16px";
    document.body.append(ta);
    ta.focus({ preventScroll: true });
    ta.select();
    ta.setSelectionRange(0, text.length);
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    ta.remove();
    if (previous && previous.focus) previous.focus({ preventScroll: true });
    return ok;
  }

  copyBtn.addEventListener("click", async () => {
    const text = currentText();
    if (!text) return;
    hideCopyFallback();
    const ok = await copyText(text);
    if (ok) {
      copyStatus.textContent = "コピーしました。";
    } else {
      copyStatus.textContent = "自動でコピーできませんでした。下の欄の文章を選択してコピーしてください。";
      copyFallback.value = text;
      copyFallback.hidden = false;
      copyFallback.focus({ preventScroll: true });
      copyFallback.select();
    }
  });
})();
