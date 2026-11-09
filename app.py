#!/usr/bin/env python3
"""Daily Plan — a local goal tracker with a heroic score panel and deadline countdowns.

Run:  python3 app.py          (then open http://127.0.0.1:8777)
      python3 app.py --port 9000 --no-browser

Storage layout (all inside this folder, so the whole app is one portable directory):

    data/state.json        source of truth (days, goals, deadlines, meta)
    logs/YYYY-MM-DD.md     human-readable Markdown log, regenerated on every write
    static/index.html      the UI
"""

import argparse
import fcntl
from contextlib import contextmanager
import json
import os
import re
import shutil
import threading
import webbrowser
from datetime import date, datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(ROOT, "static")

# When launched from DailyPlan.app the code lives inside the bundle, so data
# must be written somewhere durable instead. DAILY_PLAN_HOME points there.
HOME = os.path.abspath(os.environ.get("DAILY_PLAN_HOME") or ROOT)
DATA_DIR = os.path.join(HOME, "data")
LOGS_DIR = os.path.join(HOME, "logs")
STATE_PATH = os.path.join(DATA_DIR, "state.json")

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
STATUSES = ("pending", "done", "unfinished")

# Serialize threads locally and coordinate with native/other web processes
# using the same POSIX state.lock file for the full read-modify-write cycle.
LOCK = threading.Lock()

EMPTY_STATE = {
    "version": 1,
    "days": {},       # "YYYY-MM-DD" -> {"goals": [...], "reflection": str}
    "deadlines": [],  # [{"id", "title", "due", "note"}]
    "nextId": 1,
}


# ---------------------------------------------------------------------------
# state io
# ---------------------------------------------------------------------------


@contextmanager
def state_lock():
    """POSIX process lock shared with the native macOS app."""
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(os.path.join(DATA_DIR, "state.lock"), "a+b") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def load_state():
    if not os.path.exists(STATE_PATH):
        return json.loads(json.dumps(EMPTY_STATE))
    with open(STATE_PATH, "r", encoding="utf-8") as fh:
        state = json.load(fh)
    for key, default in EMPTY_STATE.items():
        state.setdefault(key, json.loads(json.dumps(default)))
    return state


def save_state(state):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, STATE_PATH)


def backup_state():
    """Keep one rolling backup so a bad write is never fatal."""
    if os.path.exists(STATE_PATH):
        shutil.copyfile(STATE_PATH, STATE_PATH + ".bak")


def take_id(state):
    n = int(state.get("nextId", 1))
    state["nextId"] = n + 1
    return n


# ---------------------------------------------------------------------------
# derived values
# ---------------------------------------------------------------------------

def day_entry(state, day):
    return state["days"].setdefault(day, {"goals": [], "reflection": ""})


def score_of(goals):
    return sum(1 for g in goals if g.get("status") == "done")


def compute_stats(state):
    """Total score, per-day scores, current streak, longest streak, best day."""
    days = state["days"]
    per_day = {}
    for day, entry in days.items():
        per_day[day] = score_of(entry.get("goals", []))

    total = sum(per_day.values())
    today = date.today().isoformat()

    # A day counts toward a streak if it has at least one completed goal.
    scored_days = sorted(d for d, s in per_day.items() if s > 0)
    scored_set = set(scored_days)

    def prev_day(d):
        return date.fromisoformat(d).toordinal() - 1

    # Current streak: walk back from today (or yesterday, if today is still empty).
    current = 0
    cursor = date.today().toordinal()
    if today not in scored_set:
        cursor -= 1
    while date.fromordinal(cursor).isoformat() in scored_set:
        current += 1
        cursor -= 1

    longest = 0
    run = 0
    prev_ord = None
    for d in scored_days:
        d_ord = date.fromisoformat(d).toordinal()
        run = run + 1 if prev_ord is not None and d_ord == prev_ord + 1 else 1
        longest = max(longest, run)
        prev_ord = d_ord

    best_day = max(per_day.items(), key=lambda kv: (kv[1], kv[0]), default=("", 0))

    goals_all = [g for e in days.values() for g in e.get("goals", [])]
    return {
        "total": total,
        "today": per_day.get(today, 0),
        "todayGoals": len(days.get(today, {}).get("goals", [])),
        "currentStreak": current,
        "longestStreak": longest,
        "bestDay": {"date": best_day[0], "score": best_day[1]},
        "daysTracked": len([d for d in per_day if days[d].get("goals")]),
        "goalsTotal": len(goals_all),
        "goalsDone": sum(1 for g in goals_all if g.get("status") == "done"),
        "perDay": per_day,
        "rank": rank_for(total),
    }


RANKS = [
    (0, "Novice"),
    (10, "Apprentice"),
    (25, "Journeyman"),
    (50, "Adept"),
    (100, "Expert"),
    (200, "Master"),
    (350, "Grandmaster"),
    (600, "Legend"),
    (1000, "Mythic"),
]


def rank_for(total):
    name = RANKS[0][1]
    idx = 0
    for i, (threshold, label) in enumerate(RANKS):
        if total >= threshold:
            name, idx = label, i
    floor = RANKS[idx][0]
    ceiling = RANKS[idx + 1][0] if idx + 1 < len(RANKS) else None
    if ceiling is None:
        progress = 1.0
    else:
        span = ceiling - floor
        progress = (total - floor) / span if span else 1.0
    return {
        "name": name,
        "level": idx + 1,
        "floor": floor,
        "next": ceiling,
        "nextName": RANKS[idx + 1][1] if ceiling is not None else None,
        "progress": round(max(0.0, min(1.0, progress)), 4),
    }


# ---------------------------------------------------------------------------
# markdown log
# ---------------------------------------------------------------------------

STATUS_MARK = {"done": "[x]", "pending": "[ ]", "unfinished": "[~]"}
STATUS_WORD = {"done": "done", "pending": "pending", "unfinished": "unfinished"}


def write_markdown(state, day):
    """Regenerate logs/<day>.md from state. Removes the file if the day is empty."""
    os.makedirs(LOGS_DIR, exist_ok=True)
    path = os.path.join(LOGS_DIR, day + ".md")
    entry = state["days"].get(day)
    if not entry or (not entry.get("goals") and not entry.get("reflection")):
        if os.path.exists(path):
            os.remove(path)
        return

    goals = entry.get("goals", [])
    done = score_of(goals)
    pretty = datetime.strptime(day, "%Y-%m-%d").strftime("%A, %d %B %Y")

    lines = ["# " + day + " — " + pretty, ""]
    lines.append("**Score:** {} / {} goals completed".format(done, len(goals)))
    lines.append("")
    if goals:
        lines.append("## Goals")
        lines.append("")
        for g in goals:
            mark = STATUS_MARK.get(g.get("status", "pending"), "[ ]")
            lines.append("- {} {}".format(mark, g.get("title", "")))
            if g.get("note"):
                for note_line in str(g["note"]).splitlines():
                    lines.append("      " + note_line)
        lines.append("")
    if entry.get("reflection"):
        lines.append("## Reflection")
        lines.append("")
        lines.append(entry["reflection"].strip())
        lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("_Legend: `[x]` done · `[ ]` pending · `[~]` unfinished._")
    lines.append("")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def write_summary(state, stats):
    """Regenerate logs/README.md — an index across every tracked day."""
    os.makedirs(LOGS_DIR, exist_ok=True)
    lines = ["# Daily Plan — log index", ""]
    lines.append("**Total score:** {}  ·  **Rank:** {}  ·  **Current streak:** {} day(s)  ·  "
                 "**Longest streak:** {} day(s)".format(
                     stats["total"], stats["rank"]["name"],
                     stats["currentStreak"], stats["longestStreak"]))
    lines.append("")
    lines.append("| Date | Score | Goals | Completion |")
    lines.append("| --- | ---: | ---: | ---: |")
    for day in sorted(state["days"], reverse=True):
        goals = state["days"][day].get("goals", [])
        if not goals:
            continue
        done = score_of(goals)
        pct = round(100 * done / len(goals))
        lines.append("| [{d}]({d}.md) | {s} | {n} | {p}% |".format(
            d=day, s=done, n=len(goals), p=pct))
    lines.append("")

    if state.get("deadlines"):
        lines.append("## Deadlines")
        lines.append("")
        lines.append("| Deadline | Due | Note |")
        lines.append("| --- | --- | --- |")
        for dl in sorted(state["deadlines"], key=lambda x: x.get("due", "")):
            lines.append("| {} | {} | {} |".format(
                dl.get("title", ""), dl.get("due", ""),
                (dl.get("note") or "").replace("|", "\\|")))
        lines.append("")

    with open(os.path.join(LOGS_DIR, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def persist(state, touched_days):
    """Save state, then regenerate the Markdown views it feeds."""
    backup_state()
    save_state(state)
    stats = compute_stats(state)
    for day in touched_days:
        write_markdown(state, day)
    write_summary(state, stats)
    return stats


# ---------------------------------------------------------------------------
# request handling
# ---------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status
        self.message = message


def require_day(value):
    if not isinstance(value, str) or not DATE_RE.match(value):
        raise ApiError("date must be YYYY-MM-DD, got: {!r}".format(value))
    try:
        date.fromisoformat(value)
    except ValueError:
        raise ApiError("not a real date: {}".format(value))
    return value


def require_text(value, field, max_len=500):
    text = (value or "").strip() if isinstance(value, str) else ""
    if not text:
        raise ApiError("{} cannot be empty".format(field))
    return text[:max_len]


def find_goal(state, day, goal_id):
    for goal in state["days"].get(day, {}).get("goals", []):
        if goal.get("id") == goal_id:
            return goal
    raise ApiError("goal {} not found on {}".format(goal_id, day), 404)


def snapshot(state, day):
    stats = compute_stats(state)
    return {
        "day": day,
        "entry": state["days"].get(day, {"goals": [], "reflection": ""}),
        "deadlines": sorted(state["deadlines"], key=lambda d: d.get("due", "")),
        "stats": stats,
        "serverTime": datetime.now().isoformat(timespec="seconds"),
    }


def handle_api(path, method, body):
    """Route one API call. Returns a JSON-serialisable dict."""
    with LOCK, state_lock():
        state = load_state()

        if path == "/api/state" and method == "GET":
            day = require_day(body.get("date") or date.today().isoformat())
            return snapshot(state, day)

        if path == "/api/goals" and method == "POST":
            day = require_day(body.get("date"))
            titles = body.get("titles")
            if not isinstance(titles, list):
                titles = [body.get("title")]
            entry = day_entry(state, day)
            # Same rule as carry-over: one goal per title per day.
            existing = {g.get("title", "").lower() for g in entry["goals"]}
            added = skipped = 0
            for raw in titles:
                text = (raw or "").strip() if isinstance(raw, str) else ""
                if not text:
                    continue
                if text.lower() in existing:
                    skipped += 1
                    continue
                existing.add(text.lower())
                entry["goals"].append({
                    "id": take_id(state),
                    "title": text[:500],
                    "status": "pending",
                    "note": "",
                    "createdAt": datetime.now().isoformat(timespec="seconds"),
                    "completedAt": None,
                })
                added += 1
            if not added and not skipped:
                raise ApiError("no goal text provided")
            persist(state, [day])
            result = snapshot(state, day)
            result["added"] = added
            result["skipped"] = skipped
            return result

        if path == "/api/goal" and method == "PATCH":
            day = require_day(body.get("date"))
            goal = find_goal(state, day, body.get("id"))
            if "status" in body:
                status = body["status"]
                if status not in STATUSES:
                    raise ApiError("status must be one of {}".format(", ".join(STATUSES)))
                goal["status"] = status
                goal["completedAt"] = (datetime.now().isoformat(timespec="seconds")
                                       if status == "done" else None)
            if "title" in body:
                goal["title"] = require_text(body["title"], "title")
            if "note" in body:
                goal["note"] = (body["note"] or "").strip()[:2000]
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/goal" and method == "DELETE":
            day = require_day(body.get("date"))
            goal = find_goal(state, day, body.get("id"))
            state["days"][day]["goals"].remove(goal)
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/goal/move" and method == "POST":
            day = require_day(body.get("date"))
            goal = find_goal(state, day, body.get("id"))
            goals = state["days"][day]["goals"]
            i = goals.index(goal)
            j = i + (1 if body.get("direction") == "down" else -1)
            if 0 <= j < len(goals):
                goals[i], goals[j] = goals[j], goals[i]
                persist(state, [day])
            return snapshot(state, day)

        if path == "/api/goal/carry" and method == "POST":
            # Copy every unfinished/pending goal from `from` into `date`.
            day = require_day(body.get("date"))
            source = require_day(body.get("from"))
            if source == day:
                raise ApiError("cannot carry a day into itself")
            entry = day_entry(state, day)
            existing = {g["title"] for g in entry["goals"]}
            moved = 0
            for goal in state["days"].get(source, {}).get("goals", []):
                if goal.get("status") == "done" or goal.get("title") in existing:
                    continue
                entry["goals"].append({
                    "id": take_id(state),
                    "title": goal.get("title", ""),
                    "status": "pending",
                    "note": goal.get("note", ""),
                    "createdAt": datetime.now().isoformat(timespec="seconds"),
                    "completedAt": None,
                    "carriedFrom": source,
                })
                moved += 1
            persist(state, [day])
            result = snapshot(state, day)
            result["carried"] = moved
            return result

        if path == "/api/reflection" and method == "PUT":
            day = require_day(body.get("date"))
            day_entry(state, day)["reflection"] = (body.get("text") or "").strip()[:5000]
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/deadlines" and method == "POST":
            day = require_day(body.get("date") or date.today().isoformat())
            state["deadlines"].append({
                "id": take_id(state),
                "title": require_text(body.get("title"), "deadline title", 200),
                "due": require_due(body.get("due")),
                "note": (body.get("note") or "").strip()[:500],
            })
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/deadline" and method == "PATCH":
            day = require_day(body.get("date") or date.today().isoformat())
            target = next((d for d in state["deadlines"] if d["id"] == body.get("id")), None)
            if target is None:
                raise ApiError("deadline not found", 404)
            if "title" in body:
                target["title"] = require_text(body["title"], "deadline title", 200)
            if "due" in body:
                target["due"] = require_due(body["due"])
            if "note" in body:
                target["note"] = (body["note"] or "").strip()[:500]
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/deadline" and method == "DELETE":
            day = require_day(body.get("date") or date.today().isoformat())
            before = len(state["deadlines"])
            state["deadlines"] = [d for d in state["deadlines"] if d["id"] != body.get("id")]
            if len(state["deadlines"]) == before:
                raise ApiError("deadline not found", 404)
            persist(state, [day])
            return snapshot(state, day)

        if path == "/api/history" and method == "GET":
            days = []
            for day in sorted(state["days"], reverse=True):
                goals = state["days"][day].get("goals", [])
                if not goals:
                    continue
                days.append({
                    "date": day,
                    "score": score_of(goals),
                    "total": len(goals),
                    "goals": goals,
                    "reflection": state["days"][day].get("reflection", ""),
                })
            return {"days": days, "stats": compute_stats(state)}

        raise ApiError("unknown endpoint: {} {}".format(method, path), 404)


def require_due(value):
    """Accept 'YYYY-MM-DD' or 'YYYY-MM-DDTHH:MM'; store as an ISO minute stamp."""
    if not isinstance(value, str) or not value.strip():
        raise ApiError("deadline needs a due date")
    text = value.strip()
    if DATE_RE.match(text):
        text += "T23:59"
    try:
        return datetime.fromisoformat(text).isoformat(timespec="minutes")
    except ValueError:
        raise ApiError("could not read due date: {}".format(value))


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def log_message(self, fmt, *args):
        if os.environ.get("DAILY_PLAN_VERBOSE"):
            super().log_message(fmt, *args)

    # -- helpers ---------------------------------------------------------
    def send_json(self, payload, status=200):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError("request body was not valid JSON")
        if not isinstance(parsed, dict):
            raise ApiError("request body must be a JSON object")
        return parsed

    def dispatch(self, method):
        path = urlparse(self.path).path
        if not path.startswith("/api/"):
            if method == "GET":
                return super().do_GET()
            self.send_error(405)
            return
        try:
            payload = handle_api(path, method, self.read_body())
            self.send_json(payload)
        except ApiError as err:
            self.send_json({"error": err.message}, err.status)
        except Exception as err:  # never let the UI hang on a server bug
            import traceback
            traceback.print_exc()
            self.send_json({"error": "server error: {}".format(err)}, 500)

    # -- verbs -----------------------------------------------------------
    def do_GET(self):
        path = urlparse(self.path).path
        if path.startswith("/api/"):
            # GET carries no body; /api/state reads its date from the query string.
            from urllib.parse import parse_qs
            query = parse_qs(urlparse(self.path).query)
            body = {k: v[0] for k, v in query.items()}
            try:
                self.send_json(handle_api(path, "GET", body))
            except ApiError as err:
                self.send_json({"error": err.message}, err.status)
            except Exception as err:
                import traceback
                traceback.print_exc()
                self.send_json({"error": "server error: {}".format(err)}, 500)
            return
        if path == "/":
            self.path = "/index.html"
        super().do_GET()

    def do_POST(self):
        self.dispatch("POST")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_DELETE(self):
        self.dispatch("DELETE")


def main():
    parser = argparse.ArgumentParser(description="Daily Plan — local goal tracker")
    parser.add_argument("--port", type=int, default=8777)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)
    with LOCK, state_lock():
        if not os.path.exists(STATE_PATH):
            save_state(load_state())

    url = "http://{}:{}".format(args.host, args.port)
    server = HTTPServer((args.host, args.port), Handler)
    print("Daily Plan running at {}".format(url))
    print("  data : {}".format(STATE_PATH))
    print("  logs : {}".format(LOGS_DIR))
    print("Press Ctrl+C to stop.")
    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.server_close()


if __name__ == "__main__":
    main()
