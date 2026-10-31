import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from race_state import RaceMachine  # noqa: E402

GRID = "west_coast_usa/aiRace/001-circuit"


def start(humans=1, ai=4):
    return {"type": "start", "grid": GRID, "humans": humans, "ai": ai}


class RaceMachineTest(unittest.TestCase):
    def test_duplicate_starts_collapse(self):
        machine = RaceMachine()
        starts = 0
        for offset in range(6):  # the 19:08-19:09 burst in the real journal
            emitted = machine.feed(start(), 1000.0 + offset * 12)
            starts += sum(1 for e in emitted if e["type"] == "race_started")
        self.assertEqual(starts, 1)

    def test_finish_emits_once(self):
        machine = RaceMachine()
        machine.feed(start(), 1000.0)
        first = machine.feed({"type": "phase", "phase": "finished"}, 1300.0)
        second = machine.feed({"type": "phase", "phase": "finished"}, 1301.0)
        self.assertEqual([e["type"] for e in first], ["race_finished"])
        self.assertEqual(second, [])

    def test_lobby_after_start_is_abort(self):
        machine = RaceMachine()
        machine.feed(start(), 1000.0)
        emitted = machine.feed({"type": "phase", "phase": "lobby"}, 1100.0)
        self.assertEqual([e["type"] for e in emitted], ["race_aborted"])

    def test_lobby_without_open_race_is_silent(self):
        self.assertEqual(RaceMachine().feed({"type": "phase", "phase": "lobby"}, 1.0), [])

    def test_configured_details_are_merged_into_start(self):
        machine = RaceMachine()
        machine.feed({"type": "configured", "race": GRID, "by": "guest1", "phase": "lobby",
                      "mode": "circuit", "car": "etkc", "ai": 4, "order": "random"}, 900.0)
        emitted = machine.feed(start(), 1000.0)
        race = emitted[0]["race"]
        self.assertEqual(race["mode"], "circuit")
        self.assertEqual(race["car"], "etkc")
        self.assertEqual(race["by"], "guest1")

    def test_restart_after_window_is_a_new_race(self):
        machine = RaceMachine()
        machine.feed(start(), 1000.0)
        emitted = machine.feed(start(), 1000.0 + 121)
        self.assertEqual([e["type"] for e in emitted], ["race_started"])


if __name__ == "__main__":
    unittest.main()
