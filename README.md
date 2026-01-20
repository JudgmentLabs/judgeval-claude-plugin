# Judgeval Claude Code Plugin

Claude Code plugin for Judgeval - automatic tracing and observability.

## Install

```bash
claude plugin marketplace add JudgmentLabs/judgeval-claude-plugin
claude plugin install trace-claude-code@judgeval-claude-plugin
```

See [trace-claude-code/SKILL.md](skills/trace-claude-code/SKILL.md) for setup instructions.

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

After a Claude Code session:
```
https://app.judgmentlabs.ai/projects/claude-code/traces
```

## Project Structure

```
judgeval-claude-plugin/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── skills/
│   └── trace-claude-code/
│       ├── SKILL.md
│       ├── setup.sh
│       └── hooks/
└── README.md
```

## Development

Test locally without marketplace:
```bash
claude --plugin-dir /path/to/judgeval-claude-plugin
```

## License

MIT
