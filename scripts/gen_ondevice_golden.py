#!/usr/bin/env python3
"""Golden vectors for the Swift port of the span logic (ios/MazemazeCore/.../OnDevice).

The Python implementation in backend/ is the reference. This writes inputs together with the outputs Python
produces; the Swift tests (OnDeviceGoldenTests) must reproduce every one exactly. Re-run after changing
backend/selector.py, spans.py or display.py:   .venv/bin/python scripts/gen_ondevice_golden.py
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from backend.define import parse_card  # noqa: E402
from backend.display import format_segments, joined, outside_preserved  # noqa: E402
from backend.selector import candidates, counted_length, select_spans  # noqa: E402
from backend.spans import Span, SpanError, assemble, outside_text, validate_translation  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..")
OUT = os.path.join(ROOT, "ios/MazemazeCore/Tests/MazemazeCoreTests/Resources/ondevice_golden.json")
rng = random.Random(20261010)

texts = []
for line in open(os.path.join(ROOT, "eval/dataset_ja_en.jsonl"), encoding="utf-8"):
    texts.append(json.loads(line)["text"])
texts += [
    "", "あ", "。", "今日は天気がいいので、散歩に行きました。明日は雨が降るでしょう。",
    "「こんにちは」と彼は言った。私は「元気ですか」と聞いた。\n次の段落です。これは二行目の文章です。",
    "詳しくは https://example.com/guide?id=42 を見てください。連絡は a.b@example.com まで。",
    "価格は1,200円です。3Dの映像が見られる。ＡＢＣ商事の売上は好調だった。",
    "彼女は笑っだので、みんなも笑った。𠮷野家で朝ごはんを食べて、𠮷田さんと出勤した。",
    "👨‍👩‍👧家族でお出かけした日はとても楽しかった。\r\n改行コードが混ざった文章。 別の行。",
    "（括弧が閉じていない文章です。これは続きの文です。「引用の途中で終わる文章です。",
    "AとBの間で、とても長い文章が続きますがこれは日本語だけの長い文章で、六十文字を超えるかどうかを確認するための文章ですよ。さらにもう少しだけ続けて百二十文字も超えるようにしてみましょう、まだまだ続きます。",
    "　　全角スペースで始まる文。  半角スペースの文。\t\tタブの文。",
]
POOL = list("あいうえおかきくけこさしすせそたちつてとなにぬねの今日は天気がい散歩へ行く学校先生友達雨猫窓辺")
POOL += list("。。、、！？「」（）『』【】,.!?()\"'") + list("  \n\t　") + list("abcXYZ0123２３ＡＢ") + ["https://a.b/c", "x@y.zz", "`code`", "゙", "‍", "️", "😀", "\r\n", "…", "ー"]
for _ in range(400):
    texts.append("".join(rng.choice(POOL) for _ in range(rng.randint(1, 90))))
# fuzz built from natural phrases joined by punctuation (more candidates survive the filters)
PH = ["今日は天気がいい", "友達と一緒に出かけた", "新しいカフェで朝ごはんを食べた", "雨が降っていたにもかかわらず", "傘を持たずに", "公園を散歩した", "彼の話を聞いて", "思わず耳を疑った", "とても楽しかった", "また行きたいと思う"]
for _ in range(250):
    parts = []
    for _ in range(rng.randint(1, 7)):
        parts.append(rng.choice(PH) + rng.choice(["、", "。", "！", "。\n", "、", "？", "」", "。」"]))
    texts.append("".join(parts))

selection = []
for ti, t in enumerate(texts):
    for unit in ("phrase", "sentence"):
        for ratio in (0.1, 0.3, 0.5, 0.7):
            seed = rng.choice([0, 0, 0, 7])
            mx = rng.choice([None, 24, 2])
            try:
                sel = select_spans(t, ratio, unit, seed=seed, max_spans=mx)
            except Exception as e:  # noqa: BLE001
                selection.append({"t": ti, "unit": unit, "ratio": ratio, "seed": seed, "max": mx, "error": type(e).__name__})
                continue
            selection.append({"t": ti, "unit": unit, "ratio": ratio, "seed": seed, "max": mx,
                              "spans": [[s.id, s.start, s.end, s.source] for s in sel.spans],
                              "candidates": sel.candidates, "actual": sel.actual_ratio})
counted = [counted_length(t) for t in texts]

# ---- validation vectors
def span_for(text, source):
    i = text.find(source)
    return Span("s1", i, i + len(source), source)

ENS = ["", " ", "Hello.", "hello\nworld", "日本語 mixed", "x" * 200, "Here is the translation: hi", "Sure, here you go", "Sure, I will", "```code```",
       "[name] said", "He said {x}", "a <b> c", "___", "12345", "Page 15.", "In 2015 it", "It was 15.5 degrees", "see https://example.com/guide?id=42 now",
       "mail me at support@example.com", "3D movie", "since 1990s", "a​b", "a‮b", "ok‍ok", "…", "Mr. Yamada", "the cat is sleeping",
       "I went to the cinema.", "Kyoto", "ＡＢＣ", "A-1234", "Translation: hi", "English: hi", "ｱｲｳ", "ＡＢＣ商事",
       "a" * 99, "a" * 100, "a" * 101, "a" * 160, "a" * 161, "ab " * 40]
validation = []
for t in texts[:30]:
    cands = candidates(t, "phrase")
    for s in cands[:3]:
        out = outside_text(t, s)
        for en in ENS:
            validation.append({"source": s.source, "en": en, "outside": out, "verdict": validate_translation(s.source, en, outside=out)})
sources = ["詳しくは https://example.com/guide?id=42 を", "予約番号は A-1234 です", "価格は1,200円です", "3Dの映像", "連絡してください support@example.com", "`code` を実行"]
for src in sources:
    for en in ENS + ["see https://example.com/guide?id=42", "reservation number is A-1234", "price is 1,200 yen", "price is 11,200 yen", "3D video", "contact support@example.com", "run `code`", "Please contact us at support@example.com"]:
        for outside in ["", "別の文 https://other.example/x\n", "連絡は a@b.cc まで\n", "合計 15 個\n", "`rm -rf` と書く\n"]:
            validation.append({"source": src, "en": en, "outside": outside, "verdict": validate_translation(src, en, outside=outside)})
for _ in range(1500):
    src = "".join(rng.choice(POOL) for _ in range(rng.randint(1, 20)))
    en = "".join(rng.choice(list("abcdefgXYZ .,;:!?-'\"()[]{}<>_0123456789\n\t") + ["日本", "é", "​", "‍", "https://x.y/z", "a@b.cc", "15", "…"]) for _ in range(rng.randint(0, 30)))
    out = "".join(rng.choice(POOL) for _ in range(rng.randint(0, 20)))
    validation.append({"source": src, "en": en, "outside": out, "verdict": validate_translation(src, en, outside=out)})


# ---- card validation vectors (backend/define.py parse_card)
STRS = ["take", "took", "食べる", "", " ", "a b", "  spaced   out  ", "x" * 41, "x" * 40, "well-known", "it\u2019s", "A1", "\u200bzw", "a\u200db", "ctrl\x01", "line\nbreak", "日本語の説明です", "持つ", "取る", "あ" * 16,
        "あ" * 41, "n" * 81, "n" * 80, "e" * 121, "e" * 120, "a\u202eb", "soft\u00adhyphen", "tab\there"]
INTS = [0, 1, 2, 3, 4, 5, -1, 99, 1.0, 0.0, True, False, "1", None, 2.5]
def rs(): return rng.choice(STRS)
def maybe(v, p=0.8): return v if rng.random() < p else rng.choice([None, 1, True, [], {}, "", "x"])
def gloss_item(): return rng.choice([{"gloss": rs()}, rs(), {"x": 1}, None, 5, {"gloss": None}, {"gloss": 3}])
def ex(): return rng.choice([{"en": rs(), "ja": rs()}, {"en": rs()}, {"ja": rs()}, None, "x", {"en": ""}, {}])
def pt(): return rng.choice([{"expr": rs(), "note": rs()}, {"expr": rs()}, {"note": rs()}, None, "x", {"expr": ""}])
cards = []
CTX = ["私は昼ご飯を食べた", "", "彼は本を持っている", "食べる", "x"]
for _ in range(2500):
    kind = rng.choice(["word", "phrase"]); detail = rng.choice(["basic", "more"])
    d = {}
    if kind == "word" and detail == "basic":
        d = {"matchInSource": maybe(rng.choice(["食べ", "昼ご飯", "持って", "", "ない語", rs()])), "senses": maybe([gloss_item() for _ in range(rng.randint(0, 7))]),
             "contextIndex": maybe(rng.choice(INTS)), "lemma": maybe(rng.choice(["take", "took", "it\u2019s", "x" * 41, "", "日本", "A-b", "a b", "1a", "well-known", "I'm"])), "pos": maybe(rs())}
    elif kind == "word":
        d = {"example": maybe(ex()), "phrases": maybe([rs() for _ in range(rng.randint(0, 6))] + rng.choice([[], [None], [3]])), "note": maybe(rs())}
    elif detail == "basic":
        d = {"meaning": maybe(rs()), "nuance": maybe(rs())}
    else:
        d = {"points": maybe([pt() for _ in range(rng.randint(0, 4))]), "synonyms": maybe([rs() for _ in range(rng.randint(0, 5))]), "example": maybe(ex())}
    for k in list(d):
        if rng.random() < 0.08: del d[k]
    content = rng.choice([json.dumps(d, ensure_ascii=False)] * 12 + ["not json", "[]", "null", "5", '"x"', "{", ""])
    ctx = rng.choice(CTX)
    cards.append({"kind": kind, "detail": detail, "content": content, "ctx": ctx, "card": parse_card(kind, content, detail, ctx)})

# ---- assemble + display vectors
EN_POOL = ["Hello.", "the weather is nice.", "I am here", "Mr. Yamada", "U.S. policy.", "J.", "Tom and Jerry", "The Beatles", "A Clockwork Orange", "We went.", "It's fine.",
           "Kyoto Station.", "3.", "to meet his friends.", "And so,", "so, Tom left.", "etc.", "Dr.", "bad\nline", "日本語", "", "He said \"hi.\"", "I think so.", "She is here.", "ok..", "wait…", "Is it?"]
assembly = []
for ti, t in enumerate(texts[:700]):
    for unit in ("phrase", "sentence"):
        try:
            sel = select_spans(t, 0.5, unit, max_spans=24)
        except Exception:  # noqa: BLE001
            continue
        if not sel.spans:
            continue
        tr = {s.id: rng.choice(EN_POOL) for s in sel.spans}
        if rng.random() < 0.3 and tr:
            del tr[rng.choice(list(tr))]
        try:
            segs = assemble(t, sel.spans, tr)
            disp = format_segments(t, segs)
            res = {"segments": [[s.kind, s.text, s.display, s.source, s.start, s.end] for s in disp],
                   "joined": joined(disp), "preserved": outside_preserved(t, disp)}
        except (SpanError, AssertionError) as e:
            res = {"error": type(e).__name__}
        assembly.append({"t": ti, "spans": [[s.id, s.start, s.end, s.source] for s in sel.spans], "translations": tr, **res})

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump({"texts": texts, "selection": selection, "counted": counted, "validation": validation, "assembly": assembly, "cards": cards}, f, ensure_ascii=False, separators=(",", ":"))
print("cards", len(cards), sum(1 for c in cards if c["card"]), "selection", len(selection), "counted", len(counted), "validation", len(validation), "assembly", len(assembly), "bytes", os.path.getsize(OUT))
