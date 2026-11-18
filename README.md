# Paper Companion

A Mac app for reading research papers with Claude. Select a passage, ask a question, and get an
answer composed from the paper itself: every quote is the paper's own words, highlighted in the same
color as its source and joined to it by a beam. Design: Figma file "Preview_v2", direction D "Parallel space".

Rule of the look: anything the authors wrote is paper; anything the AI made is Liquid Glass.

## Run it

```bash
scripts/build-app.sh
open "build/Paper Companion.app"
```

The first time you ask a question, the app asks for your Claude API key and saves it in the Keychain.
(Menu: Paper Companion → Claude API Key… to change it.)

## How it works

- `PaperIndex.swift` cleans each page's text (joins hyphenated line breaks, ligatures, spacing) and keeps a
  map back to the PDF's characters. Claude sees the cleaned text; its quotes are found in the same text and
  turned back into real PDF selections. Quotes that can't be found are marked, never linked.
- `ClaudeClient.swift` calls `claude-opus-5-5` over HTTPS with streaming and structured outputs
  (a JSON schema for prose / heading / quote / instrument blocks). The paper sits in a cached system prompt.
- `AppModel.swift` holds threads. Compose starts a thread, Extend appends, Rewrite and Branch add versions.
- Threads are saved per PDF (by file hash) in `~/Library/Application Support/Paper Companion/Threads/`.
- `Beams.swift` draws ribbons beneath the glass sheet and glass beads on top.

## Test flags

- `PaperCompanion --selftest <pdf>` checks that known sentences are found in the sample paper.
- `--open <pdf> --demo` runs a canned answer through the real pipeline (no API call, nothing saved).

`SamplePaper/` has the LaTeX source of the fictional sample paper (`Resources/sparse-routing-attention.pdf`).
