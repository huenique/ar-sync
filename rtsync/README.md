# rtsync: two-way real-time sync for Aronium Lite (in development)

This replaces the one-writer copy (ar-sync v1) with two laptops that both write.

- Laptop A is the till. Laptop B is the office.
- Each laptop runs a small sidecar next to Aronium.
- Design and test results: `research/aronium-sync/MULTI-WRITER.md` (outside this repo).

**Status:** this is on branch `realtime-sync` only. Nothing here ships to the laptops yet.

## How it works

- **Capture.** SQLite triggers in `pos.db` write each change Aronium makes to `_rt_log`.
  - They use core SQL only, and they skip the sidecar's own writes.
  - They are only on while Aronium runs. Before an update, Aronium migrates the schema at startup, and triggers would break that.
  - Changes made while the triggers were off are found from a snapshot (`RemoveTriggers` / `InstallTriggers`).
- **Identity.** Rows present when the database was seeded are `seed:<Id>`. New rows are `<laptop>:<Id>`. Rows received from the peer get a local Id, which `_rt_map` records.
- **Conflicts.**
  - Edits: per-column last-writer-wins on a hybrid logical clock (`_rt_ver`).
  - Deletes: a delete beats an edit (`_rt_tomb`). A product deleted on the peer is disabled here, not removed, because the till's screen caches its product list.
  - Stock: travels as deltas, so concurrent sales add up.
  - Local to each laptop: Z reports, starting cash, counters, `Document.IsClockedOut` and `Payment.ZReportId`.
- **Apply.** One short `BEGIN IMMEDIATE` transaction per batch, with a 5 s busy timeout. It is idempotent by origin and seq.

## Tests

```
cd rtsync
go test ./...
```

- The tests build databases from `testdata/schema-1.52.sql`, which is structure only, with no shop data.
- To also run the two-laptop scenario on a copy of a real Aronium 1.52 database, set `RTSYNC_FIXTURE` to its path. Keep that copy outside the repo, because it holds customer data. A failing run prints only counts, never rows.
