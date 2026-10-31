import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from runlog import RunLogTailer  # noqa: E402


def record(event="1700000000-1", identity="tester"):
    return {
        "v": 1,
        "ts": 1700000000,
        "date": "2026-11-01",
        "event": event,
        "race": "west_coast_usa/aiRace/001-circuit",
        "identity": identity,
        "status": "finished",
        "total_time": 280.92,
        "best_lap": 138.1,
        "ctx": {"pos": 1, "humans": 1, "ai": 4},
    }


class TailerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "beamcomp.runs.jsonl")

    def append(self, *records):
        with open(self.path, "a") as handle:
            for item in records:
                handle.write(json.dumps(item) + "\n")

    def test_reads_new_lines_once(self):
        self.append(record())
        tailer = RunLogTailer(self.path)
        self.assertEqual(len(tailer.poll()), 1)
        self.assertEqual(tailer.poll(), [])

    def test_survives_restart_via_state(self):
        self.append(record("e1"))
        tailer = RunLogTailer(self.path)
        tailer.poll()
        revived = RunLogTailer(self.path, tailer.state())
        self.append(record("e2"))
        self.assertEqual([r["event"] for r in revived.poll()], ["e2"])

    def test_truncation_resets(self):
        self.append(record("e1"))
        tailer = RunLogTailer(self.path)
        tailer.poll()
        with open(self.path, "w") as handle:
            handle.write(json.dumps(record("e2"))[:60] + "\n")  # shorter than before
        self.assertEqual([r["event"] for r in tailer.poll()], [])

        with open(self.path, "w") as handle:
            handle.write(json.dumps({"v": 1, "event": "e2"}) + "\n")
        self.assertEqual([r["event"] for r in tailer.poll()], ["e2"])

    def test_partial_line_does_not_eat_the_next_record(self):
        tailer = RunLogTailer(self.path)
        with open(self.path, "w") as handle:
            handle.write(json.dumps(record("e1"))[:20])
        self.assertEqual(tailer.poll(), [])
        self.append(record("e1"))
        # the truncated fragment is glued to the next object; the tailer
        # recovers the intact record instead of dropping it
        self.assertEqual([r["event"] for r in tailer.poll()], ["e1"])

    def test_missing_file_is_not_fatal(self):
        self.assertEqual(RunLogTailer(os.path.join(self.dir, "nope.jsonl")).poll(), [])

    def test_wrong_schema_skipped(self):
        self.append({"v": 2, "event": "future"})
        self.append(record("e1"))
        self.assertEqual([r["event"] for r in RunLogTailer(self.path).poll()], ["e1"])


if __name__ == "__main__":
    unittest.main()
