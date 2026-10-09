// DOM tests for ios/Mazemaze/Resources/translator.js in real Chrome (headless, CDP, no npm packages).
//   node ios/WebTests/run_dom_tests.mjs
// The native side is replaced by a deterministic mock bridge that behaves like the Swift handler
// (it re-implements only the *shape* of the server reply). WebKit-specific behaviour is covered by
// the iOS simulator self-test (ios/scripts/simulator_selftest.sh), not here.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = fs.readFileSync(path.join(HERE, "../Mazemaze/Resources/translator.js"), "utf8");
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
if (!fs.existsSync(CHROME)) { console.log("SKIP: Chrome not found (set CHROME=...)"); process.exit(0); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
function check(name, cond, info = "") { results.push({ name, ok: !!cond }); console.log((cond ? "PASS " : "FAIL ") + name + (cond || !info ? "" : "  -> " + info)); }

// ---- browser ----------------------------------------------------------------------------------
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "mazemaze-dom-"));
const port = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--allow-file-access-from-files", "about:blank"], { stdio: "ignore" });
for (let i = 0; i < 50; i++) { try { await fetch(`http://127.0.0.1:${port}/json/version`); break; } catch { await sleep(200); } }
const tab = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let nextId = 0; const waiting = new Map(); const pageErrors = [];
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && waiting.has(d.id)) { const w = waiting.get(d.id); waiting.delete(d.id); d.error ? w.rej(new Error(JSON.stringify(d.error))) : w.res(d.result); }
  else if (d.method === "Runtime.exceptionThrown") pageErrors.push(d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text);
};
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++nextId; waiting.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });
const ev = async (expr) => { const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 375, height: 812, deviceScaleFactor: 2, mobile: true });

// ---- mock native bridge -----------------------------------------------------------------------
const MOCK = `
window.__mock = { gen: 1, enabled: true, profile: "generic", mode: "ok", delay: 40, log: [], inflight: 0, maxInflight: 0 };
window.webkit = { messageHandlers: { mazemaze: { postMessage: function (m) { return window.__bridge(m); } } } };
window.__bridge = async function (msg) {
  var mk = window.__mock; mk.log.push(msg);
  if (msg.type === "ready") return { gen: mk.gen, enabled: mk.enabled, profile: mk.profile };
  if (msg.type === "save") { if (mk.saveFail) throw new Error("save failed"); return { ok: true, status: mk.saveStatus || "saved" }; }
  if (msg.type !== "translate") return { ok: false, error: "rejected" };
  mk.inflight++; mk.maxInflight = Math.max(mk.maxInflight, mk.inflight);
  await new Promise(function (r) { setTimeout(r, mk.delay); });
  mk.inflight--;
  if (mk.mode === "reject") throw new Error("not allowed");
  if (mk.mode.indexOf("error:") === 0) return { ok: false, error: mk.mode.slice(6), message: "" };
  if (msg.gen !== mk.gen) return { ok: false, error: "stale", message: "" };
  if (mk.mode === "mismatch") return { ok: true, segments: [{ kind: "ja", source: msg.text + " ", display: msg.text + " " }] };
  return { ok: true, segments: fake(msg.text, mk.mode === "xssen") };
};
function fake(text, evil) {
  var segs = [], n = 0;
  function push(kind, source, display) {
    if (kind === "ja" && segs.length && segs[segs.length - 1].kind === "ja") { segs[segs.length - 1].source += source; segs[segs.length - 1].display += source; }
    else segs.push({ kind: kind, source: source, display: display });
  }
  text.split("\\n").forEach(function (line, li) {
    if (li > 0) push("ja", "\\n", "\\n");
    var chunks = line.match(/[、。！？]*[^、。！？]+[、。！？]*|[、。！？]+/g) || [];
    var consumed = chunks.join("");
    chunks.forEach(function (c) {
      var body = c.replace(/[、。！？]+$/, ""), tail = c.slice(body.length);
      var lead = (/^\\s*/.exec(body) || [""])[0]; body = body.slice(lead.length);
      var trail = (/\\s*$/.exec(body) || [""])[0]; body = body.slice(0, body.length - trail.length);
      push("ja", lead, lead);
      if (body.length >= 4 && !/[A-Za-z0-9]/.test(body) && (n++ % 2 === 0)) push("en", body, evil ? "<img src=x onerror=window.__xss=3>" : "EN" + n + " " + body.length);
      else push("ja", body, body);
      push("ja", trail + tail, trail + tail);
    });
    if (consumed.length < line.length) push("ja", line.slice(consumed.length), line.slice(consumed.length));
  });
  return segs.filter(function (s) { return s.source.length > 0; });
}
`;
await send("Page.addScriptToEvaluateOnNewDocument", { source: MOCK });

async function load(file, { mode = "ok", delay = 40, profile: prof = "generic", inject = true, enabled = true } = {}) {
  await send("Page.navigate", { url: "file://" + path.join(HERE, file) });
  for (let i = 0; i < 100; i++) { if ((await ev("document.readyState")) === "complete") break; await sleep(50); }
  await ev(`window.__mock.mode=${JSON.stringify(mode)};window.__mock.delay=${delay};window.__mock.profile=${JSON.stringify(prof)};window.__mock.enabled=${enabled};0`);
  const before = await ev("document.body.innerHTML");
  if (inject) await ev(SCRIPT + ";0");
  return before;
}
async function settle(ms = 1800, maxMs = 20000) {
  const t0 = Date.now(); let last = -1, since = Date.now();
  while (Date.now() - t0 < maxMs) {
    const cur = await ev("window.__mock.log.length + ':' + window.__mock.inflight + ':' + document.querySelectorAll('[data-mazemaze]').length");
    if (cur !== last) { last = cur; since = Date.now(); }
    if (Date.now() - since > ms && !cur.includes(":1:")) return;
    await sleep(150);
  }
}
const text = (sel) => ev(`(function(){var e=document.querySelector(${JSON.stringify(sel)});return e?e.textContent:null})()`);
const html = (sel) => ev(`(function(){var e=document.querySelector(${JSON.stringify(sel)});return e?e.innerHTML:null})()`);
const count = (sel) => ev(`document.querySelectorAll(${JSON.stringify(sel)}).length`);
const status = () => ev("JSON.stringify(window.__mazemaze.status())").then(JSON.parse);
const translates = () => ev("window.__mock.log.filter(function(m){return m.type==='translate'}).length");
async function tapEl(selector) {
  const c = await ev(`(function(){var e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:"center"});var r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x: c.x, y: c.y, button: "left", clickCount: 1 });
}
const unchangedIn = ["#link", "nav", "footer", "#p3", "#p4", "#pre", "#edit", "#hid", "#hid2", "#nt", "#btn"];

// ---- 1. static article ------------------------------------------------------------------------
{
  const before = await load("static.html");
  const refs = await ev("(function(){var p=document.getElementById('p1');window.__ref=p.firstChild;window.__kids=p.childNodes.length;return 1})()");
  await settle();
  const st = await status();
  check("静的記事: 段落が英語混在になる", (await count("#p1 [data-mz-en]")) > 0 && st.replaced >= 4 && st.english >= 4, JSON.stringify(st));
  check("静的記事: 同時に送信するリクエストは 1 件だけ", (await ev("window.__mock.maxInflight")) === 1);
  const expectUnchanged = {};
  for (const sel of unchangedIn) expectUnchanged[sel] = true;
  const nowHtml = {};
  let allSame = true; const diffs = [];
  const beforeDoc = new DOMParser0(before);
  for (const sel of unchangedIn) { const a = beforeDoc.get(sel); const b = await html(sel); if (a !== b) { allSame = false; diffs.push(sel); } }
  check("除外要素・英語のみ・短文・article 外は変更されない", allSame, diffs.join(","));
  check("textarea / input の値は変更されない", (await ev("document.getElementById('ta').value")).startsWith("入力欄の中の") && (await ev("document.getElementById('in').value")) === "入力欄の値は触りません");
  check("リンクは壊れていない（href・テキスト・要素同一）", (await ev("var l=document.getElementById('link');l.getAttribute('href')==='#x'&&l.textContent==='このリンクの文字は翻訳しません'")));
  check("ページ自身のスクリプトは実行済みで影響を受けない", await ev("window.__pageScriptRan === true"));
  check("英語部分は下線付き・タップ可能な span", await ev("(function(){var e=document.querySelector('[data-mz-en]');var s=getComputedStyle(e);return s.textDecorationLine.indexOf('underline')>=0&&s.cursor==='pointer'&&e.tagName==='SPAN'})()"));
  check("英語 span に script/img などの要素がない", (await count("[data-mz-en] *")) === 0);

  // popover
  await ev("window.__bodyClicks=0;document.body.addEventListener('click',function(){window.__bodyClicks++});0");
  await tapEl("#p1 [data-mz-en]");
  await sleep(150);
  const pop = await ev("(function(){var p=document.querySelector('[data-mazemaze-ui]');return p?p.textContent:null})()");
  check("英語をタップすると元の日本語がポップオーバー表示される", pop && /[ぁ-ん一-龥]/.test(pop) && (await text("#p1")).includes(""), String(pop));
  check("ポップオーバーはページのクリック処理へ伝播しない", (await ev("window.__bodyClicks")) === 0);
  check("ポップオーバーは画面内に収まる", await ev("(function(){var r=document.querySelector('[data-mazemaze-ui]').getBoundingClientRect();return r.left>=0&&r.right<=innerWidth+1})()"));
  await tapEl("#p3");
  await sleep(100);
  check("他の場所をタップするとポップオーバーが閉じる", (await count("[data-mazemaze-ui]")) === 0);

  // exact restore
  await ev("window.__mazemaze.restoreAll()");
  const after = await ev("document.body.innerHTML");
  check("原文へ完全復元: body.innerHTML が翻訳前と完全一致", after === before, after === before ? "" : "differs");
  check("復元後: 元のテキストノードが同一で子ノード数も同じ", await ev("var p=document.getElementById('p1');p.firstChild===window.__ref&&p.childNodes.length===window.__kids"));
  check("復元後: wrapper が残っていない", (await count("[data-mazemaze],[data-mz-en]")) === 0);
}

// ---- 2. login page ----------------------------------------------------------------------------
{
  const before = await load("login.html");
  await settle(1500);
  check("パスワード欄のあるページでは何もしない", (await ev("document.body.innerHTML")) === before && (await translates()) === 0 && (await status()).blocked === "password");
}

// ---- 3. xss -----------------------------------------------------------------------------------
for (const mode of ["ok", "xssen"]) {
  const before = await load("xss.html", { mode });
  await settle();
  check(`XSS(${mode}): スクリプトも img も実行・生成されない`, (await ev("window.__xss === undefined")) && (await count("img")) === 0 && (await count("script")) === 0);
  check(`XSS(${mode}): HTML 風の文字列は文字として残る`, (await text("#x1")).includes('<img src=x onerror="window.__xss=1">') || mode === "xssen");
  await ev("window.__mazemaze.restoreAll()");
  check(`XSS(${mode}): 復元で完全一致`, (await ev("document.body.innerHTML")) === before);
}

// ---- 4. mismatch / errors ---------------------------------------------------------------------
{
  const before = await load("static.html", { mode: "mismatch" });
  await settle();
  check("サーバー応答の原文が 1 文字でも違えば破棄（DOM 不変）", (await ev("document.body.innerHTML")) === before && (await count("[data-mazemaze]")) === 0);
  check("不一致のノードは再試行が打ち切られる（無限ループしない）", (await translates()) <= 12, String(await translates()));
}
{
  const before = await load("static.html", { mode: "error:busy" });
  await settle(9000, 30000);
  check("busy が続いても DOM は不変で、再試行は上限で止まる", (await ev("document.body.innerHTML")) === before && (await translates()) <= 12, String(await translates()));
}
{
  const before = await load("static.html", { mode: "error:unauthorized" });
  await settle(2500);
  const st = await status();
  check("認証エラーでは直ちに停止し、再送しない", st.stopped === "unauthorized" && (await translates()) === 1 && (await ev("document.body.innerHTML")) === before, JSON.stringify(st));
}

// ---- 5. dynamic content -----------------------------------------------------------------------
{
  const before = await load("dynamic.html");
  await settle();
  const first = await count("#first [data-mz-en]");
  await ev("addMany(5)");
  await settle();
  check("後から追加された段落も翻訳される", first > 0 && (await count("#dyn0 [data-mz-en], #dyn1 [data-mz-en], #dyn2 [data-mz-en]")) > 0);
  const t0 = await translates();
  await ev("addMany(100)");
  await settle(2500, 60000);
  check("100 件追加しても同時送信は 1 件のみ", (await ev("window.__mock.maxInflight")) === 1);
  const used = await translates() - t0;
  check("画面外の段落はまとめて送られない（表示付近のみ順次処理）", used > 0 && used <= 100, String(used));
  await ev("window.__mazemaze.restoreAll()");
  check("動的ページも復元後に wrapper が残らない", (await count("[data-mazemaze]")) === 0 && (await text("#first")).startsWith("最初から"));
}
{
  // A slow request is in flight when the page generation changes: its answer must never land.
  await load("dynamic.html", { delay: 900 });
  await sleep(1300);   // the first request is now in flight (900 ms)
  await ev("window.__mock.gen = 2; window.__mazemaze.configure({gen: 2, enabled: false, profile: 'generic'}); 0");
  await sleep(1800);
  check("遷移中の古い世代の応答は DOM に反映されない", (await count("[data-mazemaze]")) === 0 && (await text("#first")).startsWith("最初から"));
}
{
  // SPA route change: new content under a new generation is translated, old queue is dropped.
  await load("dynamic.html", { delay: 600 });
  await sleep(1300);
  await ev("window.__mock.gen = 2; window.__mazemaze.configure({gen: 2, enabled: true, profile: 'generic'}); spaNavigate(); window.__mock.delay = 30; 0");
  await settle(2500, 30000);
  check("遷移後の新しいページは新しい世代で翻訳される", (await count("#spa1 [data-mz-en]")) > 0);
  check("旧世代の gen=1 での新規送信は遷移後に行われない", await ev("(function(){var l=window.__mock.log.filter(function(m){return m.type==='translate'});var i=l.map(function(m){return m.gen}).lastIndexOf(1);return l.slice(i+1).every(function(m){return m.gen===2})})()"));
}

// ---- 6. toggle off ----------------------------------------------------------------------------
{
  const before = await load("static.html");
  await settle();
  await ev("window.__mock.gen=2; window.__mazemaze.configure({gen: 2, enabled: false, profile: 'generic'}); 0");
  check("翻訳 OFF で原文へ完全復元（innerHTML 一致）", (await ev("document.body.innerHTML")) === before);
  const n = await translates();
  await sleep(1500);
  check("OFF の間は新規リクエストを送らない", (await translates()) === n);
}

// ---- 7. X-like profile ------------------------------------------------------------------------
{
  const before = await load("xlike.html", { profile: "x" });
  await settle();
  check("X 風: ツイート本文だけが翻訳され、UI ラベルは触れない", (await count("[data-testid='tweetText'] [data-mz-en]")) > 0 && (await text("#chrome")) === "UI のラベルの日本語のテキストです。これは翻訳しません。");
  check("X 風: リンク（ハッシュタグ）は変更されない", (await html("[data-testid='tweetText'] a")) === "#ハッシュタグ");
  const firstTweetRequests = await ev("window.__mock.log.filter(function(m){return m.type==='translate'&&m.text.indexOf('友達と公園')>=0}).map(function(m){return m.text})");
  check("X 風: 同じ投稿内の複数ノードは 1 リクエストにまとまる", firstTweetRequests.length === 1 && firstTweetRequests[0].includes("\n") && firstTweetRequests[0].includes("そのあと新しい"), JSON.stringify(firstTweetRequests));
  await ev("window.__mazemaze.restoreAll()");
  check("X 風: 復元で完全一致", (await ev("document.body.innerHTML")) === before);
}

// ---- 7b. X-like profile, newer markup without data-testid ----------------------------------------
{
  const before = await load("xlike2.html", { profile: "x" });
  await settle();
  check("X 新形式: 投稿本文（article 内の div[dir=auto]）が翻訳される", (await count("article div[dir='auto'] [data-mz-en]")) > 0);
  check("X 新形式: 名前・時刻（リンク）・ボタン・記事外は変更されない", (await text("#name")) === "首相官邸の公式アカウント名" && (await text("#tm")) === "2時間前の投稿です" && (await text("#btn")) === "返信する操作のボタン" && (await count("#trend [data-mz-en]")) === 0 && (await count("#quote [data-mz-en]")) === 0 && (await text("#qt")) === "引用された投稿の見出しの日本語です。リンクとして扱われる入れ子の枠です。");
  check("X 新形式: 投稿全体を包む div[role=link] の中でも本文は翻訳され、リンク内の文字は触れない", (await count("[role='link'] div[dir='auto'] [data-mz-en]")) > 0 && (await html("div[dir='auto'] a")) === "#ハッシュタグ", (await count("[role='link'] div[dir='auto'] [data-mz-en]")));
  check("X 新形式: カードが article の外側にある形でも本文は翻訳され、入れ子の引用の枠は触れない", (await count("#b2 [data-mz-en], #card2 #b2 ~ [data-mz-en], #card2 [data-mz-en]")) > 0 && (await count("#quote2 [data-mz-en]")) === 0);
  await ev("window.__mazemaze.restoreAll()");
  check("X 新形式: 復元で完全一致", (await ev("document.body.innerHTML")) === before);
}

// ---- 8. framework-like page -------------------------------------------------------------------
{
  let before = await load("framework.html");
  await settle();
  check("フレームワーク風: 翻訳される", (await count("#cell [data-mz-en]")) > 0);
  await ev("fw.normalize(); 0");
  check("normalize() を呼ばれても元ノードは残る（空にしない設計）", (await ev("fw.node.isConnected")) && (await count("#cell [data-mazemaze]")) === 1);
  await ev("window.__mazemaze.restoreAll()");
  check("normalize() 後でも完全復元できる", (await ev("document.body.innerHTML")) === before);

  before = await load("framework.html");
  await settle();
  await ev("fw.update('ページ側が書き換えた新しい日本語のテキストです。更新されました。'); 0");
  await sleep(600);
  check("ページが元ノードを書き換えたら、古い訳は外れて二重表示にならない", !(await text("#cell")).includes("フレームワークが管理している"), await text("#cell"));
  await settle();
  check("書き換え後の新しいテキストが再評価される", (await text("#cell")).length > 0 && (await count("#cell [data-mazemaze]")) <= 1);

  await load("framework.html");
  await settle();
  await ev("fw.removeNode(); 0");
  await sleep(2600);
  check("ページが元ノードを削除したら、孤児 wrapper は掃除される", (await count("#cell [data-mazemaze]")) === 0);

  before = await load("framework.html");
  await settle();
  await ev("fw.replaceCell('置き換えられた新しい要素の日本語のテキストです。'); 0");
  await settle();
  check("部分木ごと入れ替えられても例外なく新しい内容が翻訳される", (await count("#cell [data-mz-en]")) > 0 && pageErrors.length === 0, pageErrors.join("|"));

  await load("framework.html");
  await settle();
  const startReq = await translates();
  await ev("window.__iv = fw.loopOverwrite('ページが書き換え続ける日本語のテキストです。何度でも。', 60); 0");
  await sleep(4000);
  await ev("clearInterval(window.__iv); 0");
  const extra = (await translates()) - startReq;
  check("ページが書き換え続けても再翻訳は上限で止まる（無限ループなし）", extra <= 3, String(extra));
}

// ---- 8b. edge cases ---------------------------------------------------------------------------
{
  const before = await load("edge.html", { profile: "x" });
  await settle();
  check("隣り合うテキストノード・flex 親・DM は翻訳しない", (await count("#adj [data-mazemaze]")) === 0 && (await count("#flex [data-mazemaze]")) === 0 && (await count("#dm, [data-testid='DMDrawer'] [data-mazemaze]")) >= 0 && (await count("[data-testid='DMDrawer'] [data-mazemaze]")) === 0);
  check("通常の投稿は翻訳される（X プロファイル）", (await count("#ok [data-mz-en]")) > 0 || (await count("#ok [data-mazemaze]")) > 0);
  check("DM 本文は一度も送信されない", await ev("window.__mock.log.every(function(m){return m.type!=='translate'||m.text.indexOf('ダイレクトメッセージ')<0})"));
  await ev("window.__mazemaze.restoreAll()");
  check("境界ケースのページも完全復元", (await ev("document.body.innerHTML")) === before);
}
{
  await load("edge.html", { profile: "generic" });
  await settle();
  const reqs = await translates();
  await ev("addJa(); document.getElementById('late').scrollIntoView(); 0");
  await settle();
  check("英語だけの段落 700 個があっても、あとから出た日本語は翻訳される（登録枠を消費しない）", (await count("#late [data-mz-en]")) > 0 || (await count("#late [data-mazemaze]")) > 0, String(reqs));
}
{
  await load("hydrate.html");
  await sleep(1200);
  const early = await count("[data-mazemaze]");
  const stillHydrating = await ev("window.__hydrating");
  await settle(1500, 20000);
  check("水和中（DOM が更新され続ける間）は触らず、静かになってから翻訳する", early === 0 && stillHydrating === true && (await count("#h [data-mazemaze]")) > 0, `early=${early} hydrating=${stillHydrating}`);
}
{
  // Transient server trouble must not permanently fail the nodes.
  await load("static.html", { mode: "error:busy" });
  await sleep(1500);
  const n1 = await translates();
  await ev("window.__mock.mode = 'ok'; 0");
  await settle(2500, 30000);
  check("一時的な busy のあとサーバーが回復したら、同じノードが翻訳される", n1 >= 1 && (await count("[data-mz-en]")) > 0, `requests-before-recovery=${n1}`);
}
{
  // A reply to a superseded request must not release the slot for, or duplicate, the new one.
  await load("static.html", { delay: 700 });
  await sleep(1500);
  await ev("window.__mock.gen = 2; window.__mazemaze.configure({gen: 2, enabled: true, profile: 'generic'}); 0");
  await settle(2500, 40000);
  const dupTexts = await ev("(function(){var seen={},d=[];window.__mock.log.filter(function(m){return m.type==='translate'&&m.gen===2}).forEach(function(m){if(seen[m.text])d.push(m.text.slice(0,30));seen[m.text]=1});return JSON.stringify(d)})()");
  check("古い要求の応答が新しい要求を二重送信させない", dupTexts === "[]", `duplicates=${dupTexts}`);
}

// ---- 8c. failure policies and reconfiguration -------------------------------------------------
{
  await load("static.html", { mode: "error:server" });
  await settle(12000, 60000);
  const n1 = await translates();
  await sleep(4000);
  const n2 = await translates();
  check("同じ文章でサーバーエラーが続くと、数回で諦めて再送をやめる", n1 >= 3 && n2 === n1, `after=${n1} later=${n2}`);
  check("諦めても DOM は不変", (await count("[data-mazemaze]")) === 0);
}
{
  await load("static.html", { mode: "reject" });
  await settle(9000, 60000);
  const st = await status();
  check("Swift が拒否（reject）し続けたら停止する（無限リトライしない）", st.stopped === "bridge" && (await translates()) <= 4, JSON.stringify(st));
}
{
  await load("dynamic.html");
  await settle();
  await ev("window.__mazemaze.configure({gen: 1, enabled: true, profile: 'generic'}); window.__mazemaze.configure({gen: 1, enabled: true, profile: 'generic'}); addPost('同じ世代で再設定したあとに追加された日本語の段落です。', 'later'); 0");
  await settle(2500, 30000);
  check("同じ世代で configure を重ねても、その後の翻訳が止まらない", (await count("#later [data-mz-en]")) > 0 || (await count("#later [data-mazemaze]")) > 0);
}

// ---- 8d. partial reflection, priority, pause ----------------------------------------------------
{
  await load("dynamic.html", { inject: false, delay: 600 });
  const longText = Array.from({ length: 12 }, (_, i) => `これは長い段落の${["一","二","三","四","五","六","七","八","九","十","十一","十二"][i]}番目の文で、翻訳されます。`).join("");
  await ev(`(function(){var p=document.createElement('p');p.id='part';p.textContent=${JSON.stringify(longText)};document.getElementById('feed').appendChild(p);0})()`);
  const before = await ev("document.body.innerHTML");
  await ev(SCRIPT + ";0");
  // wait for the first part only
  let seen = false;
  for (let i = 0; i < 80 && !seen; i++) { await sleep(100); seen = (await count("#part [data-mz-en]")) > 0; }
  const parts = await count("#part [data-mz-part]");
  const enNow = await count("#part [data-mz-en]");
  const reqsNow = await translates();
  check("長い段落は、最初の部分が訳せた時点ですぐ反映される（残りは日本語のまま続く）", seen && parts >= 2 && (await text("#part")).includes("これは長い段落の"), `parts=${parts} en=${enNow} requests=${reqsNow}`);
  await ev("window.__mazemaze.restoreAll()");   // while later parts are still in flight
  await sleep(2500);
  check("途中で原文に戻しても完全復元され、遅れて届く応答で再び変わらない", (await ev("document.body.innerHTML")) === before);
}
{
  await load("scroll.html", { delay: 300 });
  await sleep(1500);
  const firstTexts = await ev("window.__mock.log.filter(function(m){return m.type==='translate'}).slice(0,3).map(function(m){return m.text.slice(0,8)})");
  check("最初は画面内の段落（上から）を先に送る", firstTexts.length >= 1 && firstTexts[0].startsWith("第0番"), JSON.stringify(firstTexts));
  const sentBeforeScroll = await translates();
  await ev("document.getElementById('q30').scrollIntoView(); 0");
  await sleep(2500);
  const afterTexts = await ev("window.__mock.log.filter(function(m){return m.type==='translate'}).slice(" + sentBeforeScroll + ").map(function(m){return m.text.slice(0,8)})");
  check("スクロールで移動したら、新しく見える段落を先に送る（古い位置の続きより優先）", afterTexts.length >= 1 && afterTexts.slice(0, 2).some((t) => /第(29|30|31|32)番/.test(t)), JSON.stringify(afterTexts.slice(0, 4)));
}
{
  await load("dynamic.html");
  await settle();
  await ev("window.__mazemaze.pause(); addPost('一時停止中に追加された日本語の段落です。まだ翻訳されません。', 'paused1'); 0");
  const n = await translates();
  await sleep(2000);
  check("一時停止中は新しい要求を送らない（表示済みの訳はそのまま）", (await translates()) === n && (await count("#paused1 [data-mazemaze]")) === 0 && (await count("#first [data-mazemaze]")) > 0);
  await ev("window.__mazemaze.resume(); 0");
  await settle(2000, 30000);
  check("再開すると、停止中に増えた分も翻訳する", (await count("#paused1 [data-mazemaze]")) > 0);
}

// ---- 8e. short first node, wrapper removed by the page ------------------------------------------
{
  await load("shortfirst.html");
  await settle(2500, 40000);
  check("先頭が短いノードでも、続く長い本文は翻訳される", (await count("#sf [data-mz-en]")) > 0, JSON.stringify(await status()));
  await ev("window.__mazemaze.restoreAll(); 0");
}
{
  await load("dynamic.html");
  await settle();
  const had = await count("#first [data-mz-en]");
  await ev("document.querySelector('#first [data-mazemaze]').remove(); 0");        // the page throws our wrapper away
  await sleep(3000);
  const text1 = await text("#first");
  await settle(2500, 40000);
  check("ページが wrapper だけ取り除いても、日本語が失われず、翻訳し直される", had > 0 && text1.includes("日本語の文章がここにあります") && (await count("#first [data-mz-en]")) > 0, `had=${had} text=${JSON.stringify(text1.slice(0, 30))} after=${await count("#first [data-mz-en]")} st=${JSON.stringify(await status())}`);
}

// ---- 9. oversize paragraph --------------------------------------------------------------------
{
  await load("dynamic.html", { inject: false });
  const long = Array.from({ length: 120 }, (_, i) => `これは${i}番目の長い文章の一部で、とても長く続きます。`).join("");
  await ev(`(function(){var p=document.createElement('p');p.id='long';p.textContent=${JSON.stringify(long)};document.getElementById('feed').appendChild(p);0})()`);
  const before = await ev("document.body.innerHTML");
  await ev(SCRIPT + ";0");
  await settle(2500, 60000);
  const sizes = await ev("window.__mock.log.filter(function(m){return m.type==='translate'}).map(function(m){return Array.from(m.text).length})");
  check("長い段落は 160 文字前後（1 文が長くても 320 以内）に分割して送る", sizes.length >= 10 && sizes.every((n) => n <= 320) && sizes.filter((n) => n <= 160).length >= sizes.length - 1, JSON.stringify(sizes.slice(0, 8)));
  check("分割しても全体が英語混在になる", (await count("#long [data-mz-en]")) > 20);
  await ev("window.__mazemaze.restoreAll()");
  check("長い段落も完全復元", (await ev("document.body.innerHTML")) === before);
}



// ---- 13. "辞書に保存" button in the popover -----------------------------------------------------------------
{
  await load("static.html");
  await settle();
  await ev("window.__bodyClicks=0;window.addEventListener('click',function(){window.__bodyClicks++});0");   // bubble phase on window: sees whatever is not stopped
  await tapEl("#p1 [data-mz-en]");
  await sleep(150);
  check("辞書: 英語部分のタップ自体もページのクリック処理へ伝播しない", (await ev("window.__bodyClicks")) === 0);
  const en = await ev("document.querySelector('#p1 [data-mz-en]').textContent");
  const popTxt = await ev("document.querySelector('[data-mazemaze-ui] span').textContent");
  check("辞書: 吹き出しに「辞書に保存」ボタンがあり、日本語の原文も表示される", (await ev("(function(){var b=document.querySelector('[data-mazemaze-ui] button');return b&&b.textContent==='辞書に保存'})()")) && /[ぁ-ん一-龥]/.test(popTxt));
  await tapEl("[data-mazemaze-ui] button");
  await sleep(200);
  const saves = await ev("window.__mock.log.filter(function(m){return m.type==='save'})");
  check("辞書: 押すと { type, en, ja } だけを送る（英語は画面の英語、日本語は原文）", saves.length === 1 && Object.keys(saves[0]).sort().join() === "en,ja,type" && saves[0].en === en && saves[0].ja === popTxt, JSON.stringify(saves));
  check("辞書: 保存後はボタンが「保存しました」になり、吹き出しは残る", (await ev("document.querySelector('[data-mazemaze-ui] button').textContent")) === "保存しました");
  check("辞書: ボタンを押してもページのクリック処理へ伝播しない", (await ev("window.__bodyClicks")) === 0);
  await tapEl("[data-mazemaze-ui] button");
  await sleep(150);
  check("辞書: 連打しても 1 回しか送らない", (await ev("window.__mock.log.filter(function(m){return m.type==='save'}).length")) === 1);
  await ev("window.__mock.saveStatus='duplicate';0");
  await tapEl("body"); await sleep(100);
  await tapEl("#p1 [data-mz-en]"); await sleep(150);
  await tapEl("[data-mazemaze-ui] button"); await sleep(200);
  check("辞書: すでに保存済みなら「保存済みです」と出る", (await ev("document.querySelector('[data-mazemaze-ui] button').textContent")) === "保存済みです");
  await ev("window.__mock.saveFail=true;0");
  await tapEl("body"); await sleep(100);
  await tapEl("#p1 [data-mz-en]"); await sleep(150);
  await tapEl("[data-mazemaze-ui] button"); await sleep(200);
  check("辞書: 保存に失敗したら「保存できませんでした」と出る（例外にならない）", (await ev("document.querySelector('[data-mazemaze-ui] button').textContent")) === "保存できませんでした");
  await ev("window.__mock.saveFail=false;window.__mock.saveStatus='saved';0");
  await ev("document.querySelector('[data-mazemaze-ui] button').click()");          // a script's click (not trusted)
  await sleep(200);
  const before = await ev("window.__mock.log.filter(function(m){return m.type==='save'}).length");
  await ev("document.querySelector('[data-mazemaze-ui] button').click()");
  await sleep(200);
  check("辞書: 信頼されていない click() は送信を増やさない", (await ev("window.__mock.log.filter(function(m){return m.type==='save'}).length")) === before);
  await tapEl("[data-mazemaze-ui] button"); await sleep(200);
  check("辞書: 失敗のあとでも、本物のタップなら再試行できる", (await ev("window.__mock.log.filter(function(m){return m.type==='save'}).length")) === before + 1 && (await ev("document.querySelector('[data-mazemaze-ui] button').textContent")) === "保存しました");
  await ev("window.__mazemaze.restoreAll()");
  check("辞書: 吹き出し・ボタンは原文復元の邪魔をしない（元のページと同じ）", (await count("[data-mz-en]")) === 0);
}

// ---- 12. paste page ("貼り付けて翻訳"): the app's own template, filled by paste_fill.js ----------------------
{
  const RES = path.join(HERE, "../Mazemaze/Resources");
  const FILL = fs.readFileSync(path.join(RES, "paste_fill.js"), "utf8");
  const GET = fs.readFileSync(path.join(RES, "paste_text.js"), "utf8");
  const fill = (lines) => ev(`(function(lines){${FILL}})(${JSON.stringify(lines)})`);
  const shown = () => ev(`(function(){${GET}})()`);
  const lines = ["今日は晴れていて、散歩に出かけるのにちょうど良い天気です。", "", "短い", "<img src=x onerror=window.__xss=1>テストの文章がここにあります。これは日本語の文章です。", " 先頭に空白のある、長めの日本語の文章です。それから続きの文です。", "🙂 絵文字を含む、日本語のとても長い文章がここに入ります。"];
  await load("../Mazemaze/Resources/paste.html", { mode: "ok" });
  const csp = await ev("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content");
  check("貼り付け画面: CSP でスクリプトを許可しない（script-src なし・default-src 'none'）", /default-src 'none'/.test(csp) && !/script-src/.test(csp) && /form-action 'none'/.test(csp) && /base-uri 'none'/.test(csp), csp);
  check("貼り付け画面: テンプレートに script / form / input 要素がない", (await count("script, form, input, textarea, a[href]")) === 0);
  const ok = await fill(lines);
  const filled = await ev("document.getElementById('out').innerHTML");
  check("貼り付け: 1 行 1 要素（空行は blank）で入る", ok === true && (await count("#out > div")) === lines.length && (await count("#out > div.blank")) === 1);
  check("貼り付け: HTML は文字のまま表示され、実行・要素化されない", (await ev("window.__xss === undefined")) && (await count("#out img")) === 0 && (await ev("document.querySelectorAll('#out > div')[3].textContent")) === lines[3]);
  check("貼り付け: 取り出した文字列が貼り付けた原文と完全一致（改行・先頭空白・絵文字）", (await shown()) === lines.join("\n"));
  await settle();
  const st = await status();
  check("貼り付け: 既存の翻訳処理で英語混在になる", st.replaced >= 3 && (await count("#out [data-mz-en]")) >= 3, JSON.stringify(st));
  check("貼り付け: 短い行（8 文字未満）は日本語のまま", (await ev("document.querySelectorAll('#out > div')[2].textContent")) === "短い");
  const afterText = await shown();
  check("貼り付け: 翻訳後の表示文字列には不可視のプレースホルダが混ざらない", !afterText.includes("​") && afterText !== lines.join("\n") && afterText.split("\n").length === lines.length);
  await ev("window.__mazemaze.restoreAll()");
  check("貼り付け: 原文に戻すと貼り付けた状態と完全一致（DOM・文字列）", (await ev("document.getElementById('out').innerHTML")) === filled && (await shown()) === lines.join("\n"));
}

check("ページ側に未処理の例外が出ていない", pageErrors.length === 0, pageErrors.join("|").slice(0, 300));
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
await fetch(`http://127.0.0.1:${port}/json/close/${tab.id}`).catch(() => {});
chrome.kill();
await sleep(800);
try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 }); } catch { /* temp dir cleanup is best effort */ }
process.exit(failed ? 1 : 0);

// Minimal helper: look up innerHTML of selectors in a saved HTML string without a DOM library.
function DOMParser0(htmlText) {
  return {
    get(sel) {
      const id = sel.startsWith("#") ? sel.slice(1) : null;
      if (id) {
        const m = new RegExp(`<(\\w+)[^>]*id="${id}"[^>]*>([\\s\\S]*?)</\\1>`).exec(htmlText);
        return m ? m[2] : null;
      }
      const m = new RegExp(`<${sel}[^>]*>([\\s\\S]*?)</${sel}>`).exec(htmlText);
      return m ? m[1] : null;
    },
  };
}
