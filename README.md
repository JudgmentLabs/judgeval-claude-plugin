# Judgeval Claude plugins

Claude Code plugins for Judgeval - LLM evaluation, logging, observability, and tracing.

## Plugins

### 1. Judgeval (evaluation & logging)

Enables AI agents to use Judgeval for LLM evaluation, logging, and observability.

```bash
claude plugin marketplace add judgmentlabs/judgeval-claude-plugin
claude plugin install judgeval@judgeval-claude-plugin
```

### 2. Trace Claude Code (observability)

Automatically trace Claude Code conversations to Judgeval.

```bash
claude plugin install trace-claude-code@judgeval-claude-plugin
```

See [trace-claude-code/SKILL.md](skills/trace-claude-code/SKILL.md) for setup instructions.

## Agent skills

This repo includes skills built on the open [Agent Skills](https://agentskills.io/home) format, compatible with Claude Code, Cursor, Amp, and other agents.

**Install all skills:**
```bash
curl -sL https://github.com/judgmentlabs/judgeval-claude-plugin/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 judgeval-claude-plugin-main/skills
```

Available skills:
- [trace-claude-code](skills/trace-claude-code/SKILL.md) - Automatic conversation tracing

## Setup

Create a `.env` file in your project directory:

```
JUDGMENT_API_KEY=your-api-key-here
JUDGMENT_ORG_ID=your-org-id-here
```

The plugin scripts automatically load `.env` files from the current directory or parent directories.

## What the plugin provides

### Tracing

The trace-claude-code skill provides automatic tracing of Claude Code conversations:

```
Claude Code Session (root trace)
├── Turn 1: "Add error handling"
│   ├── LLM: claude-opus-4-5
│   ├── Read: src/app.ts
│   ├── Edit: src/app.ts
│   └── LLM: claude-opus-4-5
├── Turn 2: "Now run the tests"
│   ├── LLM: claude-opus-4-5
│   ├── Terminal: npm test
│   └── LLM: claude-opus-4-5
└── Turn 3: "Great, commit this"
    └── ...
```

**Features:**
- Session, turn, and LLM span tracking
- Token usage with cache metrics
- Tool invocation logging

### SDK Integration

For programmatic tracing, use the Judgeval SDK:

```python
from judgeval.v1 import Judgeval
from judgeval.v1.integrations.claude_agent_sdk import setup_claude_agent_sdk

judgeval = Judgeval()
tracer = judgeval.tracer.create(project_name="my-project")
setup_claude_agent_sdk(tracer)

# Now use claude_agent_sdk - all calls automatically traced
```

## Project structure

```
judgeval-claude-plugin/
├── .claude-plugin/
│   ├── plugin.json         # Plugin manifest
│   └── marketplace.json    # Marketplace index
├── skills/
│   └── trace-claude-code/
│       ├── SKILL.md        # Claude Code tracing skill
│       ├── setup.sh        # Setup script
│       └── hooks/
│           ├── common.sh
│           ├── session_start.sh
│           ├── user_prompt_submit.sh
│           ├── post_tool_use.sh
│           ├── stop_hook.sh
│           └── session_end.sh
└── README.md
```

## Development

### Prerequisites

- Python 3.10+
- [uv](https://docs.astral.sh/uv/) package manager (optional)

### Local testing

Test the plugin without installing from marketplace:

```bash
claude --plugin-dir /path/to/judgeval-claude-plugin
```

### Manual hook testing

You can test individual hooks by piping JSON input:

```bash
# Test session start
echo '{"session_id": "test-123", "cwd": "/path/to/project"}' | \
  TRACE_TO_JUDGEVAL=true \
  JUDGMENT_API_KEY=your-key \
  JUDGMENT_ORG_ID=your-org \
  bash skills/trace-claude-code/hooks/session_start.sh

# Check logs
cat ~/.claude/state/judgeval_hook.log
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TRACE_TO_JUDGEVAL` | Yes | Set to `"true"` to enable tracing |
| `JUDGMENT_API_KEY` | Yes | Your Judgment API key |
| `JUDGMENT_ORG_ID` | Yes | Your Judgment organization ID |
| `JUDGEVAL_CC_PROJECT` | No | Project name (default: `claude-code`) |
| `JUDGEVAL_CC_DEBUG` | No | Set to `"true"` for verbose logging |
| `JUDGMENT_API_URL` | No | API URL (default: `https://api.judgmentlabs.ai`) |

## Updating the plugin

After making changes:

1. Bump version in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit and push
3. Users update with: `claude plugin marketplace update judgeval-claude-plugin`

## License

MIT
