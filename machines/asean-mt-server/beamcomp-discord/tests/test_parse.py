import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parse import parse_journal_message  # noqa: E402


class ParseTest(unittest.TestCase):
    def test_start_line(self):
        self.assertEqual(
            parse_journal_message(
                "[LUA] [beamcomp.race] starting 'west_coast_usa/aiRace/001-circuit' for 3 player(s) + 4 AI"
            ),
            {"type": "start", "grid": "west_coast_usa/aiRace/001-circuit", "humans": 3, "ai": 4},
        )

    def test_start_zero_ai(self):
        event = parse_journal_message("[LUA] [beamcomp.race] starting 'utah/001' for 1 player(s) + 0 AI")
        self.assertEqual(event["humans"], 1)
        self.assertEqual(event["ai"], 0)

    def test_phase_line(self):
        self.assertEqual(
            parse_journal_message("[LUA] [beamcomp.race] phase -> finished"),
            {"type": "phase", "phase": "finished"},
        )

    def test_unknown_phase_ignored(self):
        self.assertIsNone(parse_journal_message("[LUA] [beamcomp.race] phase -> bananas"))

    def test_configured_line(self):
        event = parse_journal_message(
            "[LUA] [beamcomp.race] race 'west_coast_usa/aiRace/001-circuit' by guest9071515 "
            "(phase lobby) mode=circuit recover=5s repair=5s car=etkc order=random ai=4 hard"
        )
        self.assertEqual(event["type"], "configured")
        self.assertEqual(event["by"], "guest9071515")
        self.assertEqual(event["mode"], "circuit")
        self.assertEqual(event["car"], "etkc")
        self.assertEqual(event["ai"], 4)
        self.assertEqual(event["order"], "random")

    def test_dnf_line(self):
        self.assertEqual(
            parse_journal_message("[LUA] [beamcomp.race] player 0 DNF (force finish)"),
            {"type": "dnf", "driver": "0", "reason": "force finish"},
        )

    def test_ai_dnf_line(self):
        self.assertEqual(
            parse_journal_message("[LUA] [beamcomp.race] player ai:1 DNF (grace expired)"),
            {"type": "dnf", "driver": "ai:1", "reason": "grace expired"},
        )

    def test_final_line(self):
        self.assertEqual(
            parse_journal_message("[LUA] [beamcomp.race] 0 checkpoint 32/32 lap 2 (cp 0) @ 280.92s (final)"),
            {"type": "final", "driver": "0", "time": 280.92, "laps": 2},
        )

    def test_ended_line(self):
        self.assertEqual(
            parse_journal_message("[LUA] [beamcomp.race] /raceend (force finish) by guest9071515"),
            {"type": "ended", "reason": "force finish", "by": "guest9071515"},
        )

    def test_checkpoint_spam_is_none(self):
        self.assertIsNone(
            parse_journal_message("[LUA] [beamcomp.race] ai:2 checkpoint 5/32 lap 0 (cp 4) @ 31.4s")
        )

    def test_other_subsystem_is_none(self):
        self.assertIsNone(parse_journal_message("[LUA] [beamcomp.grid] carSize id=0 4.45 x 2.12 m"))
        self.assertIsNone(parse_journal_message("[INFO] Loaded 1 Mods"))


if __name__ == "__main__":
    unittest.main()
