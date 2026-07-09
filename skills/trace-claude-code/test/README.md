# Tracing verification harness

End-to-end tests for the trace-claude-code plugin: drive real Claude Code
sessions, then assert that the spans on the Judgment platform match the local
session transcripts exactly.

## Setup

Both the claude session and the verifier read the same env vars the plugin
hooks use:

```bash
export JUDGMENT_API_KEY=...
export JUDGMENT_ORG_ID=...
export JUDGMENT_PROJECT_ID=...   # the resolved project uuid traces land in
```

`JUDGMENT_PROJECT_ID` is used by the verifier to query the platform; the
hooks themselves route via the plugin's cached project state.

## Interactive multi-turn test

```bash
python3 interactive_driver.py --cwd /path/to/workspace
```

Runs one long-lived `claude -p --input-format stream-json` process — the same
per-turn hook sequence as an interactive TUI session — through three turns:
a deterministic reply, a background subagent delegation with a notification
relay, and a history-recall question. Prints the `session_id`.

## One-shot (`claude -p`) test

```bash
echo 'Delegate exactly one background subagent. Ask it to run two tiny shell
commands using Bash: printf alpha and printf beta, then report both outputs.
While it runs, say one short sentence: parent is waiting. When the subagent
result arrives, briefly relay it. Keep it concise.' \
  | claude -p --allowedTools "Task,Agent,Bash(printf *)"
```

Find the session id in the hook log (`~/.claude/state/judgeval_hook.log`,
`Turn trace started: ... session=<id>`).

## Verify

```bash
python3 verify_tracing.py <session_id>
```

Cross-checks every span in every trace of the session against the local
transcripts (`~/.claude/projects/<munged cwd>/<session_id>.jsonl` and its
`subagents/` directory):

- root/Task structure, `session_id` and `turn_index` attributes
- parent/child integrity and time containment (no orphans, children inside
  parent windows)
- LLM tokens: every span must match one transcript request's **final** usage
  exactly (catches double-counting when a request's stream chunks interleave
  with tool results)
- no zero-duration LLM spans; model and cost attributes present
- input/output payloads carry conversation history across turns
- subagent containers: parenting, children, window vs subagent transcript
- Subagent Result marker and the notification relay span (nonzero duration)
- trace summary duration vs root span

Exits nonzero on any failure. Note: the platform's trace *summary* duration
is updated asynchronously and can lag the spans by up to ~1 minute after a
session ends — rerun if only that check fails.
