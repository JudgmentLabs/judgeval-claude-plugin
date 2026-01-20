# Judgeval Claude Code Plugin - Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Claude Code CLI                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │   Session   │  │    User     │  │    Tool     │  │      Response       │ │
│  │   Start     │  │   Prompt    │  │    Use      │  │      Complete       │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘ │
└─────────┼────────────────┼────────────────┼────────────────────┼────────────┘
          │                │                │                    │
          ▼                ▼                ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Hook System                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────┐ ┌─────────┐ │
│  │ session_    │  │ user_prompt │  │ post_tool_  │  │  stop_  │ │ session │ │
│  │ start.sh    │  │ _submit.sh  │  │ use.sh      │  │ hook.sh │ │ _end.sh │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └────┬────┘ └────┬────┘ │
└─────────┼────────────────┼────────────────┼──────────────┼──────────┼──────┘
          │                │                │              │          │
          └────────────────┴────────────────┴──────────────┴──────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              common.sh                                       │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐ │
│  │ State Mgmt    │  │ OTLP Builder  │  │ API Client    │  │ Utilities     │ │
│  │ (JSON files)  │  │ (Spans)       │  │ (HTTP/JSON)   │  │ (UUID, time)  │ │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘  └───────────────┘ │
└──────────┼──────────────────┼──────────────────┼────────────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────────────┐
│ ~/.claude/state/ │  │ OTLP Payload     │  │ Judgeval API                     │
│ judgeval_*.json  │  │ (OpenTelemetry)  │  │ POST /otel/v1/traces             │
└──────────────────┘  └──────────────────┘  └──────────────────────────────────┘
```

## Hook Lifecycle

```
┌────────────────────────────────────────────────────────────────────────────┐
│                         Claude Code Session                                 │
└────────────────────────────────────────────────────────────────────────────┘
     │
     │ 1. Session Start
     ▼
┌─────────────────────────────────────────┐
│ session_start.sh                        │
│ • Create root trace span (update_id=0)  │
│ • Initialize session state              │
│ • Resolve/create project                │
└─────────────────────────────────────────┘
     │
     │ 2. User submits prompt
     ▼
┌─────────────────────────────────────────┐
│ user_prompt_submit.sh                   │
│ • Increment turn count                  │
│ • Create Turn span (update_id=0)        │
│ • Store turn start time                 │
└─────────────────────────────────────────┘
     │
     │ 3. Claude uses tools (0-N times)
     ▼
┌─────────────────────────────────────────┐
│ post_tool_use.sh                        │
│ • Increment tool count                  │
│ • (Tool spans created in session_end)   │
└─────────────────────────────────────────┘
     │
     │ 4. Claude finishes response
     ▼
┌─────────────────────────────────────────┐
│ stop_hook.sh                            │
│ • Mark turn as stopped                  │
│ • Signal ready for finalization         │
└─────────────────────────────────────────┘
     │
     │ 5. Session/Turn ends
     ▼
┌─────────────────────────────────────────┐
│ session_end.sh                          │
│ • Parse transcript for accurate times   │
│ • Create LLM spans with duration        │
│ • Create Tool spans with duration       │
│ • Finalize Turn span (update_id=20)     │
│ • Finalize Session span (update_id=20)  │
└─────────────────────────────────────────┘
```

## Span Hierarchy

```
Session Span (task)                    ← Root span, created at session start
│   trace_id: abc123...
│   span_id: root001
│   judgment.span_kind: "task"
│   judgment.input: "Session: my-project"
│
├── Turn 1 Span (task)                 ← Created per user prompt
│   │   parent_span_id: root001
│   │   span_id: turn001
│   │   judgment.span_kind: "task"
│   │   judgment.input: "Add error handling"
│   │
│   ├── LLM Span (llm)                 ← Claude's thinking/response
│   │       parent_span_id: turn001
│   │       span_id: llm001
│   │       judgment.span_kind: "llm"
│   │       judgment.llm.model: "claude-opus-4-5"
│   │       judgment.usage.input_tokens: 1240
│   │       judgment.usage.output_tokens: 890
│   │
│   ├── Tool Span (tool)               ← File read
│   │       parent_span_id: turn001
│   │       span_id: tool001
│   │       judgment.span_kind: "tool"
│   │       name: "Read: src/app.ts"
│   │
│   ├── Tool Span (tool)               ← File edit
│   │       parent_span_id: turn001
│   │       span_id: tool002
│   │       judgment.span_kind: "tool"
│   │       name: "Edit: src/app.ts"
│   │
│   └── LLM Span (llm)                 ← Claude continues
│           span_id: llm002
│           judgment.usage.output_tokens: 450
│
├── Turn 2 Span (task)
│   └── ...
│
└── Turn N Span (task)
    └── ...
```

## Data Flow

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Claude Code     │     │  Hook Scripts    │     │  Judgeval API    │
│  CLI             │     │  (bash)          │     │                  │
└────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘
         │                        │                        │
         │ 1. Trigger hook        │                        │
         │ (JSON via stdin)       │                        │
         │───────────────────────>│                        │
         │                        │                        │
         │                        │ 2. Read/update state   │
         │                        │ (atomic file ops)      │
         │                        │◄──────────────────────►│
         │                        │ ~/.claude/state/       │
         │                        │                        │
         │                        │ 3. Build OTLP span     │
         │                        │ (JSON payload)         │
         │                        │                        │
         │                        │ 4. POST /otel/v1/traces│
         │                        │───────────────────────>│
         │                        │                        │
         │                        │     HTTP 200 OK        │
         │                        │<───────────────────────│
         │                        │                        │
         │ Hook exits (0)         │                        │
         │<───────────────────────│                        │
         │                        │                        │
```

## State Management

```
~/.claude/state/judgeval_state.json
┌─────────────────────────────────────────────────────────────────┐
│ {                                                               │
│   "project_id": "a2586f41-...",     // Cached project ID        │
│   "sessions": {                                                 │
│     "session-uuid-1": {                                         │
│       "trace_id": "abc123...",      // 32-char hex              │
│       "root_span_id": "def456...",  // 16-char hex              │
│       "project_id": "a2586f41-...", // Project UUID             │
│       "turn_count": "3",            // Current turn number      │
│       "started": "1234567890...",   // Start time (nanos)       │
│       "current_turn_span_id": "...",// Active turn span         │
│       "current_turn_start": "...",  // Turn start (nanos)       │
│       "current_turn_tool_count": "5",                           │
│       "turn_stopped": "true"        // Ready to finalize        │
│     }                                                           │
│   }                                                             │
│ }                                                               │
└─────────────────────────────────────────────────────────────────┘
```

## Concurrency & Reliability

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Multi-Instance Safety                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Instance A              Instance B              Instance C                 │
│  (Session 1)             (Session 2)             (Session 3)                │
│       │                       │                       │                     │
│       ▼                       ▼                       ▼                     │
│  ┌─────────┐             ┌─────────┐             ┌─────────┐               │
│  │ acquire │             │ acquire │             │ acquire │               │
│  │  lock   │             │  lock   │             │  lock   │               │
│  └────┬────┘             └────┬────┘             └────┬────┘               │
│       │                       │                       │                     │
│       ▼                       │ (wait)                │ (wait)              │
│  ┌─────────────────────┐      │                       │                     │
│  │ ~/.claude/state/    │      │                       │                     │
│  │ judgeval.lock.d/    │◄─────┘                       │                     │
│  │ (mkdir atomic)      │◄─────────────────────────────┘                     │
│  └─────────────────────┘                                                    │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────┐                                                    │
│  │ Read/modify state   │  Each session has its own key in sessions{}       │
│  │ (session-isolated)  │  No cross-session interference                    │
│  └─────────────────────┘                                                    │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────┐                                                    │
│  │ Atomic write        │  Write to temp file, mv to target                 │
│  │ (tmp + mv)          │  Prevents partial writes                          │
│  └─────────────────────┘                                                    │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────┐                                                    │
│  │ Release lock        │                                                    │
│  │ (rmdir)             │                                                    │
│  └─────────────────────┘                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## OTLP Payload Structure

```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": "claude-code" } },
        { "key": "telemetry.sdk.name", "value": { "stringValue": "judgeval" } },
        { "key": "telemetry.sdk.version", "value": { "stringValue": "1.0.0" } }
      ]
    },
    "scopeSpans": [{
      "scope": { "name": "judgeval" },
      "spans": [{
        "traceId": "abc123...",
        "spanId": "def456...",
        "parentSpanId": "parent...",
        "name": "Turn 1",
        "kind": 1,
        "startTimeUnixNano": "1234567890000000000",
        "endTimeUnixNano": "1234567893000000000",
        "attributes": [
          { "key": "judgment.span_kind", "value": { "stringValue": "task" } },
          { "key": "judgment.input", "value": { "stringValue": "..." } },
          { "key": "judgment.output", "value": { "stringValue": "..." } },
          { "key": "judgment.update_id", "value": { "intValue": "20" } }
        ],
        "status": { "code": 1 }
      }]
    }]
  }]
}
```

## File Structure

```
judgeval-claude-plugin/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Marketplace index
│
├── .github/workflows/
│   ├── ci.yml                   # Lint + test on PR
│   └── release.yml              # Auto-release on tag
│
├── skills/trace-claude-code/
│   ├── SKILL.md                 # Skill documentation
│   ├── setup.sh                 # Interactive setup
│   └── hooks/
│       ├── common.sh            # Shared utilities
│       │   ├── State management (load/save/lock)
│       │   ├── OTLP span building
│       │   ├── API client (insert_span)
│       │   └── Utilities (UUID, time)
│       │
│       ├── session_start.sh     # → Creates root span
│       ├── user_prompt_submit.sh # → Creates turn span
│       ├── post_tool_use.sh     # → Tracks tool count
│       ├── stop_hook.sh         # → Marks turn done
│       └── session_end.sh       # → Finalizes everything
│
├── README.md
├── LICENSE
└── CHANGELOG.md
```
