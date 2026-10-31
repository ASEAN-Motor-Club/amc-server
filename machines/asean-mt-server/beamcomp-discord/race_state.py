"""Fold BeamComp race events into one open race at a time.

The plugin logs `starting '<grid>' ...` more than once per race: the fixture from
2026-10-31 shows six identical start lines for a single race (19:08-19:09). A
second start for the same grid inside DUPLICATE_WINDOW seconds is therefore the
same race, not a new one.
"""

DUPLICATE_WINDOW = 120.0


class RaceMachine:
    def __init__(self, duplicate_window=DUPLICATE_WINDOW):
        self.duplicate_window = duplicate_window
        self.current = None      # {"grid", "started_at", "humans", "ai", "mode", "car", "order"}
        self.last_config = None  # most recent "configured" event for the next start

    # -- helpers ---------------------------------------------------------
    def _merged(self, start, ts):
        cfg = self.last_config or {}
        return {
            "grid": start["grid"],
            "race": cfg.get("race") or start["grid"],
            "started_at": ts,
            "humans": start["humans"],
            "ai": start["ai"] if start["ai"] is not None else (cfg.get("ai") or 0),
            "mode": cfg.get("mode"),
            "car": cfg.get("car"),
            "order": cfg.get("order"),
            "by": cfg.get("by"),
        }

    # -- public ----------------------------------------------------------
    def feed(self, event, ts):
        """Consume one parsed event; return a list of emitted dicts (0 or 1)."""
        kind = event["type"]

        if kind == "configured":
            self.last_config = event
            return []

        if kind == "start":
            cur = self.current
            if cur and cur["grid"] == event["grid"] and (ts - cur["started_at"]) < self.duplicate_window:
                return []
            race = self._merged(event, ts)
            self.current = race
            return [{"type": "race_started", "race": race}]

        if kind == "phase":
            phase = event["phase"]
            cur = self.current
            if cur is None:
                return []
            if phase == "finished":
                self.current = None
                return [{"type": "race_finished", "race": cur, "finished_at": ts}]
            if phase == "lobby":
                # Back to the lobby without finishing: the race was cleared/aborted.
                self.current = None
                return [{"type": "race_aborted", "race": cur, "aborted_at": ts}]
            return []

        # dnf / final / ended are informational only: identities live in the
        # run log, and the slot ids in these lines cannot be mapped to a name.
        return []
