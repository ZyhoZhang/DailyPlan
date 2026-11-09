# Web companion

Requires Python 3.9+ on macOS or Linux. No runtime packages are needed.
Keep the server on localhost; do not expose it to a network.

```bash
./build_app.sh          # creates dist/DailyPlan.app
./build_app.sh --dmg    # also creates dist/DailyPlan.dmg
```

Same double-click behaviour, but it starts a local server and opens a browser
tab. Launching it again while it's running re-opens the tab rather than
starting a second copy. You can also run it directly:

```bash
python3 app.py                 # http://127.0.0.1:8777
python3 app.py --port 9000 --no-browser
```

## Native and web builds

| | Native (recommended) | Web |
| --- | --- | --- |
| Build | `./build_native.sh` | `./build_app.sh` |
| Output | `dist-native/DailyPlan.app` | `dist/DailyPlan.app` |
| Runs as | Real Mac app, no browser | Python server + browser tab |
| Menu bar countdown | Yes | No |
| Notifications | Yes | No |
| Launch at login | Yes | No |
| Edit the UI | Swift, needs a rebuild | HTML, just reload |
