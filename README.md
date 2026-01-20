# Judgeval Claude Code Plugin

Automatic tracing for Claude Code conversations to [Judgeval](https://judgmentlabs.ai).

## Quick Start

**Step 1: Install the plugin (once)**
```bash
claude plugin marketplace add JudgmentLabs/judgeval-claude-plugin
claude plugin install trace-claude-code@judgeval-claude-plugin
```

**Step 2: Setup tracing in your project**
```bash
cd /path/to/your/project
bash <(curl -s https://raw.githubusercontent.com/JudgmentLabs/judgeval-claude-plugin/main/install.sh)
```

The setup script will prompt for:
- **JUDGMENT_API_KEY** - Get from [Judgeval Settings](https://app.judgmentlabs.ai/settings/api-keys)
- **JUDGMENT_ORG_ID** - Get from [Organization Settings](https://app.judgmentlabs.ai/settings/organization)
- **Project name** - Where traces appear (default: `claude-code`)

## What You Get

```
Claude Code Session (root trace)
├── Turn 1: "Add error handling"
│   ├── LLM: claude-opus-4-5 (3.2s, 1,240 tokens)
│   ├── Read: src/app.ts
│   ├── Edit: src/app.ts
│   └── LLM: claude-opus-4-5 (1.8s, 890 tokens)
├── Turn 2: "Now run the tests"
│   ├── LLM: claude-opus-4-5
│   ├── Terminal: npm test
│   └── LLM: claude-opus-4-5
└── Turn 3: "Commit this"
    └── ...
```

**Captured data:**
- Session start/end times
- Each conversation turn
- All LLM calls with model, tokens, and duration
- Tool invocations (file reads, edits, terminal, MCP)
- Cache metrics (creation + read tokens)

## View Traces

After a Claude Code session, view traces at:
```
https://app.judgmentlabs.ai/projects/claude-code/traces
```

## Troubleshooting

**Check hook logs:**
```bash
tail -f ~/.claude/state/judgeval_hook.log
```

**Enable debug mode:**
Re-run setup and answer "y" to debug logging, or edit `.claude/settings.local.json`:
```json
{
  "env": {
    "JUDGEVAL_CC_DEBUG": "true"
  }
}
```

**Reset state:**
```bash
rm ~/.claude/state/judgeval_state.json
```

**Verify hooks are configured:**
```bash
cat .claude/settings.local.json | jq '.hooks | keys'
```

## How It Works

The plugin uses Claude Code's hook system:

| Hook | What it does |
|------|--------------|
| SessionStart | Creates root trace span |
| UserPromptSubmit | Creates Turn span for each message |
| PostToolUse | Tracks tool call count |
| Stop | Marks turn for finalization |
| SessionEnd | Creates LLM/tool spans, finalizes trace |

Hooks are configured per-project in `.claude/settings.local.json`.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TRACE_TO_JUDGEVAL` | Yes | Set to `true` to enable |
| `JUDGMENT_API_KEY` | Yes | API key |
| `JUDGMENT_ORG_ID` | Yes | Organization ID |
| `JUDGMENT_API_URL` | No | Default: `https://api.judgmentlabs.ai` |
| `JUDGEVAL_CC_PROJECT` | No | Default: `claude-code` |
| `JUDGEVAL_CC_DEBUG` | No | Set to `true` for verbose logs |

## Updating

```bash
claude plugin marketplace update judgeval-claude-plugin
claude plugin update trace-claude-code@judgeval-claude-plugin
```

Then re-run setup in your project directories.

## License

MIT
