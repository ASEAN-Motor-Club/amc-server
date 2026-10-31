"""Turn BeamComp journal messages into typed events.

BeamComp (Resources/Server/BeamComp/main.lua) prints lifecycle lines through
BeamMP's Lua `print` with the prefix "[LUA] [beamcomp.<subsystem>] ". We only
care about the `beamcomp.race` subsystem; everything else (checkpoint spam,
grid/preset chatter) must return None so the caller can ignore it cheaply.

Run-log records (beamcomp.runs.jsonl) are NOT parsed here -- they are already
JSON and are handled by runlog.py.
"""

import re

EVENT_PREFIX = "[LUA] [beamcomp.race] "

_RE_START = re.compile(r"^starting '(.+)' for (\d+) player\(s\) \+ (\d+) AI$")
_RE_PHASE = re.compile(r"^phase -> ([a-z]+)$")
_RE_CONFIGURED = re.compile(r"^race '(.+)' by (.+?) \(phase ([a-z]+)\)(.*)$")
_RE_END_CMD = re.compile(r"^/raceend \(([^)]*)\) by (.+)$")
_RE_DNF = re.compile(r"^(?:player |ai:)(\S+) DNF \((.+)\)$")
_RE_FINAL = re.compile(r"^(\S+) checkpoint (\d+)/(\d+) lap (\d+) \(cp (\d+)\) @ ([\d.]+)s \(final\)$")

_KV = re.compile(r"(\w+)=(\S+)")

PHASES = {
    "lobby",
    "qualifying",
    "spawning",
    "staging",
    "countdown",
    "racing",
    "finished",
}


def _kv(rest):
    return {k: v for k, v in _KV.findall(rest)}


def parse_journal_message(message):
    """Return an event dict, or None when the line is not a race lifecycle line.

    Recognised events:
      {"type": "configured", "race", "by", "phase", "mode", "car", "ai", "order"}
      {"type": "start", "grid", "humans", "ai"}
      {"type": "phase", "phase"}
      {"type": "dnf", "driver", "reason"}
      {"type": "final", "driver", "time", "laps"}
      {"type": "ended", "reason", "by"}
    """
    if not message or EVENT_PREFIX not in message:
        return None
    body = message.split(EVENT_PREFIX, 1)[1].strip()

    m = _RE_START.match(body)
    if m:
        return {
            "type": "start",
            "grid": m.group(1),
            "humans": int(m.group(2)),
            "ai": int(m.group(3)),
        }

    m = _RE_PHASE.match(body)
    if m:
        phase = m.group(1)
        return {"type": "phase", "phase": phase} if phase in PHASES else None

    m = _RE_CONFIGURED.match(body)
    if m:
        extra = _kv(m.group(4))
        return {
            "type": "configured",
            "race": m.group(1),
            "by": m.group(2),
            "phase": m.group(3),
            "mode": extra.get("mode"),
            "car": extra.get("car"),
            "ai": int(extra["ai"]) if extra.get("ai", "").isdigit() else None,
            "order": extra.get("order"),
        }

    m = _RE_END_CMD.match(body)
    if m:
        return {"type": "ended", "reason": m.group(1), "by": m.group(2)}

    m = _RE_DNF.match(body)
    if m:
        return {"type": "dnf", "driver": m.group(1), "reason": m.group(2)}

    m = _RE_FINAL.match(body)
    if m:
        return {
            "type": "final",
            "driver": m.group(1),
            "time": float(m.group(6)),
            "laps": int(m.group(4)),
        }

    return None
