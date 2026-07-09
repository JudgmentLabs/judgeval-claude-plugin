#!/usr/bin/env python3
"""Drive a multi-turn interactive-equivalent Claude Code session for tracing tests.

Uses `claude -p --input-format stream-json`, which keeps one claude process
alive across multiple user turns — the same hook sequence (UserPromptSubmit /
Stop per turn, one session_id, growing transcript) an interactive TUI session
produces, but scriptable.

Sends three turns:
  1. a simple deterministic reply
  2. a background subagent delegation (two printf commands) whose
     task-notification relay exercises the follow-up attach path
  3. a history-recall question (verifies conversation continuity)

Prints the session_id; feed it to verify_tracing.py afterwards:

  python3 interactive_driver.py [--cwd DIR]
  JUDGMENT_API_KEY=... JUDGMENT_ORG_ID=... JUDGMENT_PROJECT_ID=... \
      python3 verify_tracing.py <session_id>

The claude process needs the Judgment env vars set for the plugin hooks to
trace, and permission for the Task/Agent tools plus `printf` (passed via
--allowedTools).
"""
import argparse
import json
import os
import queue
import subprocess
import threading
import time

PROMPTS = [
    "Reply with exactly this phrase and nothing else: cerulean sunrise",
    ("Delegate exactly one background subagent. Ask it to run two tiny shell "
     "commands using Bash: printf gamma and printf delta, then report both "
     "outputs. While it runs, say one short sentence: parent is waiting. When "
     "the subagent result arrives, briefly relay it. Keep it concise."),
    ("What exact phrase did I ask you to reply with in my very first message "
     "of this conversation? Answer with just the phrase."),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cwd", default=os.getcwd(),
                    help="workspace directory for the claude session")
    ap.add_argument("--allowed-tools", default="Task,Agent,Bash(printf *)")
    ap.add_argument("--turn-timeout", type=int, default=180)
    opts = ap.parse_args()

    proc = subprocess.Popen(
        [
            "claude", "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--allowedTools", opts.allowed_tools,
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=opts.cwd,
    )

    events = queue.Queue()

    def reader():
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                events.put(json.loads(line))
            except json.JSONDecodeError:
                pass
        events.put(None)

    threading.Thread(target=reader, daemon=True).start()

    state = {"session_id": None}

    def send(text):
        msg = {"type": "user",
               "message": {"role": "user",
                           "content": [{"type": "text", "text": text}]}}
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def wait_for_result(timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ev = events.get(timeout=5)
            except queue.Empty:
                continue
            if ev is None:
                return None
            if ev.get("session_id") and state["session_id"] is None:
                state["session_id"] = ev["session_id"]
            etype = ev.get("type")
            if etype == "result":
                txt = (ev.get("result") or "")[:100].replace("\n", " ")
                print(f"[result] {txt}", flush=True)
                return ev
            if etype == "assistant":
                content = ev.get("message", {}).get("content", [])
                kinds = ",".join(c.get("type", "?") for c in content)
                print(f"[assistant] {kinds}", flush=True)
        return None

    send(PROMPTS[0])
    wait_for_result(opts.turn_timeout)
    print(f"session_id: {state['session_id']}", flush=True)

    # Turn 2: the first result is the parent's reply while the subagent runs;
    # the task-notification relay produces a second result event.
    send(PROMPTS[1])
    wait_for_result(opts.turn_timeout)
    print("waiting for task-notification relay...", flush=True)
    wait_for_result(opts.turn_timeout)

    send(PROMPTS[2])
    wait_for_result(opts.turn_timeout)

    proc.stdin.close()
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()

    print(f"FINAL session_id: {state['session_id']}", flush=True)


if __name__ == "__main__":
    main()
