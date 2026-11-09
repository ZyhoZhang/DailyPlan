# Developer guide

Build, test and source-layout details for contributors.

## Tests

```bash
./test_native.sh        # Native logic and native/Python persistence
python3 test_app.py     # Web API
python3 test_storage.py # Corrupt-state and process-lock regressions
./test_ui.sh           # Isolated browser regression tests
```

`test_native.sh` covers the Swift store, scoring, streaks, rank table,
countdown maths, Markdown generation, note auto-save, drag reordering, and the
note editor's formatting commands. Critically it also asserts
**schema compatibility**: that Swift reads a Python-written `state.json`
unchanged and writes one Python can read back.

`test_app.py` starts a real server against a temporary directory and exercises
every endpoint, the scoring and streak logic, Markdown generation, validation,
and persistence across a restart.

`test_ui.py` drives the real UI in headless Chrome and asserts the page never
freezes. It deliberately never stubs `window.confirm`/`prompt` — if any code
path opens a native dialog, the page blocks and the test fails. Both suites use
their own throwaway data directory, so neither can touch your real history.

Install Google Chrome and the optional browser-test package in an isolated
environment:

~~~sh
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements-dev.txt
./test_ui.sh
~~~

The runner starts a separate headless profile with synthetic data. It does
not use your signed-in browser. CI runs native, API and storage checks;
browser tests remain an explicit local check.

## Changing it

**Native** — sources are in `native/DailyPlan/`, compiled directly with
`swiftc` (no `.xcodeproj`, so they stay ordinary editable files):

| File | What's in it |
| --- | --- |
| `Model.swift` | The on-disk types, rank table, date helpers |
| `Store.swift` | All mutations, persistence, Markdown generation |
| `Countdown.swift` | Urgency tiers, unit splitting, the shared ticker |
| `ContentView.swift` | The window UI |
| `NoteFormat.swift` | Note editing commands (lists, indent, bold, links) as pure functions |
| `NoteEditor.swift` | The note's text view: styling, shortcuts, link form |
| `DailyPlanApp.swift` | Entry point, menu bar, Feedback menu, Settings |
| `Notifier.swift` | Deadline alerts and daily reminders |

**Web** — `app.py` holds the storage and API, one function per endpoint in
`handle_api`; `static/index.html` is the whole UI in one file.

If you change the ranks, change them in **both** `RANKS` (app.py) and
`Ranks.table` (Model.swift) or the two builds will disagree — `test_native.sh`
asserts the tables match.
