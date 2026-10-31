import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import render  # noqa: E402

RACE = {
    "grid": "west_coast_usa/aiRace/001-circuit",
    "race": "west_coast_usa/aiRace/001-circuit",
    "humans": 2,
    "ai": 4,
    "mode": "circuit",
    "car": "etkc",
    "started_at": 1700000000.0,
}


def rec(identity, status, pos, total=None, best=None, model="etkc", event="e1"):
    return {
        "v": 1,
        "ts": 1700000280,
        "event": event,
        "race": RACE["grid"],
        "identity": identity,
        "status": status,
        "total_time": total,
        "best_lap": best,
        "vehicle": {"model": model},
        "ctx": {"pos": pos},
    }


class RenderTest(unittest.TestCase):
    def test_fmt_time(self):
        self.assertEqual(render.fmt_time(280.92), "4:40.92")
        self.assertEqual(render.fmt_time(9.5), "0:09.50")
        self.assertIsNone(render.fmt_time(None))
        self.assertIsNone(render.fmt_time("nope"))

    def test_started_message(self):
        payload = render.render_started(RACE)
        self.assertEqual(
            payload["content"],
            "🏁 Race started — 001-circuit\n2 drivers · 4 AI · circuit · car etkc",
        )
        self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_started_without_config(self):
        payload = render.render_started({"grid": "utah/001", "humans": 1, "ai": 0})
        self.assertEqual(payload["content"], "🏁 Race started — 001\n1 driver")
        self.assertNotIn("None", payload["content"])

    def test_results_embed(self):
        payload = render.render_results(
            RACE,
            [
                rec("slowpoke", "finished", 2, 300.0, 150.0, "etk800", "e2"),
                rec("freeman", "finished", 1, 280.92, 138.1, "etk800", "e1"),
                rec("guest123", "dnf", None, None, None, None, "e3"),
            ],
            1700000281,
        )
        embed = payload["embeds"][0]
        self.assertEqual(embed["title"], "🏁 001-circuit — west_coast_usa")
        self.assertEqual(embed["description"], "2 drivers · 4 AI · mode circuit · car etkc")
        self.assertEqual([f["name"] for f in embed["fields"]], ["🥇 freeman", "🥈 slowpoke", "🥉 guest123"])
        self.assertEqual(embed["fields"][0]["value"], "4:40.92 · best lap 2:18.10 · etk800")
        self.assertEqual(embed["fields"][2]["value"], "DNF")
        self.assertEqual(embed["color"], render.COLOR_FINISH)
        self.assertTrue(embed["footer"]["text"].endswith("+07"))

    def test_all_dnf_color(self):
        payload = render.render_results(RACE, [rec("a", "dnf", None)], 1700000281)
        self.assertEqual(payload["embeds"][0]["color"], render.COLOR_NO_FINISH)

    def test_driver_cap(self):
        records = [rec(f"p{i}", "finished", i + 1, 300 + i) for i in range(30)]
        embed = render.render_results(RACE, records, 1700000281)["embeds"][0]
        self.assertEqual(len(embed["fields"]), 21)
        self.assertEqual(embed["fields"][-1]["value"], "and 10 more drivers")

    def test_no_stats_message(self):
        payload = render.render_no_stats(RACE)
        self.assertIn("001-circuit", payload["content"])
        self.assertNotIn("None", payload["content"])


if __name__ == "__main__":
    unittest.main()
