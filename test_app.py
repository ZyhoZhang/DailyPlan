#!/usr/bin/env python3
"""End-to-end tests for Daily Plan.

Starts a real server against a throwaway DAILY_PLAN_HOME, exercises every
endpoint over HTTP, and checks the JSON state and the Markdown logs on disk.

    python3 test_app.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta

ROOT = os.path.dirname(os.path.abspath(__file__))
PORT = 8791
BASE = "http://127.0.0.1:{}".format(PORT)

PASS = FAIL = 0
FAILURES = []


def check(label, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("  ok   " + label)
    else:
        FAIL += 1
        FAILURES.append(label + ((" — " + detail) if detail else ""))
        print("  FAIL " + label + ((" — " + detail) if detail else ""))


def call(path, method="GET", body=None, expect_status=200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            status, payload = res.status, json.loads(res.read().decode())
    except urllib.error.HTTPError as err:
        status, payload = err.code, json.loads(err.read().decode())
    if expect_status is not None and status != expect_status:
        raise AssertionError("{} {} -> {} (expected {}): {}".format(
            method, path, status, expect_status, payload))
    return payload


def wait_for_server():
    for _ in range(60):
        try:
            urllib.request.urlopen(BASE + "/api/state", timeout=1).read()
            return True
        except Exception:
            time.sleep(0.2)
    return False


def read_log(home, day):
    path = os.path.join(home, "logs", day + ".md")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def main():
    home = tempfile.mkdtemp(prefix="dailyplan-test-")
    env = dict(os.environ, DAILY_PLAN_HOME=home)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "app.py"), "--port", str(PORT), "--no-browser"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    try:
        if not wait_for_server():
            out = proc.stdout.read() if proc.stdout else ""
            print("server never came up:\n" + out)
            return 1

        today = date.today().isoformat()
        yesterday = (date.today() - timedelta(days=1)).isoformat()

        print("\n[1] initial state")
        s = call("/api/state")
        check("defaults to today", s["day"] == today, s["day"])
        check("starts with no goals", s["entry"]["goals"] == [])
        check("starts at zero", s["stats"]["total"] == 0)
        check("starts at Novice", s["stats"]["rank"]["name"] == "Novice")
        check("serves index.html",
              b"Daily Plan" in urllib.request.urlopen(BASE + "/").read())

        print("\n[2] adding goals")
        s = call("/api/goals", "POST", {"date": today, "titles": ["Write intro", "Run regressions", "Email advisor"]})
        goals = s["entry"]["goals"]
        check("three goals added", len(goals) == 3, str(len(goals)))
        check("all start pending", all(g["status"] == "pending" for g in goals))
        check("ids are unique", len({g["id"] for g in goals}) == 3)
        check("order preserved", [g["title"] for g in goals][0] == "Write intro")
        s = call("/api/goals", "POST", {"date": today, "title": "Single via title"})
        check("single-title form works", len(s["entry"]["goals"]) == 4)
        call("/api/goals", "POST", {"date": today, "titles": ["   ", ""]}, expect_status=400)
        check("blank goals rejected", True)

        print("\n[2b] duplicate goals")
        before = len(s["entry"]["goals"])
        s = call("/api/goals", "POST", {"date": today, "titles": ["Write intro"]})
        check("exact duplicate skipped", len(s["entry"]["goals"]) == before, str(len(s["entry"]["goals"])))
        check("skip reported", s["skipped"] == 1 and s["added"] == 0)
        s = call("/api/goals", "POST", {"date": today, "titles": ["  write INTRO  "]})
        check("case/space duplicate skipped", len(s["entry"]["goals"]) == before)
        s = call("/api/goals", "POST", {"date": today, "titles": ["Write intro", "Genuinely new"]})
        check("mixed batch adds only the new one", len(s["entry"]["goals"]) == before + 1)
        check("mixed batch counts reported", s["added"] == 1 and s["skipped"] == 1)
        s = call("/api/goals", "POST", {"date": today, "titles": ["Dup me", "Dup me"]})
        check("duplicates within one batch collapsed", s["added"] == 1 and s["skipped"] == 1)
        s = call("/api/goals", "POST", {"date": yesterday, "titles": ["Write intro"]})
        check("same title allowed on a different day",
              any(g["title"] == "Write intro" for g in s["entry"]["goals"]))
        call("/api/goal", "DELETE",
             {"date": yesterday, "id": [g for g in s["entry"]["goals"] if g["title"] == "Write intro"][0]["id"]})
        s = call("/api/state?date=" + today)
        for title in ("Genuinely new", "Dup me"):
            gid_tmp = [g for g in s["entry"]["goals"] if g["title"] == title][0]["id"]
            s = call("/api/goal", "DELETE", {"date": today, "id": gid_tmp})
        check("scratch goals cleaned up", len(s["entry"]["goals"]) == 4, str(len(s["entry"]["goals"])))

        print("\n[3] status cycling and scoring")
        gid = s["entry"]["goals"][0]["id"]
        s = call("/api/goal", "PATCH", {"date": today, "id": gid, "status": "done"})
        check("marking done scores 1", s["stats"]["total"] == 1, str(s["stats"]["total"]))
        check("completedAt stamped", s["entry"]["goals"][0]["completedAt"] is not None)
        s = call("/api/goal", "PATCH", {"date": today, "id": gid, "status": "unfinished"})
        check("unfinished scores 0", s["stats"]["total"] == 0)
        check("completedAt cleared", s["entry"]["goals"][0]["completedAt"] is None)
        s = call("/api/goal", "PATCH", {"date": today, "id": gid, "status": "pending"})
        check("back to pending", s["entry"]["goals"][0]["status"] == "pending")
        call("/api/goal", "PATCH", {"date": today, "id": gid, "status": "bogus"}, expect_status=400)
        check("invalid status rejected", True)
        call("/api/goal", "PATCH", {"date": today, "id": 99999, "status": "done"}, expect_status=404)
        check("unknown goal id 404s", True)

        print("\n[4] editing, notes, reorder, delete")
        s = call("/api/goal", "PATCH", {"date": today, "id": gid, "title": "Write introduction"})
        check("title edited", s["entry"]["goals"][0]["title"] == "Write introduction")
        s = call("/api/goal", "PATCH", {"date": today, "id": gid, "note": "Section 1 only"})
        check("note saved", s["entry"]["goals"][0]["note"] == "Section 1 only")
        call("/api/goal", "PATCH", {"date": today, "id": gid, "title": "   "}, expect_status=400)
        check("empty title rejected", True)

        s = call("/api/goal/move", "POST", {"date": today, "id": gid, "direction": "down"})
        check("moved down", s["entry"]["goals"][1]["id"] == gid)
        s = call("/api/goal/move", "POST", {"date": today, "id": gid, "direction": "up"})
        check("moved up", s["entry"]["goals"][0]["id"] == gid)
        s = call("/api/goal/move", "POST", {"date": today, "id": gid, "direction": "up"})
        check("move past top is a no-op", s["entry"]["goals"][0]["id"] == gid)

        last = s["entry"]["goals"][-1]["id"]
        s = call("/api/goal", "DELETE", {"date": today, "id": last})
        check("goal deleted", len(s["entry"]["goals"]) == 3)
        check("deleted id gone", all(g["id"] != last for g in s["entry"]["goals"]))

        print("\n[5] markdown log")
        call("/api/goal", "PATCH", {"date": today, "id": gid, "status": "done"})
        md = read_log(home, today)
        check("log file written", md is not None)
        check("done goal marked [x]", "[x] Write introduction" in md, repr(md))
        check("note indented under goal", "Section 1 only" in md)
        check("score line present", "1 / 3 goals completed" in md, repr(md))
        check("pending goals marked [ ]", "[ ] Run regressions" in md)
        index = read_log(home, "README")
        check("index written", index is not None)
        check("index links the day", "({}.md)".format(today) in index)

        print("\n[6] reflection")
        s = call("/api/reflection", "PUT", {"date": today, "text": "Good focus in the morning."})
        check("reflection stored", s["entry"]["reflection"] == "Good focus in the morning.")
        check("reflection in markdown", "Good focus in the morning." in read_log(home, today))
        s = call("/api/reflection", "PUT", {"date": today, "text": ""})
        check("reflection can be cleared", s["entry"]["reflection"] == "")

        print("\n[7] carry over")
        call("/api/goals", "POST", {"date": yesterday, "titles": ["Finished thing", "Leftover thing"]})
        y = call("/api/state?date=" + yesterday)
        call("/api/goal", "PATCH", {"date": yesterday, "id": y["entry"]["goals"][0]["id"], "status": "done"})
        s = call("/api/goal/carry", "POST", {"date": today, "from": yesterday})
        check("one goal carried", s["carried"] == 1, str(s["carried"]))
        titles = [g["title"] for g in s["entry"]["goals"]]
        check("leftover carried in", "Leftover thing" in titles)
        check("completed not carried", "Finished thing" not in titles)
        carried = [g for g in s["entry"]["goals"] if g["title"] == "Leftover thing"][0]
        check("carry marked pending", carried["status"] == "pending")
        check("carry provenance recorded", carried.get("carriedFrom") == yesterday)
        s = call("/api/goal/carry", "POST", {"date": today, "from": yesterday})
        check("carry is idempotent", s["carried"] == 0, str(s["carried"]))
        call("/api/goal/carry", "POST", {"date": today, "from": today}, expect_status=400)
        check("carry into self rejected", True)

        print("\n[8] streaks and stats")
        s = call("/api/state")
        check("streak counts both days", s["stats"]["currentStreak"] == 2,
              str(s["stats"]["currentStreak"]))
        check("total is 2", s["stats"]["total"] == 2, str(s["stats"]["total"]))
        check("longest streak is 2", s["stats"]["longestStreak"] == 2)
        check("best day recorded", s["stats"]["bestDay"]["score"] == 1)

        old = (date.today() - timedelta(days=30)).isoformat()
        call("/api/goals", "POST", {"date": old, "titles": ["Ancient goal"]})
        o = call("/api/state?date=" + old)
        call("/api/goal", "PATCH", {"date": old, "id": o["entry"]["goals"][0]["id"], "status": "done"})
        s = call("/api/state")
        check("gap does not extend streak", s["stats"]["currentStreak"] == 2,
              str(s["stats"]["currentStreak"]))
        check("total includes old day", s["stats"]["total"] == 3)

        print("\n[9] ranks")
        for total, expected in [(0, "Novice"), (9, "Novice"), (10, "Apprentice"),
                                (25, "Journeyman"), (50, "Adept"), (100, "Expert"),
                                (200, "Master"), (350, "Grandmaster"), (600, "Legend"),
                                (1000, "Mythic"), (5000, "Mythic")]:
            sys.path.insert(0, ROOT)
            import app as appmod
            r = appmod.rank_for(total)
            check("rank at {} is {}".format(total, expected), r["name"] == expected, r["name"])
        r = appmod.rank_for(5000)
        check("max rank has no next", r["next"] is None and r["progress"] == 1.0)
        r = appmod.rank_for(0)
        check("progress at floor is 0", r["progress"] == 0.0)

        print("\n[10] deadlines")
        s = call("/api/deadlines", "POST", {"title": "JMP draft", "due": "2026-12-01"})
        check("deadline added", len(s["deadlines"]) == 1)
        check("bare date gets 23:59", s["deadlines"][0]["due"] == "2026-12-01T23:59",
              s["deadlines"][0]["due"])
        s = call("/api/deadlines", "POST", {"title": "Seminar", "due": "2026-09-15T14:30"})
        check("datetime preserved", s["deadlines"][1]["due"] == "2026-09-15T14:30" or
              s["deadlines"][0]["due"] == "2026-09-15T14:30")
        check("deadlines sorted by due",
              [d["due"] for d in s["deadlines"]] == sorted(d["due"] for d in s["deadlines"]))
        dl_id = [d for d in s["deadlines"] if d["title"] == "Seminar"][0]["id"]
        s = call("/api/deadline", "PATCH", {"id": dl_id, "title": "Seminar talk", "note": "30 min"})
        seminar = [d for d in s["deadlines"] if d["id"] == dl_id][0]
        check("deadline edited", seminar["title"] == "Seminar talk" and seminar["note"] == "30 min")
        call("/api/deadlines", "POST", {"title": "Bad", "due": "not-a-date"}, expect_status=400)
        check("bad due date rejected", True)
        call("/api/deadlines", "POST", {"title": "", "due": "2026-12-01"}, expect_status=400)
        check("empty deadline title rejected", True)
        check("deadlines in index", "Seminar talk" in read_log(home, "README"))
        s = call("/api/deadline", "DELETE", {"id": dl_id})
        check("deadline deleted", len(s["deadlines"]) == 1)
        call("/api/deadline", "DELETE", {"id": dl_id}, expect_status=404)
        check("deleting twice 404s", True)

        print("\n[11] history")
        h = call("/api/history")
        check("history has three days", len(h["days"]) == 3, str(len(h["days"])))
        check("history newest first", h["days"][0]["date"] >= h["days"][1]["date"])
        check("history carries stats", h["stats"]["total"] == 3)

        print("\n[12] validation and errors")
        call("/api/state?date=2026-13-45", expect_status=400)
        check("impossible date rejected", True)
        call("/api/state?date=nonsense", expect_status=400)
        check("malformed date rejected", True)
        call("/api/goals", "POST", {"date": "07/04/2026", "titles": ["x"]}, expect_status=400)
        check("non-ISO date rejected", True)
        call("/api/nope", "GET", expect_status=404)
        check("unknown endpoint 404s", True)
        req = urllib.request.Request(BASE + "/api/goals", data=b"{not json",
                                     method="POST", headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=5)
            check("malformed JSON rejected", False, "no error raised")
        except urllib.error.HTTPError as err:
            check("malformed JSON rejected", err.code == 400, str(err.code))

        print("\n[13] persistence across restart")
        with open(os.path.join(home, "data", "state.json"), encoding="utf-8") as fh:
            disk = json.load(fh)
        check("state.json holds days", today in disk["days"])
        check("state.json holds deadlines", len(disk["deadlines"]) == 1)
        check("backup written", os.path.exists(os.path.join(home, "data", "state.json.bak")))

        proc.terminate()
        proc.wait(timeout=10)
        proc = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "app.py"), "--port", str(PORT), "--no-browser"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        check("server restarts", wait_for_server())
        s = call("/api/state")
        check("score survives restart", s["stats"]["total"] == 3, str(s["stats"]["total"]))
        check("goals survive restart", len(s["entry"]["goals"]) == 4)
        check("deadlines survive restart", len(s["deadlines"]) == 1)
        s = call("/api/goals", "POST", {"date": today, "titles": ["After restart"]})
        ids = [g["id"] for g in s["entry"]["goals"]]
        check("ids stay unique after restart", len(ids) == len(set(ids)))

        print("\n[14] empty-day cleanup")
        scratch = (date.today() + timedelta(days=5)).isoformat()
        s = call("/api/goals", "POST", {"date": scratch, "titles": ["Temp"]})
        check("future day log written", read_log(home, scratch) is not None)
        call("/api/goal", "DELETE", {"date": scratch, "id": s["entry"]["goals"][0]["id"]})
        check("emptied day log removed", read_log(home, scratch) is None)

        print("\n[15] unicode and long input")
        s = call("/api/goals", "POST", {"date": today, "titles": ["写论文 — «σ» 📈"]})
        check("unicode round-trips", "写论文 — «σ» 📈" in [g["title"] for g in s["entry"]["goals"]])
        check("unicode in markdown", "写论文" in read_log(home, today))
        s = call("/api/goals", "POST", {"date": today, "titles": ["x" * 900]})
        longest = max((g["title"] for g in s["entry"]["goals"]), key=len)
        check("long title truncated to 500", len(longest) == 500, str(len(longest)))

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(home, ignore_errors=True)

    print("\n" + "=" * 60)
    print("{} passed, {} failed".format(PASS, FAIL))
    if FAILURES:
        print("\nFailures:")
        for f in FAILURES:
            print("  - " + f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
