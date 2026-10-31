"""Render Discord payloads for a race.

Two payloads per race:
  * render_started(race)                -> plain content message
  * render_results(race, records, ts)   -> one embed with the finishing order

Rules that matter:
  * Never print None / "None". Missing numbers are omitted, not faked.
  * No mentions anywhere (allowed_mentions parse: []).
  * Drivers are capped so the embed stays inside Discord's 25-field limit and
    stays readable; the remainder is summarised in one extra field.
"""

import datetime

MEDALS = ("🥇", "🥈", "🥉")
MAX_DRIVERS = 20
COLOR_FINISH = 0x2ECC71
COLOR_NO_FINISH = 0xE74C3C
TZ_OFFSET_HOURS = 7  # the server runs +07


def race_label(grid):
    """'west_coast_usa/aiRace/001-circuit' -> '001-circuit'."""
    return (grid or "race").rstrip("/").split("/")[-1]


def map_name(grid):
    if grid and "/" in grid:
        return grid.split("/", 1)[0]
    return None


def fmt_time(seconds):
    """280.92 -> '4:40.92'. Returns None for anything not a number."""
    if seconds is None:
        return None
    try:
        value = float(seconds)
    except (TypeError, ValueError):
        return None
    minutes, rest = divmod(value, 60)
    return f"{int(minutes)}:{rest:05.2f}"


def _local_time(ts):
    try:
        moment = datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc)
    except (TypeError, ValueError, OSError):
        return None
    return moment.astimezone(datetime.timezone(datetime.timedelta(hours=TZ_OFFSET_HOURS)))


def _status_text(record):
    status = record.get("status") or "unknown"
    if status == "finished":
        return None
    if status == "dnf":
        return "DNF"
    return "aborted"


def _driver_value(record):
    status = _status_text(record)
    if status:
        return status
    parts = []
    total = fmt_time(record.get("total_time"))
    if total:
        parts.append(total)
    best = fmt_time(record.get("best_lap"))
    if best:
        parts.append(f"best lap {best}")
    model = ((record.get("vehicle") or {}).get("model"))
    if model:
        parts.append(model)
    return " · ".join(parts) if parts else "finished"


def _count(n, noun):
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def render_started(race):
    """Plain 'race started' message -- no embed, no pings."""
    label = race_label(race.get("grid"))
    bits = [_count(race.get("humans", 0), "driver")]
    if race.get("ai"):
        bits.append(f"{race['ai']} AI")
    if race.get("mode"):
        bits.append(race["mode"])
    if race.get("car"):
        bits.append(f"car {race['car']}")
    return {
        "content": f"🏁 Race started — {label}\n" + " · ".join(bits),
        "allowed_mentions": {"parse": []},
    }


def render_no_stats(race, ts=None):
    label = race_label(race.get("grid"))
    return {
        "content": f"🏁 Race ended — {label} (no statistics recorded)",
        "allowed_mentions": {"parse": []},
    }


def render_results(race, records, ts):
    label = race_label(race.get("grid"))
    where = map_name(race.get("grid"))

    description = []
    description.append(f"{race.get('humans', 0)} drivers")
    if race.get("ai"):
        description.append(f"{race['ai']} AI")
    if race.get("mode"):
        description.append(f"mode {race['mode']}")
    if race.get("car"):
        description.append(f"car {race['car']}")

    ordered = sorted(
        records,
        key=lambda r: (
            0 if (r.get("status") == "finished") else 1,
            (r.get("ctx") or {}).get("pos") or 999,
            r.get("total_time") or 9999,
        ),
    )

    fields = []
    for index, record in enumerate(ordered[:MAX_DRIVERS]):
        name = record.get("identity") or "unknown"
        prefix = MEDALS[index] if index < len(MEDALS) else f"{index + 1}."
        fields.append({
            "name": f"{prefix} {name}"[:256],
            "value": _driver_value(record)[:1024],
            "inline": False,
        })
    if len(ordered) > MAX_DRIVERS:
        fields.append({
            "name": "…",
            "value": f"and {len(ordered) - MAX_DRIVERS} more drivers",
            "inline": False,
        })

    any_finished = any(r.get("status") == "finished" for r in records)
    local = _local_time(ts)
    embed = {
        "title": f"🏁 {label}" + (f" — {where}" if where else ""),
        "description": " · ".join(description),
        "color": COLOR_FINISH if any_finished else COLOR_NO_FINISH,
        "fields": fields,
    }
    if local is not None:
        embed["footer"] = {"text": f"AMC BeamNG · {local:%H:%M} +07"}
        embed["timestamp"] = local.astimezone(datetime.timezone.utc).isoformat()
    return {"embeds": [embed], "allowed_mentions": {"parse": []}}
