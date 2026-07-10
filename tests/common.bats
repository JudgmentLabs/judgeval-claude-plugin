#!/usr/bin/env bats
#
# Unit tests for the pure/business logic in
# skills/trace-claude-code/hooks/common.sh.

setup() {
  load 'test_helper'
  setup_common_env
}

# --- detect_provider ---------------------------------------------------------

@test "detect_provider: bare claude model -> anthropic" {
  run detect_provider "claude-opus-4-5"
  [ "$status" -eq 0 ]
  [ "$output" = "anthropic" ]
}

@test "detect_provider: anthropic/ prefix -> anthropic" {
  run detect_provider "anthropic/claude-3"
  [ "$output" = "anthropic" ]
}

@test "detect_provider: gpt model -> openai" {
  run detect_provider "gpt-4o"
  [ "$output" = "openai" ]
}

@test "detect_provider: gemini model -> google" {
  run detect_provider "gemini-2.0-flash"
  [ "$output" = "google" ]
}

@test "detect_provider: llama model -> meta" {
  run detect_provider "llama-3.1-70b"
  [ "$output" = "meta" ]
}

@test "detect_provider: unknown vendor/ prefix -> openrouter" {
  run detect_provider "somevendor/some-model"
  [ "$output" = "openrouter" ]
}

@test "detect_provider: unrecognized bare model -> anthropic default" {
  run detect_provider "mystery-model"
  [ "$output" = "anthropic" ]
}

# --- id generation -----------------------------------------------------------

@test "generate_trace_id: 32 lowercase hex chars" {
  run generate_trace_id
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
  [[ "$output" =~ ^[0-9a-f]{32}$ ]]
}

@test "generate_span_id: 16 lowercase hex chars" {
  run generate_span_id
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 16 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "generate_trace_id: consecutive ids differ" {
  a="$(generate_trace_id)"
  b="$(generate_trace_id)"
  [ "$a" != "$b" ]
}

# --- build_otlp_attributes (type coercion) ----------------------------------

@test "build_otlp_attributes: coerces each JSON type to the right OTLP value" {
  run build_otlp_attributes '{"s":"hello","i":42,"f":1.5,"b":true}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.key=="s") | .value.stringValue == "hello"'
  echo "$output" | jq -e '.[] | select(.key=="i") | .value.intValue == "42"'
  echo "$output" | jq -e '.[] | select(.key=="f") | .value.doubleValue == 1.5'
  echo "$output" | jq -e '.[] | select(.key=="b") | .value.boolValue == true'
}

# --- build_otlp_span ---------------------------------------------------------
# Positional args: trace_id span_id parent_span_id name <unused> start end attrs update_id

@test "build_otlp_span: well-formed span, empty parent omitted, update_id injected" {
  run build_otlp_span "trace123" "span123" "" "my-span" "IGNORED" "100" "200" "[]" "7"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.traceId == "trace123"'
  echo "$output" | jq -e '.spanId == "span123"'
  echo "$output" | jq -e '.name == "my-span"'
  echo "$output" | jq -e '.kind == 1'
  echo "$output" | jq -e '.startTimeUnixNano == "100"'
  echo "$output" | jq -e '.endTimeUnixNano == "200"'
  # empty parentSpanId must be dropped, not emitted as null/""
  echo "$output" | jq -e 'has("parentSpanId") | not'
  echo "$output" | jq -e '.attributes[] | select(.key=="judgment.update_id") | .value.intValue == "7"'
}

@test "build_otlp_span: non-empty parent is preserved" {
  run build_otlp_span "t" "s" "parent1" "n" "x" "1" "2" "[]" "0"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.parentSpanId == "parent1"'
}

# --- state persistence guards ------------------------------------------------

@test "save_state: refuses empty input" {
  run save_state ""
  [ "$status" -ne 0 ]
}

@test "save_state: refuses non-object JSON" {
  run save_state '"just a string"'
  [ "$status" -ne 0 ]
}

@test "save_state + load_state: round-trips a valid object" {
  save_state '{"hello":"world"}'
  run load_state
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hello == "world"'
}

@test "load_state: corrupt state file falls back to empty object" {
  printf 'not valid json {' > "$STATE_FILE"
  run load_state
  [ "$output" = "{}" ]
}

@test "set_state_value / get_state_value: round-trip" {
  set_state_value "project_id" "proj-abc"
  run get_state_value "project_id"
  [ "$output" = "proj-abc" ]
}

@test "get_state_value: missing key yields empty string" {
  save_state '{}'
  run get_state_value "nope"
  [ "$output" = "" ]
}

@test "session state: set then get round-trips per-session values" {
  set_session_state "sess-1" "trace_id" "tid-xyz"
  run get_session_state "sess-1" "trace_id"
  [ "$output" = "tid-xyz" ]
}

@test "session state: values with spaces survive the round-trip" {
  set_session_state "sess-2" "prompt" "hello there world"
  run get_session_state "sess-2" "prompt"
  [ "$output" = "hello there world" ]
}

# --- small utilities ---------------------------------------------------------

@test "count_file_lines: counts lines in a file" {
  printf 'a\nb\nc\n' > "$BATS_TEST_TMPDIR/f.txt"
  run count_file_lines "$BATS_TEST_TMPDIR/f.txt"
  [ "$output" -eq 3 ]
}

@test "count_file_lines: missing file -> 0" {
  run count_file_lines "$BATS_TEST_TMPDIR/does-not-exist.txt"
  [ "$output" -eq 0 ]
}

@test "get_time_nanos: positive integer" {
  run get_time_nanos
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "iso_to_nanos: converts an ISO-8601 timestamp to positive nanos" {
  run iso_to_nanos "2026-01-01T00:00:00Z"
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}
