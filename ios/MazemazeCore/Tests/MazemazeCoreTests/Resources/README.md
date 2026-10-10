# ondevice_golden.json

Golden vectors for the Swift port of the span logic (`Sources/MazemazeCore/OnDevice`: `SpanSelector`, `SpanRules`,
`DisplayFormat`, `OnDeviceDefinition`). Every input was run through the original **Python** implementation
(`backend/selector.py`, `spans.py`, `display.py`, `define.py`) and the output was recorded; `OnDeviceGoldenTests`
requires the Swift code to reproduce every one exactly (~14k cases: span selection, ratio counting, translation
validation, assembly + display formatting, card validation).

The Python reference and the generator (`scripts/gen_ondevice_golden.py`) live on the branch **`mac-local-model`**
(the version of Mazemaze that used a Mac server). To regenerate (only needed if the logic is changed on purpose):

```bash
git worktree add ../mazemaze-mac mac-local-model
cd ../mazemaze-mac && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python scripts/gen_ondevice_golden.py     # rewrites this file inside that worktree
```

then copy the file back here. Changing the logic on purpose means these expectations change too: say why in the commit.
