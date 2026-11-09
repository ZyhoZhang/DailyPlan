#!/usr/bin/env python3
"""Persistence regressions. Every test uses a temporary, synthetic data home."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import app

ROOT = Path(__file__).resolve().parent
WRITER = """
import app, sys
for index in range(int(sys.argv[2])):
    app.handle_api('/api/goals', 'POST',
                   {'date': '2026-01-01', 'titles': [sys.argv[1] + str(index)]})
"""

class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dailyplan-storage-")
        self.home = Path(self.temp.name)
        self.data = self.home / "data"
        self.data.mkdir()
        self.path = self.data / "state.json"
        self.backup = self.data / "state.json.bak"
        self.patch = mock.patch.multiple(
            app, HOME=str(self.home), DATA_DIR=str(self.data),
            LOGS_DIR=str(self.home / "logs"), STATE_PATH=str(self.path))
        self.patch.start()
        self.env = dict(os.environ, DAILY_PLAN_HOME=str(self.home),
                        PYTHONDONTWRITEBYTECODE="1")

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def test_corrupt_state_preserves_original_and_backup(self):
        damaged = b"{damaged json"
        backup = json.dumps(app.EMPTY_STATE).encode()
        self.path.write_bytes(damaged)
        self.backup.write_bytes(backup)
        with self.assertRaises(json.JSONDecodeError):
            app.handle_api("/api/goals", "POST",
                           {"date": "2026-01-01", "titles": ["Not written"]})
        self.assertEqual(self.path.read_bytes(), damaged)
        self.assertEqual(self.backup.read_bytes(), backup)

    def test_multiple_python_processes_preserve_all_edits(self):
        children = [
            subprocess.Popen([sys.executable, "-c", WRITER, f"writer-{i}-", "40"],
                             cwd=ROOT, env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
            for i in range(4)
        ]
        try:
            for child in children:
                _, error = child.communicate(timeout=30)
                self.assertEqual(child.returncode, 0, error.decode())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.wait()
        state = json.loads(self.path.read_text())
        goals = state["days"]["2026-01-01"]["goals"]
        self.assertEqual(len(goals), 160)
        self.assertEqual(len({goal["id"] for goal in goals}), 160)
        self.assertEqual(len({goal["title"] for goal in goals}), 160)
        self.assertEqual(state["nextId"], 161)

    def test_python_writer_waits_for_shared_lock(self):
        with open(self.data / "state.lock", "a+b") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            child = subprocess.Popen(
                [sys.executable, "-c", "print('ready', flush=True)\n" + WRITER, "blocked-", "1"],
                cwd=ROOT, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertEqual(child.stdout.readline().strip(), b"ready")
                time.sleep(0.15)
                self.assertIsNone(child.poll())
                self.assertFalse(self.path.exists())
                fcntl.flock(held.fileno(), fcntl.LOCK_UN)
                _, error = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, error.decode())
                self.assertTrue(self.path.exists())
            finally:
                fcntl.flock(held.fileno(), fcntl.LOCK_UN)
                if child.poll() is None:
                    child.kill()
                    child.wait()

if __name__ == "__main__":
    unittest.main(verbosity=2)
