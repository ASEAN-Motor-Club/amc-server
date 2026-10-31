"""Replay the real journal dump captured on 2026-10-31 (9 solo practice races).

This is the regression guard for the log format: if a BeamComp update rewords a
lifecycle line, these counts change and the test fails instead of the Discord
feed silently going quiet.
"""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

import parse  # noqa: E402
import race_state  # noqa: E402
import render  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "journal-2026-10-31.jsonl")


def events():
    with open(FIXTURE) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            ts = float(entry.get("__REALTIME_TIMESTAMP", 0)) / 1_000_000
            event = parse.parse_journal_message(entry.get("MESSAGE", ""))
            if event:
                yield event, ts


@unittest.skipUnless(os.path.exists(FIXTURE), "fixture not captured")
class FixtureTest(unittest.TestCase):
    def test_counts(self):
        machine = race_state.RaceMachine()
        counts = {"race_started": 0, "race_finished": 0, "race_aborted": 0}
        for event, ts in events():
            for emitted in machine.feed(event, ts):
                counts[emitted["type"]] += 1
        self.assertEqual(counts["race_started"], 9)
        self.assertEqual(counts["race_finished"], 9)
        self.assertEqual(counts["race_aborted"], 0)

    def test_every_race_renders_without_none(self):
        machine = race_state.RaceMachine()
        rendered = 0
        for event, ts in events():
            for emitted in machine.feed(event, ts):
                if emitted["type"] == "race_started":
                    payload = render.render_started(emitted["race"])
                elif emitted["type"] == "race_finished":
                    payload = render.render_no_stats(emitted["race"])  # statistics were off that night
                else:
                    continue
                rendered += 1
                self.assertNotIn("None", json.dumps(payload))
        self.assertEqual(rendered, 18)

    def test_non_beamcomp_lines_are_ignored(self):
        matched = 0
        for event, _ts in events():
            self.assertIn(
                event["type"],
                {"configured", "start", "phase", "dnf", "final", "ended"},
            )
            matched += 1
        self.assertGreater(matched, 50)


if __name__ == "__main__":
    unittest.main()
