# Journal fixture — 2026-10-31

`journal-2026-10-31.jsonl` is a raw `journalctl -u beammp-server -o json` dump of
the first BeamComp session (17:00–02:00 +07, 734 entries, 355 of them
`beamcomp.race`).

Captured with:

```bash
ssh root@asean-mt-server 'journalctl -u beammp-server \
  --since "2026-10-31 17:00" --until "2026-11-01 02:00" -o json --no-pager' \
  > journal-2026-10-31.jsonl
```

What it contains:

- **9 `starting …` lines and 9 `phase -> finished` lines** — nine short solo
  practice races, all on `west_coast_usa/aiRace/001-circuit`, 12:02–12:16 UTC
- Runner-up races of 14–20 s each, several DNFs (`force finish`, `grace expired`)
- `enableStatistics=off` for the whole window, so **no `beamcomp.runs.jsonl`
  records exist** — this fixture tests the lifecycle parser only, not rendering
  with real times

`tests/test_fixture.py` pins these counts. If a BeamComp update rewords a log
line, that test fails instead of the Discord feed silently going quiet.
