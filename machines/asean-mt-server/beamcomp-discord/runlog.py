"""Tail BeamComp's append-only run log without missing or repeating lines.

The plugin writes one JSON object per human driver per race to
Resources/Server/BeamComp/beamcomp.runs.jsonl (schema v=1), appending with
io.open(path, "a"). It only does that while `enableStatistics` is on.

Offset + inode are persisted so a service restart neither re-posts old races nor
skips records written while the bridge was down. A re-seeded Resources dir gets a
new inode; a truncated file gets a smaller size -- both reset the offset to 0.
"""

import json
import os

SCHEMA_VERSION = 1


class RunLogTailer:
    def __init__(self, path, state=None):
        state = state or {}
        self.path = path
        self.inode = state.get("inode")
        self.offset = int(state.get("offset") or 0)
        self.partial = state.get("partial") or ""
        self.bad_schema_seen = False

    def state(self):
        return {
            "inode": self.inode,
            "offset": self.offset,
            "partial": self.partial,
        }

    def _reset(self, inode):
        self.inode = inode
        self.offset = 0
        self.partial = ""

    def poll(self):
        """Return newly appended records (possibly none)."""
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return []

        if st.st_ino != self.inode or st.st_size < self.offset:
            self._reset(st.st_ino)
        if st.st_size == self.offset:
            return []

        with open(self.path, "rb") as handle:
            handle.seek(self.offset)
            chunk = handle.read()

        self.offset += len(chunk)
        text = self.partial + chunk.decode("utf-8", "replace")
        lines = text.split("\n")
        self.partial = lines.pop()  # last element is the incomplete tail

        records = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                # A crash mid-write can leave a truncated object glued to the
                # front of the next one. Recover it rather than losing a race.
                start = line.rfind('{"v"')
                if start > 0:
                    try:
                        record = json.loads(line[start:])
                    except ValueError:
                        continue
                else:
                    continue
            if record.get("v") != SCHEMA_VERSION:
                if not self.bad_schema_seen:
                    self.bad_schema_seen = True
                continue
            records.append(record)
        return records
