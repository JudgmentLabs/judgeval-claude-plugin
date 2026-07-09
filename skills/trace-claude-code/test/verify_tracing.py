#!/usr/bin/env python3
"""Verify plugin tracing end to end: platform spans vs local transcripts.

For every trace in a session, checks:
  - root/Task span structure, session_id and turn_index attributes
  - parent/child integrity (no orphans) and time containment
  - LLM span tokens match the transcript's per-request final usage exactly
  - no zero-duration LLM spans; model and cost attributes present
  - input/output payloads carry conversation history across turns
  - subagent containers: parenting, child spans, window vs subagent transcript
  - subagent-result marker and notification relay span (nonzero duration)
  - trace summary duration matches the root span

Configuration (same env vars the plugin hooks use):
  JUDGMENT_API_KEY     (required)
  JUDGMENT_ORG_ID      (required)
  JUDGMENT_PROJECT_ID  (required; the *resolved* project uuid traces land in)
  JUDGMENT_MCP_URL     (default https://mcp.judgmentlabs.ai)

Usage:
  verify_tracing.py <session_id> [--transcript-dir DIR]

The transcript dir defaults to the Claude Code project dir for the current
working directory (~/.claude/projects/<munged cwd>). Exits nonzero on any
failed check.

Note: the platform trace summary (duration) is updated asynchronously and can
lag the spans by up to ~1 minute; rerun if that single check fails right
after a session ends.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

MCP = os.environ.get("JUDGMENT_MCP_URL", "https://mcp.judgmentlabs.ai")
KEY = os.environ.get("JUDGMENT_API_KEY", "")
ORG = os.environ.get("JUDGMENT_ORG_ID", "")
PROJ = os.environ.get("JUDGMENT_PROJECT_ID", "")

TOL_US = 5000  # tolerance for ms-truncated timestamps

failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(f"{name}: {detail}")


def mcp(tool, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": args}})
    out = subprocess.run(
        ["curl", "-sS", "-X", "POST", MCP,
         "-H", "Content-Type: application/json",
         "-H", "Accept: application/json, text/event-stream",
         "-H", f"Authorization: Bearer {KEY}",
         "-H", f"X-Organization-Id: {ORG}",
         "-H", f"X-Project-Id: {PROJ}",
         "--data-binary", "@-"],
        input=body, capture_output=True, text=True).stdout
    resp = json.loads(out)
    text = resp["result"]["content"][0]["text"]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise RuntimeError(f"MCP {tool} returned non-JSON: {text[:200]}")


def read_attr_full(trace_id, span_id, key_name):
    val, offset = "", 0
    while True:
        r = mcp("read_span_attribute", {
            "organization_id": ORG, "project_id": PROJ, "trace_id": trace_id,
            "span_id": span_id, "attribute_key": key_name,
            "offset": offset, "length": 25000})
        chunk = r.get("value", "")
        val += chunk
        total = r.get("total_chars", len(val))
        offset = len(val)
        if offset >= total or not chunk:
            break
    return val


def iso_us(ts):
    from datetime import datetime
    return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1e6)


def load_transcript(path):
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return recs


def usage_by_request(recs):
    """requestId -> final (last-chunk) usage, matching the plugin's semantics."""
    req = {}
    for r in recs:
        if r.get("type") != "assistant":
            continue
        rid = r.get("requestId")
        u = (r.get("message") or {}).get("usage") or {}
        if rid and u:
            req[rid] = u
    return req


def default_transcript_dir():
    munged = re.sub(r"[/.]", "-", os.getcwd())
    return os.path.expanduser(f"~/.claude/projects/{munged}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session_id")
    ap.add_argument("--transcript-dir", default=default_transcript_dir())
    opts = ap.parse_args()

    for var, val in [("JUDGMENT_API_KEY", KEY), ("JUDGMENT_ORG_ID", ORG),
                     ("JUDGMENT_PROJECT_ID", PROJ)]:
        if not val:
            sys.exit(f"error: {var} is not set")

    session_id = opts.session_id
    tdir = opts.transcript_dir
    main_path = f"{tdir}/{session_id}.jsonl"
    if not os.path.exists(main_path):
        sys.exit(f"error: transcript not found: {main_path}")
    main_t = load_transcript(main_path)

    tids = mcp("get_session_trace_ids", {"organization_id": ORG, "project_id": PROJ,
                                         "session_id": session_id})["trace_ids"]
    print(f"session {session_id}: {len(tids)} trace(s)")
    sdetail = mcp("get_session_detail", {"organization_id": ORG, "project_id": PROJ,
                                         "session_id": session_id})

    all_traces = {}
    for tid in tids:
        spans = mcp("get_trace_spans", {"organization_id": ORG, "project_id": PROJ,
                                        "trace_id": tid})
        if isinstance(spans, dict):
            spans = spans.get("spans", [])
        detail = mcp("get_trace_detail", {"organization_id": ORG, "project_id": PROJ,
                                          "trace_id": tid})
        details = []
        for i in range(0, len(spans), 20):
            batch = [{"trace_id": tid, "span_id": s["span_id"]} for s in spans[i:i+20]]
            r = mcp("get_trace_span", {"organization_id": ORG, "project_id": PROJ,
                                       "spans": batch})
            details.extend(r if isinstance(r, list) else [r])
        all_traces[tid] = {"spans": spans, "detail": detail,
                           "by_id": {d["span_id"]: d for d in details}}

    def root_of(tinfo):
        for s in tinfo["spans"]:
            if not s.get("parent_span_id"):
                return tinfo["by_id"][s["span_id"]]
        return None

    ordered = sorted(all_traces.items(),
                     key=lambda kv: (int(root_of(kv[1])["span_attributes"].get("turn_index", 0)),
                                     root_of(kv[1])["timestamp"]))

    main_usage = usage_by_request(main_t)
    used_requests = set()

    def ai(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return -1

    prev_turn_output = None
    for turn_no, (tid, tinfo) in enumerate(ordered, 1):
        print(f"\n=== turn {turn_no} — trace {tid} ===")
        spans, by_id = tinfo["spans"], tinfo["by_id"]
        root = root_of(tinfo)
        task = next((by_id[s["span_id"]] for s in spans
                     if s["span_name"] == "Task" and s["span_kind"] == "task"), None)

        check("root span exists", root is not None)
        check("Task span exists", task is not None)
        if not root or not task:
            continue

        ra = root["span_attributes"]
        check("root session_id attr", ra.get("judgment.session_id") == session_id,
              f"got {ra.get('judgment.session_id')}")
        check("root turn_index", int(ra.get("turn_index", -1)) == turn_no,
              f"got {ra.get('turn_index')}")
        check("Task parented to root", task["parent_span_id"] == root["span_id"])
        check("trace detail duration == root duration",
              str(tinfo["detail"]["duration"]) == str(root["duration"]),
              f"{tinfo['detail']['duration']} vs {root['duration']} (summary may lag; rerun)")

        root_start = root["timestamp"]
        root_end = root_start + int(root["duration"]) // 1000

        llm_spans = [by_id[s["span_id"]] for s in spans if s["span_kind"] == "llm"]
        tool_spans = [by_id[s["span_id"]] for s in spans if s["span_kind"] == "tool"]
        task_spans = [by_id[s["span_id"]] for s in spans if s["span_kind"] == "task"]

        bad = [s for s in llm_spans + tool_spans + task_spans
               if s["timestamp"] < root_start - TOL_US
               or s["timestamp"] + int(s["duration"]) // 1000 > root_end + TOL_US]
        check("all spans within root window", not bad,
              "; ".join(s["span_name"] for s in bad))

        ids = {s["span_id"] for s in spans}
        orphans = [s["span_name"] for s in spans
                   if s.get("parent_span_id") and s["parent_span_id"] not in ids]
        check("no orphan spans", not orphans, str(orphans))

        sub_ts = {}
        for p in glob.glob(f"{tdir}/{session_id}/subagents/agent-*.jsonl"):
            sub_ts[os.path.basename(p)[6:-6]] = load_transcript(p)
        all_usage = dict(main_usage)
        for recs in sub_ts.values():
            all_usage.update(usage_by_request(recs))

        zero_dur_llm = [s for s in llm_spans if int(s["duration"]) == 0]
        check("no zero-duration LLM spans", not zero_dur_llm,
              str([s["span_id"] for s in zero_dur_llm]))

        for s in llm_spans:
            a = s["span_attributes"]
            toks = (ai(a.get("judgment.usage.non_cached_input_tokens")),
                    ai(a.get("judgment.usage.output_tokens")),
                    ai(a.get("judgment.usage.cache_creation_input_tokens")),
                    ai(a.get("judgment.usage.cache_read_input_tokens")))
            match = None
            for rid, u in all_usage.items():
                if rid in used_requests:
                    continue
                if (u.get("input_tokens", 0), u.get("output_tokens", 0),
                        u.get("cache_creation_input_tokens", 0),
                        u.get("cache_read_input_tokens", 0)) == toks:
                    match = rid
                    break
            if match:
                used_requests.add(match)
            check(f"llm {s['span_id'][:8]} tokens match a transcript request",
                  match is not None, f"tokens={toks}")
            check(f"llm {s['span_id'][:8]} has model attr",
                  bool(a.get("judgment.llm.model")))
            check(f"llm {s['span_id'][:8]} has cost",
                  float(a.get("judgment.usage.total_cost_usd", 0) or 0) > 0)

        tin = task["span_attributes"].get("judgment.input", "")
        tout = task["span_attributes"].get("judgment.output", "")
        check("Task input non-empty", bool(tin))
        check("Task output non-empty", bool(tout))

        if turn_no > 1 and prev_turn_output and llm_spans:
            first_llm = min(llm_spans, key=lambda s: s["timestamp"])
            full_in = read_attr_full(tid, first_llm["span_id"], "judgment.input")
            check(f"turn {turn_no} LLM input contains previous turn's output",
                  prev_turn_output[:40] in full_in,
                  f"looking for {prev_turn_output[:40]!r}")

        full_out = read_attr_full(tid, task["span_id"], "judgment.output")
        try:
            out_obj = json.loads(json.loads(full_out) if full_out.startswith('"') else full_out)
        except (json.JSONDecodeError, TypeError):
            out_obj = None
        if isinstance(out_obj, dict):
            prev_turn_output = out_obj.get("assistant_output") or prev_turn_output
            check("Task output has messages array",
                  isinstance(out_obj.get("messages"), list) and len(out_obj["messages"]) > 0)
            check("Task output has assistant_output",
                  bool(out_obj.get("assistant_output")))

        containers = [s for s in task_spans if s["span_name"].startswith("Subagent:")]
        for c in containers:
            sub_id = c["span_name"].split(": ")[1]
            check(f"subagent {sub_id} parented to Task span",
                  c["parent_span_id"] == task["span_id"],
                  f"parent={c['parent_span_id']}")
            kids = [s for s in llm_spans + tool_spans
                    if s["parent_span_id"] == c["span_id"]]
            check(f"subagent {sub_id} has child spans", len(kids) >= 2, f"{len(kids)} kids")
            c_start = c["timestamp"]
            c_end = c_start + int(c["duration"]) // 1000
            bad_kids = [k for k in kids if k["timestamp"] < c_start - TOL_US
                        or k["timestamp"] + int(k["duration"]) // 1000 > c_end + TOL_US]
            check(f"subagent {sub_id} children within container window", not bad_kids,
                  str([k["span_name"] for k in bad_kids]))
            if sub_id in sub_ts:
                times = [iso_us(r["timestamp"]) for r in sub_ts[sub_id] if r.get("timestamp")]
                check(f"subagent {sub_id} container start matches transcript",
                      abs(c_start - min(times)) < TOL_US, f"{c_start} vs {min(times)}")
                check(f"subagent {sub_id} container end matches transcript",
                      abs(c_end - max(times)) < TOL_US, f"{c_end} vs {max(times)}")

        markers = [s for s in task_spans if s["span_name"].startswith("Subagent Result:")]
        if containers:
            check("Subagent Result marker present", len(markers) >= 1)
            c_end = max(c["timestamp"] + int(c["duration"]) // 1000 for c in containers)
            relays = [s for s in llm_spans
                      if s["parent_span_id"] == task["span_id"] and s["timestamp"] >= c_end]
            check("relay LLM span present after subagent", len(relays) >= 1)
            for r in relays:
                check(f"relay {r['span_id'][:8]} duration > 0", int(r["duration"]) > 0)

    print(f"\nsession trace_count on platform: {sdetail.get('trace_count')}")
    print("\n" + "=" * 50)
    if failures:
        print(f"RESULT: {len(failures)} FAILURE(S)")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("RESULT: ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
