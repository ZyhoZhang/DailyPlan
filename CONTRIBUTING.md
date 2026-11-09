# Contributing

Daily Plan has a SwiftUI app and a Python/web companion. Keep their state
schema and rank tables compatible.

## Development

- Native: macOS 14+, Xcode Command Line Tools, Python 3 for cross-process tests.
- Web: Python 3.9+ on macOS or Linux. No runtime packages.
- Browser tests: Google Chrome and requirements-dev.txt.

~~~sh
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements-dev.txt
./test_native.sh
python3 test_app.py
python3 test_storage.py
./test_ui.sh
~~~

Tests use temporary, synthetic data. Never use real history as a fixture.
For manual testing, set DAILY_PLAN_HOME to a separate directory.

Include focused regression tests. Keep the shared state.lock held throughout
each read-modify-write operation. Never lock state.json itself: atomic
replacement changes its inode. For UI changes, test Cancel, keyboard shortcuts,
repeated actions and save failures.

Do not commit personal history, logs, credentials, signing material or build
outputs. Screenshots should contain synthetic data only.

A license has not been selected. The maintainer must choose one before
describing this project as open source or accepting contributions under a
specific license.

## Further reading

- [Developer guide](docs/DEVELOPMENT.md): test coverage and source layout.
- [Web companion](docs/WEB_COMPANION.md): local web setup.
