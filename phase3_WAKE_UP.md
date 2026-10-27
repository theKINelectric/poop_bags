# phase3_WAKE_UP.md — poop_bags compaction handoff

**Read this first, then go.** Written 2026-10-06 after completing phase 2; updated same day after completing **phase 3 step 1 (hotspots + trends + retention)** and on 2026-10-07 after the **agent surface + publish + production deploy**. You are resuming with full history compacted away; this file + the repo + README carry the state.

## Production (2026-10-07)

- **Live** at loopback `http://localhost:4769` (launchd `ai.sag.poopbags`, house `bin/service`), LAN via phi `http://SS-Medea.local/poopbags/` (test with `http://192.168.1.209/poopbags/api` from SS-Medea). Ledger: `apps/poopbags/var/poop_bags.db`. Env (secrets) at `apps/poopbags/env`.
- Deploy = `~/PRODUCTION_SERVERS/deploy/bin/deploy poopbags /Volumes/Centaurus-A/__centaurus_repos/poop_bags HEAD`, then `launchctl kickstart -k gui/$(id -u)/ai.sag.poopbags` (bin/deploy flips the symlink; the kick loads the new release). env.example + lan.Caddyfile live in the deploy repo.
- Migrations run on every boot (single-node SQLite; `SKIP_MIGRATIONS=1` opts out).
- Git: `main` pushed to `git@codeberg.org:kin_electric/poop_bags.git`.
- Agent surface: `GET /api` discovery contract, front-page agent card (host-relative `$HOST` recipe), MCP escript **committed** at `bin/poop_bags_mcp` (build: `mix escript.build`; escript config has `app: nil` — the script must never boot the supervision tree, the SQLite NIF can't load inside an escript), skill at `skills/poopbags/` + installed at `~/.agents/skills/poopbags`.
- flow_extra dep auto-detects: sibling path dep when `../flow_extra/lib` exists, else codeberg git dep (public clones work).
- Dev-server gotcha: a backgrounded `mix phx.server` shares `_build/dev` with foreground mix runs — foreground `mix test`/`compile` kills the server; restart it after heavy mix work.

## What this project is

`poop_bags` — standalone web service in `/Volumes/Centaurus-A/__centaurus_repos/poop_bags` that takes a local project directory and ranks functions by CRAP score (`comp² × (1−cov)³ + comp`) for **Elixir, Zig, Kotlin, Swift**. Stack: **Phoenix 1.7** (no assets/live/mailer/gettext/dashboard, hand-written CSS at `priv/static/assets/app.css`, zero client JS) + **flow_extra** (path dep `../flow_extra`, the Flowex fork — GenStage railway pipelines) + **SQLite** (`ecto_sqlite3`, WAL + 5s busy_timeout). Dev server: **port 4100** (`PORT=` overrides; port 4000 belongs to another app — uml_viewer). Migrations auto-run on boot (Ecto.Migrator in the supervision tree).

## Hard rules

- **Never touch `/Volumes/Centaurus-A/__centaurus_repos/honey_badger`** — it is the read-only subject repo (~7.4k zig files + stray ex/exs/kt; no swift yet). Its `wake_up.md` convention inspired this file.
- `flow_extra` is a path dependency — read its source freely (`lib/flow_extra/`), don't modify it.
- Static analysis only: never build/run/execute scanned code; `.poopbags.json` is strict-JSON parsed, never evaluated.

## Support team (user-provided)

- **Strategy collaborator**: `codex exec resume 01a11172-d2da-7442-bcb2-67f2077f78f2 "<msg>"` — has full phase-1/2 history, gave the roadmap + two review rounds. Use for direction questions; can run in background (takes minutes, buffers output until done).
- **Pair validator**: `devin --permission-mode dangerous -p "<prompt>"` — fresh sessions (the user's `-r tidy-reply` session never existed). Read-only review instructions work well; it empirically probes (compiles to /tmp). Round 1 delivered 24 verified findings, most fixed.

## Phase state: 1, 2, and 3.1 COMPLETE, all green

- **133/133 tests**, `mix format` clean, `mix compile --warnings-as-errors` clean.
- **Phase 3 step 1 shipped**: directory hotspots (`scan_directories` table, `PoopBags.Hotspots` — depth 1..N aggregates with `(root)` and `<seg>/(direct files)` groups, CRAP-excess burden + violation-rate + worst + measured/assumed), per-project **trends page** (`/scans/:id/trends` — timeline + boundary markers for threshold/policy/scope/coverage-mode changes + hotspot matrix with CSS bars), **retention** (`PoopBags.Retention` — keep latest K=3 done scans per project via `config :poop_bags, :retention_keep`, pin/unpin to protect, `details_expired_at` marker, expired = unavailable (410/redirect) never empty, sweep after commit + at boot, claim-based expire that loses gracefully to a pin race).
- Live-verified on honey_badger through scan #8: retention expired 1–5 in sequence; scan 6+ carry 17 directory rows (`experiments/hb003_s3_user_journey` = 95k functions, excess 17.6M; `apps/amrita` = 14,280-worst in 82 files). Dev DB holds scans 1–8 (1–5 expired, summaries survive).
- README current through phase 3 step 1 (hotspots/trends/retention sections).

### Phase-3 step-1 review scars (devin round + probe): keep these true

- `details_available?/1` requires `status == "done"` AND `details_expired_at == nil` — a queued/running/error scan must never diff as "empty baseline".
- `Task.Supervisor.async_stream_nolink` exit shape with `zip_input_on_exit: true` is **`{:exit, {entry, reason}}`** (input zipped inside the second element — NOT a 3-tuple; verified empirically, Elixir 1.20). `lost_ip/2` rebuilds the ip from the entry so the manifest stays honest (hash `"unknown"`); regression test drives it via `Engine.run(scan, per_file_timeout: 1)`.
- API diff rows: `row.current` can be nil (`:removed`) — always `row.current && row.current.crap`.
- Retention expiry claims the row conditionally (`where not pinned and is_nil(details_expired_at)`) then deletes findings only if claimed — pin-vs-sweep race resolved in the pin's favor.
- `latest_baseline`/`scan_history` order by `[desc: finished_at, desc: id]` — same rank retention uses.
- SQLite: no `OFFSET` without `LIMIT` (drop-in-Elixir instead); `s.details_expired_at != nil` forbidden in queries (`is_nil/1`).
- A configured-but-missing coverage report now **stays configured** (broken-report semantics: CI fails, web warns) — the old nil-swallow was a silent-degradation bug.
- Untrusted params: `?against=` parsed with Integer.parse (no CastError 500); `?outcome=` validated against the six diff outcomes; `?depth=` clamped 1..4.

## Phase 3 — remaining, priority order (codex-confirmed 2026-10-06)

1. **Incremental rescanning** (next up): cache raw analysis keyed on `content sha256 + language + analyzer/backend version` (NOT coverage/threshold/depth — reattach coverage and rescore every scan). `scan_files` manifest already stores sha256s; scan_files survive detail expiry (cache must be independent of retained scans). Acceptance: timestamp-only touch reuses all 7,381 analyses; one content edit reuses 7,380 and matches a cache-disabled full scan of the updated snapshot; coverage-only change reuses analyses but updates scores/hotspots; parser-version change never reuses. Engine already records `stats["timings"]` (`belt_ms`, `commit_ms`) — extend with hashing/analyzing/scoring splits. Warm == cold is the correctness bar; wall-time collapse is the benchmark goal.
2. **Tree-sitter Zig pilot**: side-by-side with the token analyzer, separately versioned backend identity in the policy string, no effect on ordinary rankings until promoted. Erlang Port worker first.
3. Later/optional: scan queueing, LiveView on demand, multi-user.

Devin review round for step 1 came back clean on: FK cascades, sweep-vs-commit design, empty/root-only scans, not-pinned/is_nil/desc-NULL SQLite correctness. Known residual (accepted): narrow TOCTOU between `details_available?` checks and findings reads; literal `(root)`-named dirs merge into the root bucket; `hotspot_depth` config changes count as trend boundaries (displayed as boundaries, honest).

## Phase-2 feature map (what exists, where)

| Concern | Files |
|---|---|
| CRAP formula + stench bands | `lib/poop_bags/crap.ex` |
| Elixir AST analyzer (atom-safe via `static_atoms_encoder`, guards counted, quote pruned) + `explain/2` | `lib/poop_bags/elixir_analyzer.ex` |
| Zig/Kotlin/Swift token analyzer (offset-preserving cleaner → regex funs → brace spans bounded by next decl → innermost token attribution; labeled tokens; `explain/3`) | `lib/poop_bags/token_analyzer.ex`, `lib/poop_bags/source_cleaner.ex` |
| Project config `.poopbags.json` (exclude globs w/ `**`, coverage_report, threshold, languages) | `lib/poop_bags/project_config.ex`, `lib/poop_bags/glob.ex` |
| Coverage ingestion (LCOV + ExCoveralls JSON, innermost-span mapping, unknown≠zero, suffix path alignment) | `lib/poop_bags/coverage.ex` |
| **Engine** — the one place a scan happens (web runner + CI both call it) | `lib/poop_bags/engine.ex` |
| FlowExtra belt: `load_file ×6 → analyze_file ×6 → attach_coverage ×3 → score_findings ×3`, error_pipe `bag_the_mess` | `lib/poop_bags/scan_pipeline.ex` |
| Diff (identity matching, outcomes, threshold, comparability guards, gate) | `lib/poop_bags/diff.ex` |
| CI task | `lib/mix/tasks/poop_bags.ci.ex` |
| Web | `lib/poop_bags_web/controllers/scan_controller.ex`, `scan_html/{show,diff,explain}.heex`, `page_html/home.html.heex`, API in `controllers/api/scan_controller.ex` |
| Walker (junk dirs, caps, config excludes) | `lib/poop_bags/walker.ex` |
| DB | `lib/poop_bags/catalog.ex` + `catalog/{scan,finding,scan_file}.ex`, migrations in `priv/repo/migrations/` |

Runner lifecycle gotchas already solved (don't regress): `restart: :temporary` runner; `Task.Supervisor.async_stream_nolink` under `PoopBags.CallerSupervisor`; delete-of-running-scan rejected; reaper runs as a Task child BEFORE the Endpoint; findings+manifest+finish commit in one transaction; `max_children: 3` on the DynamicSupervisor.

## Phase 3 — codex's roadmap, priority order it gave

1. **Trends + directory hotspots** (2–4d): directory-prefix aggregation (function count, violations, worst CRAP, CRAP-excess — normalized so the biggest dir isn't auto-worst), per-project trend history, keep assumed- vs measured-coverage history visibly separate, **plus a retention policy** (~99k findings/scan accumulates fast; preserve baselines/summaries, expire old details). 1–2 extra days for retention.
2. **Incremental rescanning** (3–5d, AFTER trends): cache analysis keyed by content hash + language + analyzer version (scan_files manifest already stores sha256s — groundwork done); reattach coverage and rescore every scan (tests change coverage even when source doesn't); mtime as hint, hash as authority; fresh manifest every scan to catch deletions. Cache lookup can live before `analyze_file` in the pipeline.
3. **Tree-sitter: bounded Zig experiment first** (2–3d feasibility; 1–2w production adapter): Zig dominates the workload. Run token vs tree-sitter side-by-side on fixtures + honey_badger, inspect disagreements, promote behind a **new analyzer-policy version string** (policy is already persisted per scan — the invalidation hook exists). Erlang Port worker first, NIF only if measurements justify.
4. Later/optional: scan queueing (persisted FIFO replacing busy-rejection), LiveView only when interaction demands it, multi-user (registered project roots / uploads — a separate milestone, not now).
5. Trust-builders to weave in as touched: versioned analysis corpus (fixtures with expected counts — extend existing analyzer tests), "explain" already exists.

Acceptance bar for phase 3 (pick per codex's style): concrete scenario, e.g. *rescan a project after touching one file → manifest+hash cache skips 7,380 files, wall time collapses, identical findings; hotspot table shows the directory trend across the last N scans; old scans' detailed findings expire per retention policy while baselines survive.*

## Scars — things that cost time; don't repeat

- **Orphan dev-server beams** squat on 4100 after TaskStop of the background shell (`mix phx.server` detaches). Before restart: `lsof -tnPiTCP:4100 -sTCP:LISTEN | xargs kill -9`. Symptom: eaddrinuse, or curl gets stale code.
- HEEx: no `<%= %>` interpolation inside plain attributes — wrap whole attribute in `{"... #{...}"}`. `mix format` rewrites templates to `{}` syntax — match that when string-patching.
- Elixir-in-shell-heredocs: `"""` inside `~s{}`/`""` strings breaks parsers — build probes in `.exs` files or via char codes (`<<34>>`); `~s|...|` for strings containing braces.
- `tl([])` raises — use `Enum.drop(list, 1)`. `@spec` needs `::` not `->`. `Keyword.new` needs atom keys (use `Map.new`/tuple sums for string-keyed pairs).
- Python-patched .ex files: watch `\\` escaping (python eats backslashes → `config \ nil` bugs) and verify the seam after every patch.
- Test-writing traps hit: `catch_exit` fails if nothing exits; stale Ecto structs (reassign after `finish_scan!`); fake paths fail `create_scan` dir validation (mkdir first); async atom-count tests need slack (<200) for sibling noise; fixture LCOV must target *executable* lines inside the finding's span (line numbers of `if`s, not `end`s).
- Zig fun-regex now handles nested generics + receivers + Swift operator funcs; module regex allows lowercase + `packed|extern`. Kotlin `->` after `)` = type annotation (documented approximation). Swift ternary regex: `\?(?![?.])(?!\s*=)[^\n?:]*:`.
- honey_badger junk dirs include un-dotted `zig-cache`/`cache` (in `Languages` junk list). Known files that mislead: `experiments/**` holds ~9.2k vendored/copied zig trees (correctly scanned — the subject's reality).

## Standing verification loop

```console
mix test                                   # 115 green
mix compile --warnings-as-errors && mix format
mix phx.server                             # PORT=4100 default
curl -X POST localhost:4100/api/scans -H 'content-type: application/json' \
  -d '{"project_path": "/Volumes/Centaurus-A/__centaurus_repos/honey_badger"}'
mix poop_bags.ci --path /Volumes/Centaurus-A/__centaurus_repos/honey_badger --against latest
```

Browser verify via the browser-use skill (screenshot → Read the artifact). Acceptance fixture lives in `test/poop_bags/acceptance_test.exs`; static fixture project at `priv/fixtures/subject_project`.

## First moves when you wake

1. `mix test` to confirm the world still spins (133 green); check server/port state.
2. Re-read README.md (current through phase 3 step 1) + this file.
3. Begin **incremental rescanning** (design constraints above; codex already blessed the key shape: raw-analysis cache keyed on sha256+language+analyzer version, coverage/threshold rescored every scan, cache independent of retained scans, warm must equal cold). Consult codex on the cache table shape before building if the design feels ambiguous.
4. Then the tree-sitter Zig pilot as a side-by-side experiment behind a new backend-identity policy string.
