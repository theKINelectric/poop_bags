---
name: poopbags
description: Bag the CRAP (Change Risk Anti-Patterns) of a local project — per-function risk ranking for Elixir, Zig, Kotlin, and Swift. Use when asked to find complexity hotspots, assess change risk before or after a refactor, rank worst functions, or gate a change on new code-risk violations. Static analysis only; the scanned project is never built or run.
---

# poop_bags — CRAP, bagged

Point it at a project directory and get every function ranked by
`CRAP = complexity² × (1 − coverage)³ + complexity`. High complexity with
nothing pinning it down (no tests) is change risk. Bands: fresh ≤ 5,
whiffy ≤ 20, foul ≤ 50, biohazard > 50.

## Where it runs

- House production: `http://localhost:4769` (loopback only)
- Dev instance: `http://localhost:4100`
- MCP server (stdio, same tools): `/Users/lloyd/PRODUCTION_SERVERS/apps/poopbags/current/bin/poop_bags_mcp`
  or `bin/poop_bags_mcp` from a repo checkout, with `POOP_BAGS_URL` set.

## The loop (curl)

```sh
# 1. start — absolute path, 202 + {"id": N}
curl -s $URL/api/scans -H 'content-type: application/json' \
     -d '{"project_path": "/abs/path", "coverage": 0}'

# 2. poll until status is done (or error)
curl -s $URL/api/scans/$ID

# 3. worst-first findings
curl -s "$URL/api/scans/$ID/findings?limit=20"

# 4. outcomes vs previous scan + gate verdict
curl -s "$URL/api/scans/$ID/diff?against=latest"
```

`GET $URL/api` returns the full machine-readable contract.

## MCP tools

`bag_project` (scan + wait + summary + worst offenders — the one-call loop),
`scan_status`, `top_findings`, `diff_latest`.

## Reading the results — the parts that matter

- **CRAP** is the ranking; **cx** is the cyclomatic complexity behind it.
  With no coverage report, coverage falls back to the scan's assumed value
  (0% default) — then CRAP ≈ complexity² + complexity and the ranking is a
  complexity ranking with teeth.
- **violations** are CRAP strictly above the scan's threshold (default 20;
  the project's `.poopbags.json` can set it, as can the caller).
- **diff outcomes** match functions on language+path+module+function — never
  line numbers. `introduced`/`regressed` (only when violation-level),
  `improved`/`resolved`, `removed` (missing code is never "resolved").
- **gate_passed=false** only when new violations or above-threshold
  regressions appeared. A pure refactor never fails the gate.
- **Retention**: only the last 3 done scans per project keep per-function
  details; older ones answer 410 "expired" (summaries and directory trends
  survive). Pin a scan to protect it.

## When using it on your own work

1. Scan before a refactor (that's your baseline).
2. Refactor; rescan.
3. `diff?against=latest` — you want your hotspots `resolved`/`improved` and
   no violation-level `introduced`. If the gate fails, the failing rows are
   the work list.

## Honest limits

Kotlin `->` after `)` reads as a function type; Swift `case` in nested enum
declarations counts; accessors/init blocks/test blocks are not reported as
functions; Elixir reports one finding per clause. Cross-language rankings
are comparable in spirit, not numerically identical.
