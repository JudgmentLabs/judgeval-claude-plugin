# Judgeval Tracing for Claude Code

Automatically trace Claude Code sessions to Judgeval for observability and debugging.

## Features

- **Session Grouping**: Group Claude turns into the same Judgment session with `judgment.session_id`
- **Turn Tracing**: Create one Judgment trace for each user prompt/assistant response turn
- **Conversation Context**: Store prior user, assistant, system, and tool-result messages in each turn trace input/output
- **LLM Spans**: Log every model call with input/output and token usage
- **Tool Spans**: Track tool invocations (file operations, terminal, MCP tools)
- **Cache Metrics**: Track cache creation and read tokens for prompt caching

## Trace Structure

```
Claude session_id
├── Trace for user turn 1
│   └── Task
│       ├── claude-opus-4-5 (llm span)
│       ├── Read (tool span)
│       └── Subagent: code-reviewer (task span)
└── Trace for user turn 2
    └── Task
        └── claude-opus-4-5 (llm span)
```

## Setup

After installing the plugin, run setup in your project directory:

```bash
cd /path/to/your/project
bash ~/.claude/plugins/marketplaces/judgeval-claude-plugin/skills/trace-claude-code/setup.sh
```

This will prompt you for:
- `JUDGMENT_API_KEY` - Your Judgeval API key
- `JUDGMENT_ORG_ID` - Your organization ID
- `JUDGMENT_API_URL` - API URL (default: https://api.judgmentlabs.ai)
- `JUDGEVAL_CC_PROJECT` - Project name (default: claude-code)

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TRACE_TO_JUDGEVAL` | Yes | Set to `true` to enable tracing |
| `JUDGMENT_API_KEY` | Yes | Your Judgeval API key |
| `JUDGMENT_ORG_ID` | Yes | Your organization ID |
| `JUDGMENT_API_URL` | No | API URL (default: https://api.judgmentlabs.ai) |
| `JUDGEVAL_CC_PROJECT` | No | Project name (default: claude-code) |
| `JUDGEVAL_CC_DEBUG` | No | Set to `true` for debug logging |

## Hooks

| Hook | Trigger | Action |
|------|---------|--------|
| `session_start.sh` | Session begins | Records session metadata |
| `user_prompt_submit.sh` | User sends prompt | Creates a new trace and Task span for the turn |
| `stop_hook.sh` | Response complete | Parses transcript delta and finalizes the turn trace |
| `subagent_stop.sh` | Subagent completes | Parses subagent transcript, creates nested spans |
| `session_end.sh` | Session ends | Fallback-finalizes any open turn trace, then flushes the upload queue |

Hooks never perform network I/O and always exit 0, so they cannot change
Claude Code's behavior or add meaningful latency. Spans are appended to a
local queue (`~/.claude/state/judgeval_queue/`) and uploaded by a detached
background worker (`worker.sh`) with bounded, retried, time-limited requests;
project-name resolution also happens in the worker. Each hook registers with
an explicit timeout as a hard backstop.

## Span Attributes

### Turn Root Span
- `judgment.span_kind`: "task"
- `judgment.input`: JSON envelope with session metadata, prior conversation history, current user prompt, and tool context used by the turn
- `judgment.output`: JSON envelope with session metadata, assistant output, and the conversation after the turn
- `judgment.session_id`: Claude Code session ID
- `turn_index`: Turn number within the Claude session

### LLM Span
- `judgment.span_kind`: "llm"
- `judgment.input`: Conversation history
- `judgment.output`: Model response
- `judgment.llm.model`: Model name
- `judgment.llm.provider`: "anthropic"
- `judgment.usage.non_cached_input_tokens`: Input tokens
- `judgment.usage.output_tokens`: Output tokens
- `judgment.usage.cache_creation_input_tokens`: Cache write tokens
- `judgment.usage.cache_read_input_tokens`: Cache read tokens

### Tool Span
- `judgment.span_kind`: "tool"
- `judgment.input`: Tool input
- `judgment.output`: Tool output
- `tool_name`: Tool identifier

## Logs

Hook logs are written to: `~/.claude/state/judgeval_hook.log`

Enable debug logging:
```bash
export JUDGEVAL_CC_DEBUG=true
```

## Troubleshooting

**Traces not appearing:**
1. Check `TRACE_TO_JUDGEVAL=true` is set
2. Verify API key and org ID are correct
3. Check logs for errors

**Missing spans:**
1. Ensure all hooks are executable
2. Check for jq/curl availability
3. Review debug logs
