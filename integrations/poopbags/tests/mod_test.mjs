// Contract-controls simulation for the advisory poop_bags Mod. Pure node:test
// — drives register(on) with a mock $ (fs, http, session, clock). This is SDK
// simulation only; real-service and real-Claude-CLI receipts are separate.
import test from "node:test";
import assert from "node:assert/strict";
import { register } from "../hooks/register.mjs";

const ROOT = "/proj";
const STATE = "/state";
const SRC = "pub fn add(a: i32, b: i32) -> i32 { a + b }\n";

// fsFiles/written are shared across hosts so several "sessions" can sit on the
// same project + state dir, like real worktrees sharing a repo.
function host({ fetch, files, sessionRef, fsFiles, written, extraEnv = {} }) {
  const hooks = new Map();
  const logs = [];
  fsFiles = fsFiles || new Map(Object.entries(files || { [`${ROOT}/src/lib.rs`]: SRC }));
  written = written || new Map();

  register((name, matcher, handler) => hooks.set(name, handler || matcher));

  const env = { POOPBAGS_MOD_STATE: STATE, PWD: ROOT, ...extraEnv };
  const $ = {
    env: { get: async (n) => env[n] },
    plugin: { root: "/plugin" },
    command: { register: async () => {} },
    session: { id: async () => sessionRef.id },
    clock: { now: async () => Date.now() },
    ui: { log: async (t) => logs.push(t) },
    fs: {
      read: async (p) => {
        if (!fsFiles.has(p)) throw new Error(`ENOENT ${p}`);
        const v = fsFiles.get(p);
        if (v === null || v.dir) throw new Error(`EISDIR ${p}`);
        return v;
      },
      write: async (p, text) => { written.set(p, text); fsFiles.set(p, text); },
      exists: async (p) => fsFiles.has(p),
      stat: async (p) => ({ kind: "dir", size: 0, mtimeMs: 0, isLink: false, realPath: p }),
      list: async (p) => {
        const prefix = `${p}/`;
        const seen = new Map();
        for (const key of fsFiles.keys()) {
          if (!key.startsWith(prefix)) continue;
          const rest = key.slice(prefix.length);
          const head = rest.split("/")[0];
          const isDir = rest.includes("/");
          if (!seen.has(head)) seen.set(head, { name: head, kind: isDir ? "dir" : "file", size: 4, mtimeMs: 0, isLink: false });
        }
        return [...seen.values()];
      },
    },
    http: { fetch: fetch || (async () => { throw new Error("connection refused"); }) },
    process: { run: async () => ({ exitCode: 1, stdout: "", stderr: "unused" }) },
  };
  return { $, hooks, logs, written, fsFiles };
}

const edit = (session_id = "s1", cwd = ROOT) => ({
  hook_event_name: "PostToolUse", cwd, session_id, tool_name: "Edit",
  tool_input: { file_path: `${cwd}/src/lib.rs` }, tool_response: { success: true },
});
const stop = (session_id = "s1", cwd = ROOT, active = false) => ({
  hook_event_name: "Stop", cwd, session_id, stop_hook_active: active,
});
const passthrough = (e) => e;

const okScan = (id) => ({ status: 200, ok: true, headers: {}, text: JSON.stringify({ id, status: "done", project_path: ROOT, functions_total: 7, violations: 1, threshold: 20, assumed_coverage: 0 }) });
const diffBody = (over = {}) => JSON.stringify({
  scan_id: 2, baseline_id: 1, threshold: 20, comparable: true, warnings: [],
  summary: { introduced: 0, removed: 0, regressed: 0, improved: 0, resolved: 0, unchanged: 7 },
  gate_passed: true, rows: [], ...over,
});

function scanServer({ scanId = 1, diffStatus = 200, diff = diffBody(), statusSeq = ["done"] } = {}) {
  const calls = [];
  let poll = 0;
  const fetch = async (url, init = {}) => {
    calls.push(`${init.method || "GET"} ${url}`);
    if (url.endsWith("/api/scans") && init.method === "POST")
      return { status: 202, ok: true, headers: {}, text: JSON.stringify({ id: scanId, status: "running" }) };
    if (url.includes("/diff")) {
      if (diffStatus !== 200) return { status: diffStatus, ok: false, headers: {}, text: JSON.stringify({ error: "baseline scan details expired by retention" }) };
      return { status: 200, ok: true, headers: {}, text: diff };
    }
    if (/\/api\/scans\/\d+$/.test(url)) {
      const st = statusSeq[Math.min(poll++, statusSeq.length - 1)];
      if (st === "done") return okScan(scanId);
      return { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: scanId, status: st }) };
    }
    return { status: 404, ok: false, headers: {}, text: "{}" };
  };
  return { fetch, calls };
}

test("no edits: Stop forwards unchanged, no service traffic", async () => {
  const srv = scanServer();
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.equal(result.cwd, ROOT);
  assert.equal(srv.calls.length, 0);
});

test("edit then Stop with no baseline: initial observation, never a gate pass", async () => {
  const srv = scanServer({ scanId: 11 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /initial observation/);
  assert.match(notice, /[Bb]aseline pinned to #11/);
  assert.match(notice, /not a passed regression gate/);
  assert.ok(!srv.calls.some((c) => c.includes("/diff")), "no diff without a baseline");
  assert.ok(new TextEncoder().encode(notice).length <= 2000);
});

test("pinned baseline + clean diff: completed-clean", async () => {
  const srv = scanServer({ scanId: 22 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  await h.hooks.get("classic.Stop")(h.$, stop(), passthrough); // pins baseline 22
  h.fsFiles.set(`${ROOT}/src/lib.rs`, SRC + "pub fn extra() -> i32 { 0 }\n");
  h.$.http.fetch = scanServer({ scanId: 23, diff: diffBody({ scan_id: 23, baseline_id: 22 }) }).fetch;
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /completed-clean/);
  assert.match(notice, /baseline #22/);
});

test("introduced violations: completed-actionable with named functions", async () => {
  const srv = scanServer({ scanId: 30 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const first = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(first.additionalContext.join(""), /initial observation/);
  const diff2 = diffBody({
    scan_id: 31, baseline_id: 30, gate_passed: false,
    summary: { introduced: 2, removed: 0, regressed: 0, improved: 0, resolved: 0, unchanged: 5 },
    rows: [
      { outcome: "introduced", violation: true, language: "rust", path: "src/lib.rs", module: null, function: "rotten/0", baseline_crap: null, current_crap: 47, delta_crap: 47, delta_complexity: 9, coverage: null, coverage_source: null },
      { outcome: "introduced", violation: true, language: "rust", path: "src/lib.rs", module: null, function: "bad/0", baseline_crap: null, current_crap: 33, delta_crap: 33, delta_complexity: 7, coverage: null, coverage_source: null },
    ],
  });
  h.fsFiles.set(`${ROOT}/src/lib.rs`, SRC + "fn changed() {}\n");
  h.$.http.fetch = scanServer({ scanId: 31, diff: diff2 }).fetch;
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /completed-actionable/);
  assert.match(notice, /rotten\/0 CRAP 47/);
  assert.match(notice, /baseline #30/);
});

test("down service: unknown, fail-open, evidence on disk, notice under 2KB", async () => {
  const h = host({ fetch: async () => { throw new Error("connection refused"); }, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /poop_bags: unknown/);
  assert.match(notice, /never blocks/);
  assert.ok(new TextEncoder().encode(notice).length <= 2000);
  assert.ok([...h.written.keys()].some((p) => p.includes("last-unknown.json")), "evidence file written");
  const ev = JSON.parse([...h.written.entries()].find(([p]) => p.includes("last-unknown.json"))[1]);
  assert.equal(ev.schema, "poopbags-mod/1");
});

test("expired baseline (410): unknown, repins to current scan as initial observation", async () => {
  const srv = scanServer({ scanId: 40 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  await h.hooks.get("classic.Stop")(h.$, stop(), passthrough); // pins baseline 40
  h.fsFiles.set(`${ROOT}/src/lib.rs`, SRC + "fn v2() {}\n");
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  h.$.http.fetch = scanServer({ scanId: 41, diffStatus: 410 }).fetch;
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /unknown/);
  assert.match(notice, /baseline expired/);
});

test("same-revision replay: identical content answers from store, no rescan", async () => {
  const srv = scanServer({ scanId: 50 });
  const sessionRef = { id: "s1" };
  const fsFiles = new Map([[`${ROOT}/src/lib.rs`, SRC]]);
  const written = new Map();
  const h = host({ fetch: srv.fetch, sessionRef, fsFiles, written });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const posts = srv.calls.filter((c) => c.includes("POST")).length;
  // A different session edits but writes identical content → replay, no POST.
  sessionRef.id = "s2";
  await h.hooks.get("classic.PostToolUse")(h.$, edit("s2"), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop("s2"), passthrough);
  assert.match(result.additionalContext.join("\n"), /initial observation/);
  assert.equal(srv.calls.filter((c) => c.includes("POST")).length, posts, "no rescan on identical content");
});

test("malformed responses degrade to unknown", async () => {
  const h = host({ fetch: async () => ({ status: 200, ok: true, headers: {}, text: "not json{{{" }), sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(result.additionalContext.join("\n"), /unknown/);
});

test("oversized scope (>512 files): unknown, never pretends a gate ran", async () => {
  const files = {};
  for (let i = 0; i < 600; i++) files[`${ROOT}/src/f${i}.rs`] = "fn x() {}\n";
  const h = host({ fetch: scanServer().fetch, files, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(result.additionalContext.join("\n"), /unknown.*fingerprint bounds/);
});

test("pending scan stays pending, resumes at a later boundary without resubmit", async () => {
  // scanBudgetMs=1 → the poll budget expires while the scan reports running,
  // so the run parks as pending; the second Stop resumes the same scan_id.
  // The bounded poll loop does not fetch once the deadline has passed, so each
  // boundary consumes exactly one status read.
  const srv = scanServer({ scanId: 70, statusSeq: ["running", "done"] });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" }, extraEnv: { POOPBAGS_SCAN_BUDGET_MS: "1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const r1 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r1.additionalContext.join("\n"), /still running/);
  const r2 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r2.additionalContext.join("\n"), /initial observation/);
  assert.equal(srv.calls.filter((c) => c.includes("POST")).length, 1, "one submission only");
});

test("adversarial: source changed while the scan ran → stale, never completed-clean", async () => {
  // The status GET mutates the tree mid-scan — the finish-time fingerprint
  // must differ from the submitted digest and refuse a clean verdict.
  const fsFiles = new Map([[`${ROOT}/src/lib.rs`, SRC]]);
  const srv = scanServer({ scanId: 60 });
  const inner = srv.fetch;
  srv.fetch = async (url, init) => {
    if (/\/api\/scans\/\d+$/.test(url)) fsFiles.set(`${ROOT}/src/lib.rs`, "pub fn changed_during_scan() {}\n");
    return inner(url, init);
  };
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" }, fsFiles });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /stale/);
  assert.doesNotMatch(notice, /completed-clean/);
  // Stale evidence exists; the scan is never promoted to a baseline.
  const last = JSON.parse([...h.written.entries()].find(([k]) => k.endsWith("last-unknown.json"))[1]);
  assert.match(last.reason, /source changed|stale/i);
});

test("adversarial: partial scan (failed files) → unknown, never completed-clean", async () => {
  const srv = {
    fetch: async (url, init = {}) => {
      if (url.endsWith("/api/scans") && init.method === "POST")
        return { status: 202, ok: true, headers: {}, text: JSON.stringify({ id: 61, status: "running" }) };
      if (/\/api\/scans\/\d+$/.test(url))
        return { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: 61, status: "done", functions_total: 7, violations: 0, threshold: 20, assumed_coverage: 0, files: { total: 5, done: 4, failed: 1, skipped: 0 } }) };
      if (url.includes("/diff"))
        return { status: 200, ok: true, headers: {}, text: diffBody() };
      return { status: 404, ok: false, headers: {}, text: "{}" };
    },
  };
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = result.additionalContext.join("\n");
  assert.match(notice, /unknown|partial/);
  assert.doesNotMatch(notice, /completed-clean/);
});

test("adversarial: hanging HTTP inside a poll is bounded by the remaining deadline", async () => {
  const h = host({ fetch: async () => new Promise(() => {}), sessionRef: { id: "s1" }, extraEnv: { POOPBAGS_SCAN_BUDGET_MS: "30" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const start = Date.now();
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.ok(Date.now() - start < 5000, "boundary returned despite hung transport");
  assert.match(result.additionalContext.join("\n"), /unknown/);
});

test("adversarial: notice is always <= 2000 UTF-8 bytes including the suffix", async () => {
  const longPath = `${ROOT}/${"sub/".repeat(700)}src`;
  const fsFiles = new Map([[`${longPath}/lib.rs`, SRC]]);
  const srv = scanServer({ scanId: 62 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" }, fsFiles });
  await h.hooks.get("classic.PostToolUse")(h.$, { ...edit(), tool_input: { file_path: `${longPath}/lib.rs` } }, passthrough);
  const result = await h.hooks.get("classic.Stop")(h.$, { ...stop(), cwd: longPath.replace(/\/src$/, "") }, passthrough);
  const notice = (result.additionalContext || []).join("\n");
  assert.ok(new TextEncoder().encode(notice).length <= 2000, `notice ${new TextEncoder().encode(notice).length}B`);
});

test("adversarial: coverage_report bytes ride the fingerprint — a report change rescans", async () => {
  const fsFiles = new Map([
    [`${ROOT}/src/lib.rs`, SRC],
    [`${ROOT}/.poopbags.json`, JSON.stringify({ coverage_report: "coverage/lcov.info" })],
    [`${ROOT}/coverage/lcov.info`, "first report"],
  ]);
  const srv1 = scanServer({ scanId: 63 });
  const h = host({ fetch: srv1.fetch, sessionRef: { id: "s1" }, fsFiles });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  await h.hooks.get("classic.Stop")(h.$, stop(), passthrough); // pins baseline 63

  // Only the coverage report bytes change — the fingerprint must differ and
  // the boundary must rescan rather than replay the stored verdict.
  h.fsFiles.set(`${ROOT}/coverage/lcov.info`, "second report, different bytes");
  const srv2 = scanServer({ scanId: 64, diff: diffBody({ scan_id: 64, baseline_id: 63 }) });
  h.$.http.fetch = srv2.fetch;
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.ok(srv2.calls.some((c) => c.includes("POST")), "resubmitted after coverage_report change");
});

test("session isolation: another session's dirty flag is untouched", async () => {
  const srv = scanServer({ scanId: 80 });
  const sessionRef = { id: "s2" };
  const fsFiles = new Map([[`${ROOT}/src/lib.rs`, SRC]]);
  const h = host({ fetch: srv.fetch, sessionRef, fsFiles });
  await h.hooks.get("classic.PostToolUse")(h.$, edit("s2"), passthrough); // s2 dirtied
  sessionRef.id = "s1"; // s1 never edited
  const result = await h.hooks.get("classic.Stop")(h.$, stop("s1"), passthrough);
  assert.equal(result.additionalContext, undefined);
  assert.equal(srv.calls.length, 0);
});

test("downstream result is preserved and context appended", async () => {
  const srv = scanServer({ scanId: 90 });
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const downstream = { additionalContext: ["prior plugin note"], extra: true };
  const result = await h.hooks.get("classic.Stop")(h.$, stop(), () => downstream);
  assert.equal(result.extra, true);
  assert.equal(result.additionalContext[0], "prior plugin note");
  assert.equal(result.additionalContext.length, 2);
});

test("uncertain scan submission retains reservation; late response adopts the scan", async () => {
  let resolvePost;
  const gate = new Promise((r) => (resolvePost = r));
  let posts = 0;
  const fetch = async (url, init = {}) => {
    if (url.endsWith("/api/scans") && init.method === "POST") {
      posts++;
      return gate.then(() => ({ status: 202, ok: true, headers: {}, text: JSON.stringify({ id: 31, status: "running" }) }));
    }
    if (url.includes("/diff")) return { status: 200, ok: true, headers: {}, text: diffBody({ scan_id: 31 }) };
    if (/\/api\/scans\/31$/.test(url)) return okScan(31);
    return { status: 404, ok: false, headers: {}, text: "{}" };
  };
  const h = host({ fetch, sessionRef: { id: "s1" }, extraEnv: { POOPBAGS_SCAN_BUDGET_MS: "500" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const r1 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r1.additionalContext.join("\n"), /outcome unknown|reservation|timed out/);
  assert.equal(posts, 1);
  // Reservation retained: a second dirty boundary submits nothing new.
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const r2 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r2.additionalContext.join("\n"), /outcome is still unknown|reservation/);
  assert.equal(posts, 1);
  // The late POST resolves with a landed scan — next boundary adopts + polls it.
  resolvePost();
  const r3 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r3.additionalContext.join("\n"), /scan #31|initial observation/);
});

test("a scan response over 256KiB bytes is over-cap, never a verdict", async () => {
  const fetch = async (url, init = {}) => {
    if (init.method === "POST") return { status: 202, ok: true, headers: {}, text: JSON.stringify({ id: 32, status: "running" }) };
    if (/\/api\/scans\/32$/.test(url)) return { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: 32, status: "done", pad: "é".repeat(140_000) }) };
    return { status: 404, ok: false, headers: {}, text: "{}" };
  };
  const h = host({ fetch, sessionRef: { id: "s1" } });
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const r = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  const notice = r.additionalContext.join("\n");
  assert.match(notice, /unknown|unreadable/);
  assert.doesNotMatch(notice, /CRAP/);
});

test("restart with unresolved uncertain submission: stays unknown, refuses resubmit, operator resolve clears", async () => {
  const crypto = await import("node:crypto");
  const rootKey = crypto.createHash("sha256").update(ROOT).digest("hex");
  const srv = scanServer({ scanId: 40 });
  const fsFiles = new Map();
  fsFiles.set(`${ROOT}/src/lib.rs`, SRC);
  fsFiles.set(`${STATE}/${rootKey}/state.json`, JSON.stringify({
    schema: "poopbags-mod/1", baseline_id: 7, digest: "d", last_scan_id: 7, notice: null,
    pending: null,
    uncertain_scan: { at: Date.now() - 60_000, client_ref: "ref-old", submitted_digest: "d", tool: "poopbags-mod@0.2.0" },
    dirty_by: { s1: "x" },
  }));
  const h = host({ fetch: srv.fetch, sessionRef: { id: "s1" }, fsFiles });
  const r1 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r1.additionalContext.join("\n"), /unknown|unresolvable/);
  const posts = srv.calls.filter((c) => c.startsWith("POST")).length;
  assert.equal(posts, 0, "no resubmit while uncertain");
  // Operator verifies nothing landed and clears.
  const r2 = await h.hooks.get("command.run")(h.$, { command: "poopbags", args: "resolve none" }, passthrough);
  assert.match(r2.text, /cleared by operator/);
  // Next dirty boundary can submit again.
  await h.hooks.get("classic.PostToolUse")(h.$, edit(), passthrough);
  const r3 = await h.hooks.get("classic.Stop")(h.$, stop(), passthrough);
  assert.match(r3.additionalContext.join("\n"), /scan #40|initial observation/);
});
