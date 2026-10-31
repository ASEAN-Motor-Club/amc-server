#!/usr/bin/env python3
"""BeamComp -> Discord bridge.

Follows the beammp-server journal for race lifecycle events, tails BeamComp's
append-only run log for results, and posts two messages per race to a Discord
channel: a "race started" line and a results card.

Configuration (environment):
  BEAMCOMP_CHANNEL_ID    Discord channel id to post into
  BEAMCOMP_TOKEN_FILE    file holding a bot token (posts as that bot)
  BEAMCOMP_WEBHOOK_FILE  alternative to TOKEN_FILE: file holding a webhook URL
  BEAMCOMP_RUNLOG        path to beamcomp.runs.jsonl
  BEAMCOMP_STATE_DIR     where state.json lives
  BEAMCOMP_DRY_RUN       "1" -> print payloads instead of posting
  BEAMCOMP_UNIT          systemd unit to follow (default beammp-server)

Usage:
  bridge.py                      run the live bridge
  bridge.py --replay FILE        feed a journalctl -o json dump through the
                                 parser and print payloads (implies dry run)
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque

import parse
import race_state
import render
import runlog

API = "https://discord.com/api/v10"
RESULT_WAIT_SECONDS = 10.0
POLL_INTERVAL = 1.0


def log(message):
    print(f"[beamcomp-discord] {message}", flush=True)


class Poster(threading.Thread):
    """Single worker so posts stay ordered and rate limits are respected."""

    def __init__(self, target, dry_run=False):
        super().__init__(daemon=True)
        self.queue = queue.Queue()
        self.target = target          # dict: {"url": ...} or {"token":..., "channel":...}
        self.dry_run = dry_run
        self.stopped = False

    def submit(self, payload):
        self.queue.put(payload)

    def run(self):
        while not self.stopped:
            payload = self.queue.get()
            if payload is None:
                break
            try:
                self._deliver(payload)
            except Exception as exc:  # never let one bad post kill the thread
                log(f"post failed permanently: {exc}\n{json.dumps(payload)[:800]}")

    def _deliver(self, payload):
        body = json.dumps(payload).encode()
        if self.dry_run:
            log(f"DRY RUN payload: {body.decode()}")
            return
        attempt = 0
        while True:
            attempt += 1
            request = urllib.request.Request(
                self.target["url"] if "url" in self.target
                else f"{API}/channels/{self.target['channel']}/messages",
                data=body,
                method="POST",
                headers=self._headers(),
            )
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    log(f"posted ({response.status}): {payload.get('content', 'embed')[:60]!r}")
                    return
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:300]
                if exc.code == 429 and attempt <= 3:
                    wait = _retry_after(detail)
                    log(f"rate limited, sleeping {wait:.1f}s")
                    time.sleep(wait)
                    continue
                if 500 <= exc.code < 600 and attempt <= 3:
                    time.sleep(2 ** attempt)
                    continue
                raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                if attempt <= 3:
                    time.sleep(2 ** attempt)
                    continue
                raise

    def _headers(self):
        headers = {"Content-Type": "application/json", "User-Agent": "amc-beamcomp-bridge"}
        if "token" in self.target:
            headers["Authorization"] = "Bot " + self.target["token"]
        return headers


def _retry_after(detail):
    try:
        return float(json.loads(detail).get("retry_after", 1.0))
    except (ValueError, TypeError, AttributeError):
        return 1.0


class Bridge:
    def __init__(self, config):
        self.config = config
        self.state_path = os.path.join(config["state_dir"], "state.json")
        self.state = self._load_state()
        self.machine = race_state.RaceMachine()
        self.tailer = runlog.RunLogTailer(config["runlog"], self.state.get("runlog"))
        self.poster = Poster(config["target"], dry_run=config["dry_run"])
        self.records = deque(maxlen=500)
        self.seen_events = set(self.state.get("seen_events") or [])
        self.poster.start()

    # -- state -----------------------------------------------------------
    def _load_state(self):
        try:
            with open(self.state_path) as handle:
                return json.load(handle)
        except (FileNotFoundError, ValueError):
            return {}

    def _save_state(self):
        self.state["runlog"] = self.tailer.state()
        self.state["seen_events"] = list(self.seen_events)[-500:]
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(self.state, handle)
        os.replace(tmp, self.state_path)

    # -- records ---------------------------------------------------------
    def _poll_runlog(self):
        for record in self.tailer.poll():
            self.records.append(record)
        self._save_state()

    def _claim(self, race, finished_at):
        """Records for this race instance, newest wins on duplicates."""
        started = race.get("started_at") or 0
        picked = []
        for record in self.records:
            event_id = record.get("event")
            if event_id and event_id in self.seen_events:
                continue
            same_race = record.get("race") == race.get("grid")
            in_window = started - 5 <= (record.get("ts") or 0) <= finished_at + 10
            if same_race or in_window:
                picked.append(record)
        for record in picked:
            if record.get("event"):
                self.seen_events.add(record["event"])
        return picked

    # -- events ----------------------------------------------------------
    def handle(self, event, ts):
        for emitted in self.machine.feed(event, ts):
            if emitted["type"] == "race_started":
                self.poster.submit(render.render_started(emitted["race"]))
                continue

            if emitted["type"] == "race_aborted":
                race = emitted["race"]
                log(f"race aborted before finishing: {race.get('grid')}")
                picked = self._claim(race, emitted.get("aborted_at") or time.time())
                if picked:
                    self.poster.submit(render.render_results(race, picked, emitted.get("aborted_at")))
                continue

            if emitted["type"] == "race_finished":
                race, finished_at = emitted["race"], emitted["finished_at"]
                deadline = time.time() + RESULT_WAIT_SECONDS
                picked = []
                while time.time() < deadline:
                    self._poll_runlog()
                    picked = self._claim(race, finished_at)
                    if picked:
                        break
                    time.sleep(0.5)
                if picked:
                    self.poster.submit(render.render_results(race, picked, finished_at))
                else:
                    log(f"no run records for {race.get('grid')} -- statistics disabled?")
                    self.poster.submit(render.render_no_stats(race, finished_at))
                self._save_state()

    # -- journal ---------------------------------------------------------
    def _journal_lines(self):
        command = ["journalctl", "-u", self.config["unit"], "-f", "-o", "json", "--lines=0"]
        while True:
            log(f"following: {' '.join(command)}")
            process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True, bufsize=1)
            assert process.stdout is not None
            for line in process.stdout:
                yield line
            process.wait()
            log("journal follower exited; restarting in 5s")
            time.sleep(5)

    def run(self):
        log(f"bridge started; runlog={self.config['runlog']} offset={self.tailer.offset}")
        self._poll_runlog()
        pending = queue.Queue()

        def pump():
            for line in self._journal_lines():
                pending.put(line)

        threading.Thread(target=pump, daemon=True).start()

        while True:
            try:
                line = pending.get(timeout=POLL_INTERVAL)
            except queue.Empty:
                self._poll_runlog()
                continue
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            micro = entry.get("__REALTIME_TIMESTAMP")
            ts = float(micro) / 1_000_000 if micro else time.time()
            event = parse.parse_journal_message(entry.get("MESSAGE", ""))
            if event:
                self.handle(event, ts)


def replay(path, config):
    """Feed a journalctl JSON dump through the parser and print payloads."""
    machine = race_state.RaceMachine()
    count = 0
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            micro = entry.get("__REALTIME_TIMESTAMP")
            ts = float(micro) / 1_000_000 if micro else time.time()
            event = parse.parse_journal_message(entry.get("MESSAGE", ""))
            if not event:
                continue
            for emitted in machine.feed(event, ts):
                count += 1
                if emitted["type"] == "race_started":
                    print(json.dumps(render.render_started(emitted["race"]), indent=2))
                elif emitted["type"] == "race_finished":
                    print(json.dumps(render.render_no_stats(emitted["race"]), indent=2))
                else:
                    print(json.dumps({"aborted": emitted["race"].get("grid")}, indent=2))
    log(f"replay complete: {count} race transitions")


def _credential(name):
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        return ""
    path = os.path.join(directory, name)
    return path if os.path.exists(path) else ""


def _target_from_env(config):
    if config["webhook_file"]:
        with open(config["webhook_file"]) as handle:
            return {"url": handle.read().strip()}
    if config["token_file"]:
        with open(config["token_file"]) as handle:
            return {"token": handle.read().strip(), "channel": config["channel"]}
    print("need BEAMCOMP_WEBHOOK_FILE or BEAMCOMP_TOKEN_FILE", file=sys.stderr)
    return None


def main(argv):
    config = {
        "channel": os.environ.get("BEAMCOMP_CHANNEL_ID", ""),
        "token_file": os.environ.get("BEAMCOMP_TOKEN_FILE", "") or _credential("discord-token"),
        "webhook_file": os.environ.get("BEAMCOMP_WEBHOOK_FILE", ""),
        "runlog": os.environ.get("BEAMCOMP_RUNLOG", ""),
        "state_dir": os.environ.get("BEAMCOMP_STATE_DIR", "."),
        "unit": os.environ.get("BEAMCOMP_UNIT", "beammp-server"),
        "dry_run": os.environ.get("BEAMCOMP_DRY_RUN") == "1",
    }

    if len(argv) > 2 and argv[1] == "--replay":
        replay(argv[2], config)
        return 0

    if len(argv) > 1 and argv[1] == "--self-test":
        target = _target_from_env(config)
        if target is None:
            return 2
        sample_race = {
            "grid": "west_coast_usa/aiRace/001-circuit",
            "humans": 2,
            "ai": 4,
            "mode": "circuit",
            "car": "etkc",
        }
        sample_records = [
            {"identity": "self-test-a", "status": "finished", "total_time": 280.92,
             "best_lap": 138.1, "vehicle": {"model": "etk800"}, "ctx": {"pos": 1}, "event": "self-test"},
            {"identity": "self-test-b", "status": "dnf", "ctx": {"pos": 2}, "event": "self-test"},
        ]
        Poster(target)._deliver(render.render_results(sample_race, sample_records, time.time()))
        return 0

    if not config["runlog"]:
        print("BEAMCOMP_RUNLOG is required", file=sys.stderr)
        return 2

    target = _target_from_env(config)
    if target is None:
        return 2
    config["target"] = target

    Bridge(config).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
