// Advisory Poopbags Mod. Native form (hooks.mjs register(on)), same shape as
// licorice's being-memory. No Node imports, provider calls or permission
// changes.
//
// Contract (licorice/docs/portfolio-plan.md, Mod contract):
//   - ADVISORY ONLY. Never returns block/preventContinuation; findings arrive
//     as additionalContext. A future strict gate is an explicit opt-in and is
//     out of this Mod.
//   - Three distinct verdicts: completed-clean, completed-actionable,
//     unknown (unsupported / unavailable / pending / expired baseline /
//     partial / stale). Errors never become success.
//   - Edits mark the canonical project/worktree dirty; at a Stop boundary the
//     real tree is fingerprinted (contents + .poopbags.json + coverage bytes +
//     tool identity). Same fingerprint = same-revision replay, no rescan.
//   - Baselines pin by scan ID, never `latest`. A scan with no comparable
//     baseline is an initial observation, never a passed gate.
//   - Fail-open and bounded: one short notice (<= 2000 UTF-8 bytes) plus a
//     versioned evidence file on disk. Tool failure notices appear once; the
//     scope stays dirty only while a real scan is pending.

const NOTICE_MAX = 2000;
const FILE_CAP = 512;
const TOTAL_CAP = 8 * 1024 * 1024;
const RESP_CAP = 256 * 1024;
const SCAN_BUDGET_MS = 20_000;
const PENDING_MAX_MS = 120_000;
const POLL_MS = 250;
const TOOL = "poopbags-mod@0.2.0";

const SRC_EXTS = /\.(ex|exs|zig|kt|kts|swift|rs)$/;
const SKIP_DIRS = new Set([
  ".git", "deps", "_build", "target", "node_modules", "vendor", "dist",
  "build", ".build", ".zig-cache", "zig-out", ".elixir_ls", ".cargo",
]);
const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
const SCHEMA = "poopbags-mod/1";

async function config($) {
  const api = (await $.env.get("POOPBAGS_API")) || "http://127.0.0.1:4100";
  if (!/^https?:\/\/[^\s/]+[^\s]*$/.test(api)) throw new Error("POOPBAGS_API must be an http(s) URL");
  const home = await $.env.get("HOME");
  const state =
    (await $.env.get("POOPBAGS_MOD_STATE")) ||
    (home ? `${home}/.local/state/poopbags-mod` : null);
  if (!state || !state.startsWith("/")) throw new Error("no state dir: set POOPBAGS_MOD_STATE or HOME");
  const int = (v, dflt, cap) => {
    const n = Number(v);
    return Number.isInteger(n) && n >= 0 && n <= cap ? n : dflt;
  };
  return {
    api: api.replace(/\/+$/, ""),
    state,
    scanBudgetMs: int(await $.env.get("POOPBAGS_SCAN_BUDGET_MS"), SCAN_BUDGET_MS, 60_000),
    pendingMaxMs: int(await $.env.get("POOPBAGS_PENDING_MAX_MS"), PENDING_MAX_MS, 600_000),
  };
}

async function canonicalRoot($, cwd) {
  try {
    const st = await $.fs.stat(cwd, { resolve: true });
    return st.realPath || cwd;
  } catch {
    return cwd;
  }
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Fingerprint the files the analyzer would actually read: source extensions
// under the project minus build/vendor dirs, plus .poopbags.json and the
// coverage report it names. Content bytes, not a touched-path list.
async function fingerprint($, root) {
  const files = [];
  const stack = [""];
  const listErrors = [];
  let truncated = false;

  while (stack.length && files.length <= FILE_CAP) {
    const rel = stack.pop();
    let entries;
    try {
      entries = await $.fs.list(rel ? `${root}/${rel}` : root);
    } catch {
      // A directory that cannot be listed is an omission risk: record it so
      // the boundary can answer unknown rather than certifying a partial tree.
      if (rel) listErrors.push(`${rel} unlistable`);
      else listErrors.push("project root unlistable");
      continue;
    }
    for (const ent of entries) {
      const child = rel ? `${rel}/${ent.name}` : ent.name;
      if (ent.isLink) continue;
      if (ent.kind === "dir") {
        if (!SKIP_DIRS.has(ent.name)) stack.push(child);
      } else if (SRC_EXTS.test(ent.name) || ent.name === ".poopbags.json") {
        files.push(child);
      }
    }
  }
  files.sort();
  if (files.length > FILE_CAP) truncated = true;
  const errors = listErrors;

  const parts = [`tool:${TOOL}`, `cap:${FILE_CAP}/${TOTAL_CAP}`];
  let bytes = 0;
  for (const rel of files.slice(0, FILE_CAP)) {
    let text;
    try {
      text = await $.fs.read(`${root}/${rel}`);
    } catch {
      parts.push(`${rel}:unreadable`);
      errors.push(`${rel} unreadable`);
      continue;
    }
    bytes += new TextEncoder().encode(text).length;
    if (bytes > TOTAL_CAP) { truncated = true; break; }
    parts.push(`${rel}:${await sha256(text)}`);
  }

  // The coverage report bytes ride in the fingerprint when .poopbags.json
  // names one via `coverage_report` (the service's real config key) — a new
  // report without source changes still rescans, and a named-but-missing or
  // unreadable report is a fingerprinted fact, not an omission.
  try {
    const cfgText = await $.fs.read(`${root}/.poopbags.json`);
    let covPath = null;
    try {
      const coverage = JSON.parse(cfgText).coverage_report;
      covPath = typeof coverage === "string" ? coverage : coverage && coverage.path;
    } catch {
      parts.push(".poopbags.json:malformed");
      errors.push(".poopbags.json unparseable");
    }
    if (typeof covPath === "string") {
      try {
        parts.push(`${covPath}:${await sha256(await $.fs.read(`${root}/${covPath}`))}`);
      } catch {
        parts.push(`${covPath}:missing`);
        errors.push(`coverage report ${covPath} unreadable`);
      }
    }
  } catch {
    /* no .poopbags.json — coverage assumed */
  }

  return { digest: await sha256(parts.join("\n")), files: files.length, bytes, truncated, errors };
}

async function loadState($, cfg, rootKey) {
  try {
    return JSON.parse(await $.fs.read(`${cfg.state}/${rootKey}/state.json`));
  } catch {
    return { schema: SCHEMA, baseline_id: null, digest: null, last_scan_id: null, notice: null, pending: null, uncertain_scan: null, dirty_by: {} };
  }
}

async function saveState($, cfg, rootKey, state) {
  await $.fs.write(`${cfg.state}/${rootKey}/state.json`, JSON.stringify(state, null, 2));
}

async function evidence($, cfg, rootKey, name, payload) {
  const path = `${cfg.state}/${rootKey}/${name}`;
  await $.fs.write(path, JSON.stringify({ schema: SCHEMA, ...payload }, null, 2));
  return path;
}

// The qualified SDK's $.http.fetch has no timeout option (HttpInit carries
// method/headers/body/auth/socketPath only). Each request therefore races a
// bounded timer; a request that outlives its slice is abandoned, never
// awaited again — the boundary stays inside its budget. Response text is
// capped before parse; an over-cap body is malformed, not trusted.
async function call($, cfg, method, path, body, timeoutMs = 10_000) {
  const request = $.http.fetch(`${cfg.api}${path}`, {
    method,
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  // The SDK has no abort: a timed-out request still completes server-side.
  // `late` resolves to the same normalized shape so a scan submission can
  // keep its reservation and reconcile the late response at a later boundary.
  const wrap = (r) => {
    const rawText = (r && r.text) || "";
    const over_cap = new TextEncoder().encode(rawText).length > RESP_CAP;
    let parsed = null;
    try { parsed = JSON.parse(over_cap ? "" : rawText); } catch { /* malformed */ }
    return { status: r.status, ok: r.ok && !over_cap, body: parsed, over_cap };
  };
  const late = request.then(wrap, (e) => ({ status: 0, ok: false, body: null, error: String(e) }));
  let timer;
  const res = await Promise.race([
    late.then((w) => ({ kind: "response", w })),
    new Promise((resolve) => { timer = setTimeout(() => resolve({ kind: "timeout" }), Math.max(1, timeoutMs)); }),
  ]);
  clearTimeout(timer);
  if (res.kind === "timeout") return { status: 0, ok: false, body: null, timed_out: true, late };
  if (res.w.error) throw new Error(res.w.error);
  return res.w;
}

// In-flight scan submissions, keyed per session+project. Not persisted: on
// restart the reservation flag survives and releases after orphan_by.
const LATE = new Map();
const lateKey = (rootKey, session) => `${rootKey}${session}`;

// A scan POST whose outcome is unknown may have completed server-side. The
// reservation blocks resubmission until the late response reconciles or
// orphan_by passes — a stray scan is non-mutating garbage, never a run.
async function reconcileUncertain($, cfg, rootKey, state, session) {
  const u = state.uncertain_scan;
  if (!u) return null;
  const late = LATE.get(lateKey(rootKey, session));
  const settled = late ? await Promise.race([late, Promise.resolve("pending")]) : "lost";
  if (settled !== "pending" && settled !== "lost") {
    LATE.delete(lateKey(rootKey, session));
    delete state.uncertain_scan;
    if (settled.ok && settled.body && Number.isInteger(settled.body.id)) {
      state.pending = { scan_id: settled.body.id, since: u.at, submitted_digest: u.submitted_digest, tool: u.tool };
      await saveState($, cfg, rootKey, state);
      return { adopted: settled.body.id };
    }
    await saveState($, cfg, rootKey, state);
    return { lost: `submission failed server-side (http ${settled.status})` };
  }
  // The promise is still in flight or was lost at restart. No list endpoint
  // exists to read back by client_ref, so without the live promise the
  // outcome is unverifiable — stay unknown, hold the slot, operator resolves.
  if (settled === "lost" && !u.unresolvable) {
    u.unresolvable = Date.now();
    await evidence($, cfg, rootKey, "submit-unresolvable.json", { ts: Date.now(), session, client_ref: u.client_ref, note: "in-flight promise lost (restart); cannot verify whether the POST landed" });
    await saveState($, cfg, rootKey, state);
  }
  return { waiting: true, unresolvable: settled === "lost" };
}

// Cut at a UTF-8 codepoint boundary with the suffix reserved inside the cap —
// every notice path stays <= NOTICE_MAX bytes total.
function fit(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length <= NOTICE_MAX) return text;
  const suffix = new TextEncoder().encode("…");
  let end = NOTICE_MAX - suffix.length;
  while (end > 0 && (bytes[end] & 0xC0) === 0x80) end--;
  return new TextDecoder().decode(bytes.slice(0, end)) + "…";
}

function footer(scan) {
  // Honest labeling: the coverage object exists on every scan; it is measured
  // only when the service actually ingested a report for real functions.
  // Mixed and warned coverage stay visible rather than rounding to clean.
  const measured = scan?.coverage?.measured_functions || 0;
  const assumed = scan?.coverage?.assumed_functions || 0;
  const cov =
    measured > 0 && assumed > 0
      ? `mixed (${measured} measured, ${assumed} assumed fns)`
      : measured > 0
        ? `measured (${measured} fns)`
        : `assumed ${scan?.assumed_coverage ?? 0}%`;
  const warn = scan?.coverage_warning ? `; coverage warning: ${String(scan.coverage_warning).slice(0, 200)}` : "";
  return `advisory only — lexical analyzer (rust: token-level approximation, impl/match/closure guards); coverage ${cov}${warn}; never blocks.`;
}

async function submitScan($, cfg, rootKey, state, root, session, fpDigest) {
  // Reserve before POST: a restart or reentrant boundary during flight
  // cannot double-submit; the flag persists until reconcile/operator resolve.
  const client_ref = `poopbags-mod:${session}:${Date.now()}`;
  state.uncertain_scan = { at: Date.now(), client_ref, submitted_digest: fpDigest, tool: TOOL };
  await saveState($, cfg, rootKey, state);
  const res = await call($, cfg, "POST", "/api/scans", {
    project_path: root,
    label: client_ref,
  }, Math.max(500, cfg.scanBudgetMs)).catch((e) => ({ transport_error: true, error: String(e) }));
  if (res.timed_out) return { uncertain: true, late: res.late };
  if (res.transport_error) { delete state.uncertain_scan; await saveState($, cfg, rootKey, state); throw new Error(res.error); }
  if (res.ok && res.body && Number.isInteger(res.body.id)) {
    delete state.uncertain_scan;
    return { scan_id: res.body.id };
  }
  delete state.uncertain_scan;
  await saveState($, cfg, rootKey, state);
  return { error: `submit rejected (http ${res.status})` };
}

async function pollScan($, cfg, id, deadlineMs) {
  for (;;) {
    const remaining = deadlineMs - Date.now();
    if (remaining <= 0) return { done: false, terminal: null };
    // Each request is bounded by the remaining budget; a hung transport can
    // no longer hold the loop past its deadline.
    const res = await call($, cfg, "GET", `/api/scans/${id}`, undefined, remaining);
    if (res.ok && res.body) {
      if (res.body.status === "done") return { done: true, scan: res.body };
      if (["error", "failed", "cancelled"].includes(res.body.status))
        return { done: false, scan: res.body, terminal: res.body.status };
    } else if (res.status === 404 || res.status === 410) {
      return { done: false, terminal: `scan ${id} gone (http ${res.status})` };
    } else if (res.over_cap) {
      // Over-cap is deterministically unreadable — never spin out the
      // remaining deadline hoping a truncated body turns valid.
      return { done: false, terminal: `scan ${id} response over-cap (>256KiB)` };
    }
    if (res.timed_out) return { done: false, terminal: null, timed_out: true };
    if (Date.now() > deadlineMs) return { done: false, terminal: null };
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

function violationsNotice(state, root, scan, diff, evidencePath) {
  const head =
    diff === null
      ? `poop_bags: initial observation on ${root} — scan #${scan.id}: ${scan.functions_total ?? "?"} functions, ${scan.violations ?? 0} violations over threshold ${scan.threshold ?? "?"}. Baseline pinned to #${scan.id}; this is not a passed regression gate.`
      : diff.gate_passed && diff.comparable
        ? `poop_bags: completed-clean — scan #${scan.id} vs baseline #${diff.baseline_id}: no new violations.`
        : null;
  if (head) return fit(`${head}\n${footer(scan)}\nevidence: ${evidencePath}`);

  const rows = (diff.rows || []).filter(
    (r) => ["introduced", "regressed"].includes(r.outcome) && r.violation
  );
  const top = rows
    .slice(0, 3)
    .map((r) => `${r.path} ${r.module ? `${r.module}.` : ""}${r.function} CRAP ${r.current_crap}`)
    .join("; ");
  const counts = diff.summary || {};
  const more = rows.length > 3 ? ` +${rows.length - 3} more` : "";
  const comparability = diff.comparable ? "" : ` not fully comparable (${(diff.warnings || []).join("; ") || "policy drift"}).`;
  return fit(
    `poop_bags: completed-actionable — scan #${scan.id} vs baseline #${diff.baseline_id}: ${rows.length} introduced/regressed violations${more}.${comparability}\n` +
      `introduced ${counts.introduced ?? 0}, regressed ${counts.regressed ?? 0}, resolved ${counts.resolved ?? 0}, removed ${counts.removed ?? 0}.` +
      (top ? `\ntop: ${top}` : "") +
      `\n${footer(scan)}\nevidence: ${evidencePath}`
  );
}

function unknownNotice(reason, evidencePath) {
  return fit(`poop_bags: unknown — ${reason}.\nevidence: ${evidencePath}\nno scan verdict; source unchanged, never blocks.`);
}

async function boundary($, cfg, e, root, session) {
  const rootKey = await sha256(root);
  const state = await loadState($, cfg, rootKey);

  if (!(state.dirty_by && state.dirty_by[session])) return null;

  // An unresolved scan POST keeps the reservation — reconcile it before any
  // new submission so a late-landed scan is adopted, not duplicated.
  const recon = await reconcileUncertain($, cfg, rootKey, state, session);
  if (recon && recon.waiting) {
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, reason: "scan submission outcome unresolved", submitted_at: state.uncertain_scan && state.uncertain_scan.at });
    return unknownNotice("a scan submission's outcome is still unknown — reservation retained; reconciles at a later boundary", path);
  }

  const fp = await fingerprint($, root);
  if (fp.truncated || fp.errors.length) {
    const reason = fp.truncated
      ? `scope exceeds fingerprint bounds (${fp.files} files)`
      : `unreadable scope (${fp.errors[0]}${fp.errors.length > 1 ? ` +${fp.errors.length - 1} more` : ""})`;
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, reason, files: fp.files, bytes: fp.bytes, errors: fp.errors });
    state.dirty_by[session] = null;
    await saveState($, cfg, rootKey, state);
    return unknownNotice(reason, path);
  }

  // Same-revision replay: unchanged fingerprint answers with the stored
  // verdict instead of rescanning.
  if (state.digest === fp.digest && state.notice) {
    state.dirty_by[session] = null;
    await saveState($, cfg, rootKey, state);
    return state.notice;
  }

  // A pending scan (submitted now or adopted from a late POST) keeps polling
  // across boundaries — never resubmits.
  if (state.pending && state.pending.scan_id) {
    const elapsed = Date.now() - state.pending.since;
    const budget = Math.max(0, Math.min(cfg.scanBudgetMs, cfg.pendingMaxMs - elapsed));
    const outcome = await pollScan($, cfg, state.pending.scan_id, Date.now() + budget);
    if (!outcome.done && !outcome.terminal) {
      if (elapsed >= cfg.pendingMaxMs) {
        const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, reason: "pending scan exceeded bound", scan_id: state.pending.scan_id });
        state.pending = null;
        state.dirty_by[session] = null;
        await saveState($, cfg, rootKey, state);
        return unknownNotice(`scan #${state.last_scan_id || "?"} did not complete within bound`, path);
      }
      return fit(`poop_bags: unknown — scan #${state.pending.scan_id} still running; reports at the next boundary. Never blocks.`);
    }
    return finish($, cfg, root, rootKey, state, session, outcome, state.pending.scan_id, state.pending.submitted_digest, state.pending.tool);
  }

  // Fresh submission — the fingerprint taken NOW is what the scan will see;
  // it is persisted on the pending record so a source change mid-scan can be
  // detected at finish instead of attached to different source.
  const submitted = await submitScan($, cfg, rootKey, state, root, session, fp.digest);
  if (submitted.uncertain) {
    LATE.set(lateKey(rootKey, session), submitted.late);
    state.dirty_by[session] = null;
    await saveState($, cfg, rootKey, state);
    const path = await evidence($, cfg, rootKey, "submit-uncertain.json", { ts: Date.now(), root, session, client_ref: state.uncertain_scan.client_ref, source_digest: fp.digest });
    return unknownNotice("scan submission timed out — outcome unknown; the request may still complete server-side; reservation retained until reconcile or operator resolve", path);
  }
  if (submitted.error) {
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, reason: submitted.error, digest: fp.digest });
    state.dirty_by[session] = null;
    await saveState($, cfg, rootKey, state);
    return unknownNotice(submitted.error, path);
  }

  state.pending = { scan_id: submitted.scan_id, since: Date.now(), submitted_digest: fp.digest, tool: TOOL };
  const outcome = await pollScan($, cfg, submitted.scan_id, Date.now() + cfg.scanBudgetMs);
  if (!outcome.done && !outcome.terminal) {
    await saveState($, cfg, rootKey, state);
    return fit(`poop_bags: unknown — scan #${submitted.scan_id} still running; reports at the next boundary. Never blocks.`);
  }
  return finish($, cfg, root, rootKey, state, session, outcome, submitted.scan_id, fp.digest, TOOL);
}

async function finish($, cfg, root, rootKey, state, session, outcome, scanId, submittedDigest, submittedTool) {
  state.pending = null;
  state.dirty_by[session] = null;
  state.last_scan_id = scanId;

  if (!outcome.done) {
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, scan_id: scanId, terminal: outcome.terminal, scan: outcome.scan || null });
    state.digest = null;
    await saveState($, cfg, rootKey, state);
    return unknownNotice(`scan #${scanId} ended ${outcome.terminal}`, path);
  }

  const scan = outcome.scan;

  // The verdict belongs to the source the scan was submitted against. Re-
  // fingerprint now: a tree that changed mid-scan (or a tool build that
  // changed between submit and finish) makes this result stale — kept as
  // evidence, never the current baseline or a replayable clean verdict.
  const fpNow = await fingerprint($, root);
  const staleReason =
    submittedTool && submittedTool !== TOOL
      ? `tool build changed mid-scan (${submittedTool} -> ${TOOL})`
      : !submittedDigest
        ? "submitted fingerprint missing (pre-repair pending record)"
        : submittedDigest !== fpNow.digest
          ? "source changed while the scan ran"
          : fpNow.errors.length
            ? `unreadable scope at finish (${fpNow.errors[0]})`
            : null;
  if (staleReason) {
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, scan_id: scanId, reason: staleReason, submitted_digest: submittedDigest, digest_at_finish: fpNow.digest });
    state.digest = null;
    state.notice = null;
    await saveState($, cfg, rootKey, state);
    return unknownNotice(`stale — ${staleReason}; scan #${scanId} not promoted`, path);
  }
  const fp = fpNow;

  // A partial scan cannot certify a diff: failed or missing files make the
  // function set incomplete, so the result is unknown, not clean.
  const files = scan.files || {};
  if ((files.failed || 0) > 0 || (files.total != null && files.done != null && files.done < files.total)) {
    const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, scan_id: scanId, reason: "partial scan", files });
    state.digest = null;
    await saveState($, cfg, rootKey, state);
    return unknownNotice(`partial — scan #${scanId} incomplete (${files.failed || 0} failed, ${files.done ?? "?"}/${files.total ?? "?"} files)`, path);
  }

  let notice;
  if (state.baseline_id == null) {
    // No comparable baseline: initial observation, pinned by ID.
    state.baseline_id = scanId;
    const path = await evidence($, cfg, rootKey, `report-${scanId}.json`, { ts: Date.now(), root, session, digest: fp.digest, scan_id: scanId, baseline_id: null, kind: "initial", scan });
    notice = violationsNotice(state, root, scan, null, path);
  } else {
    const diffRes = await call($, cfg, "GET", `/api/scans/${scanId}/diff?against=${state.baseline_id}`, undefined, Math.max(2_000, cfg.scanBudgetMs));
    if (diffRes.ok && diffRes.body) {
      const path = await evidence($, cfg, rootKey, `report-${scanId}.json`, { ts: Date.now(), root, session, digest: fp.digest, scan_id: scanId, baseline_id: state.baseline_id, kind: "diff", scan, diff: diffRes.body });
      notice = violationsNotice(state, root, scan, diffRes.body, path);
    } else if (diffRes.status === 404 || diffRes.status === 410) {
      // Missing/expired baseline: this scan becomes the new pinned baseline
      // and reports as an initial observation — never a passed gate.
      const reason = diffRes.body && diffRes.body.error ? diffRes.body.error : `http ${diffRes.status}`;
      state.baseline_id = scanId;
      const path = await evidence($, cfg, rootKey, `report-${scanId}.json`, { ts: Date.now(), root, session, digest: fp.digest, scan_id: scanId, prior_baseline: "expired", kind: "initial", scan });
      notice = unknownNotice(`baseline expired (${reason}); scan #${scanId} is a fresh initial observation, now pinned`, path);
    } else {
      const path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, scan_id: scanId, reason: `diff rejected (http ${diffRes.status})` });
      notice = unknownNotice(`diff unavailable (http ${diffRes.status})`, path);
    }
  }

  state.digest = fp.digest;
  state.notice = notice;
  await saveState($, cfg, rootKey, state);
  return notice;
}

export function register(on) {
  on("session.start", async ($, e, next) => {
    await $.command.register({ name: "poopbags", description: "Advisory CRAP status: last scan, pinned baseline, dirty scopes" });
    return next(e);
  });

  on("command.run", { command: "poopbags" }, async ($, e) => {
    try {
      const cfg = await config($);
      const session = await $.session.id();
      const root = await canonicalRoot($, (await $.env.get("PWD")) || ".");
      const rootKey = await sha256(root);
      const state = await loadState($, cfg, rootKey);
      const args = String((e && e.args) || "").trim().split(/\s+/).filter(Boolean);
      // Operator resolution for an unverifiable uncertain scan submission:
      // adopt a scan id found on the service, or clear after verifying none.
      if (args[0] === "resolve") {
        const u = state.uncertain_scan;
        if (!u) return { text: "poop_bags: no uncertain submission for this session+project." };
        if (args[1] === "none") {
          delete state.uncertain_scan;
          await saveState($, cfg, rootKey, state);
          return { text: `poop_bags: reservation cleared by operator (ref ${u.client_ref}).` };
        }
        if (!/^\d+$/.test(args[1] || "")) return { text: "poop_bags: usage — /poopbags resolve <scan_id|none>" };
        const show = await call($, cfg, "GET", `/api/scans/${args[1]}`);
        if (!show.ok || !show.body || !Number.isInteger(show.body.id)) {
          return { text: `poop_bags: scan #${args[1]} not readable on the service (http ${show.status}); reservation kept.` };
        }
        state.pending = { scan_id: show.body.id, since: u.at, submitted_digest: u.submitted_digest, tool: u.tool };
        delete state.uncertain_scan;
        await saveState($, cfg, rootKey, state);
        return { text: `poop_bags: scan #${args[1]} adopted by operator (ref ${u.client_ref}); polls at the next boundary.` };
      }
      const dirty = state.dirty_by && state.dirty_by[session] ? "yes" : "no";
      const uncertain = state.uncertain_scan ? `; uncertain submission ${state.uncertain_scan.client_ref} since ${new Date(state.uncertain_scan.at).toISOString()}${state.uncertain_scan.unresolvable ? " (unresolvable — /poopbags resolve <id|none>)" : ""}` : "";
      return {
        text:
          `poop_bags advisory — root ${root}\n` +
          `baseline: ${state.baseline_id ?? "none"}; last scan: ${state.last_scan_id ?? "none"}; ` +
          `pending: ${state.pending ? state.pending.scan_id : "none"}; dirty this session: ${dirty}${uncertain}\n` +
          `state: ${cfg.state}/${rootKey}/`,
      };
    } catch (err) {
      return { text: `poop_bags advisory unavailable: ${err.message}` };
    }
  });

  on("classic.PostToolUse", async ($, e, next) => {
    try {
      if (EDIT_TOOLS.has(e.tool_name)) {
        const ok =
          !e.tool_response ||
          !(e.tool_response.error || e.tool_response.is_error === true || e.tool_response.isError === true);
        if (ok) {
          const cfg = await config($);
          const session = await $.session.id();
          const root = await canonicalRoot($, e.cwd);
          const rootKey = await sha256(root);
          const state = await loadState($, cfg, rootKey);
          (state.dirty_by ||= {})[session] = Date.now();
          await saveState($, cfg, rootKey, state);
        }
      }
    } catch {
      /* dirty marking is advisory; a failed mark is a no-op, never a retry */
    }
    return next(e);
  });

  on("classic.Stop", async ($, e, next) => {
    const result = await next(e);
    // Repeated Stop inside the same hook loop without new edits: the stored
    // verdict already answered; never scan twice. Any failure degrades to one
    // short unknown-notice with evidence on disk — never a thrown retry.
    let notice = null;
    let cfg = null, rootKey = null, root = null, session = null;
    try {
      cfg = await config($);
      session = await $.session.id();
      root = await canonicalRoot($, e.cwd);
      rootKey = await sha256(root);
      notice = await boundary($, cfg, e, root, session);
    } catch (err) {
      const reason = String((err && err.message) || err).slice(0, 300);
      let path = "(no evidence path)";
      try {
        if (cfg && rootKey) path = await evidence($, cfg, rootKey, "last-unknown.json", { ts: Date.now(), root, session, reason });
      } catch { /* evidence failure only shortens the notice */ }
      notice = unknownNotice(reason, path);
      try { await $.ui.log("poop_bags advisory degraded; see notice/evidence."); } catch { /* a failed log must not turn a stop into a retry */ }
    }
    if (notice) {
      const ctx = (result && result.additionalContext) || [];
      return { ...(result || {}), additionalContext: [...ctx, notice] };
    }
    return result;
  });
}
