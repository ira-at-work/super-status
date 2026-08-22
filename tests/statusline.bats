#!/usr/bin/env bats
# Tests for statusline.sh — unit tests source the script (its render flow is
# guarded behind a BASH_SOURCE check), end-to-end tests run it with mock stdin
# payloads under an isolated HOME/XDG_CACHE_HOME.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/statusline.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$HOME/.claude/super-status"
    unset SUPER_STATUS_DISABLE SUPER_STATUS_CONFIG ANTHROPIC_BASE_URL OPENROUTER_API_KEY COLUMNS
    # shellcheck disable=SC1090
    source "$SCRIPT"
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' <<< "$1"; }

run_statusline() { # $1 = payload
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$1" "$SCRIPT"
}

MINIMAL_PAYLOAD='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25}}'
SUBSCRIPTION_PAYLOAD='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'

# --- unit: date parsing -----------------------------------------------------

@test "parse_subscription_date accepts a real dd/MM/yyyy date and round-trips" {
    epoch=$(parse_subscription_date "14/07/2026")
    [ -n "$epoch" ]
    [ "$(format_date_epoch "$epoch")" = "14/07/2026" ]
}

@test "parse_subscription_date rejects the impossible date 31/02/2026" {
    [ -z "$(parse_subscription_date "31/02/2026")" ]
}

@test "parse_subscription_date rejects non-dd/MM/yyyy formats" {
    [ -z "$(parse_subscription_date "2026-07-14")" ]
    [ -z "$(parse_subscription_date "7/14/2026")" ]
    [ -z "$(parse_subscription_date "garbage")" ]
}

@test "add_months_epoch clamps 31/01 to the end of February" {
    epoch=$(add_months_epoch 31 01 2026 1)
    [ "$(format_date_epoch "$epoch")" = "28/02/2026" ]
}

@test "add_months_epoch clamps to 29/02 on a leap year" {
    epoch=$(add_months_epoch 31 01 2028 1)
    [ "$(format_date_epoch "$epoch")" = "29/02/2028" ]
}

@test "add_months_epoch keeps the same day across a normal month boundary" {
    epoch=$(add_months_epoch 14 07 2026 1)
    [ "$(format_date_epoch "$epoch")" = "14/08/2026" ]
}

@test "days_in_month handles leap-year rules (2024 yes, 2100 no, 2000 yes)" {
    [ "$(days_in_month 2 2024)" = "29" ]
    [ "$(days_in_month 2 2100)" = "28" ]
    [ "$(days_in_month 2 2000)" = "29" ]
}

@test "format_reset_marker clock mode shows HH:MM even when the reset is on a later day" {
    # 4h from now, deliberately crossing into tomorrow so day != today.
    tomorrow_epoch=$(( $(date +%s) + 4 * 3600 ))
    while [ "$(date -r "$tomorrow_epoch" +%Y%m%d 2>/dev/null || date -d "@$tomorrow_epoch" +%Y%m%d)" = "$(date +%Y%m%d)" ]; do
        tomorrow_epoch=$(( tomorrow_epoch + 3600 ))
    done
    marker=$(format_reset_marker "$tomorrow_epoch" clock)
    [[ "$marker" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]
}

@test "format_reset_marker default mode shows dd/MM for a later day" {
    next_week=$(( $(date +%s) + 7 * 86400 ))
    marker=$(format_reset_marker "$next_week")
    [[ "$marker" =~ ^[0-3][0-9]/[0-1][0-9]$ ]]
}

# --- unit: formatting -------------------------------------------------------

@test "fmt_tokens_k formats thousands with one decimal and passes small values through" {
    [ "$(fmt_tokens_k 15234)" = "15.2k" ]
    [ "$(fmt_tokens_k 480)" = "480" ]
    [ -z "$(fmt_tokens_k notanumber)" ]
}

@test "parse_iso_epoch reads a UTC ISO-8601 timestamp as UTC, not local time" {
    epoch=$(parse_iso_epoch "2026-07-17T10:00:00Z")
    [ -n "$epoch" ]
    formatted=$(TZ=UTC date -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || TZ=UTC date -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    [ "$formatted" = "2026-07-17T10:00:00Z" ]
}

@test "parse_iso_epoch returns nothing on unparseable input" {
    [ -z "$(parse_iso_epoch "not-a-date")" ]
}

@test "fmt_countdown_epoch clamps past epochs to 0m" {
    [ "$(fmt_countdown_epoch 1000000)" = "0m" ]
}

@test "make_bar renders proportional fill and clamps out-of-range percentages" {
    [ "$(make_bar 50 10)" = "▮▮▮▮▮▪▪▪▪▪" ]
    [ "$(make_bar 200 10)" = "▮▮▮▮▮▮▮▮▮▮" ]
    [ "$(make_bar -5 10)" = "▪▪▪▪▪▪▪▪▪▪" ]
}

@test "grade_for maps score bands to letters" {
    [ "$(grade_for 95)" = "A" ]
    [ "$(grade_for 60)" = "C" ]
    [ "$(grade_for 10)" = "F" ]
}

@test "path_tail returns the last N components" {
    [ "$(path_tail "/a/parent/child" 1)" = "child" ]
    [ "$(path_tail "/a/parent/child" 2)" = "parent/child" ]
    [ "$(path_tail "/a/parent/child" 9)" = "a/parent/child" ]
}

@test "resolve_color handles named, 256, and hex colors and rejects garbage" {
    [ "$(resolve_color red)" = $'\033[31m' ]
    [ "$(resolve_color 208)" = $'\033[38;5;208m' ]
    [ "$(resolve_color '#ff0000')" = $'\033[38;2;255;0;0m' ]
    run resolve_color "evil;m"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- e2e: basics ------------------------------------------------------------

@test "kill switch SUPER_STATUS_DISABLE=1 prints nothing and exits 0" {
    run bash -c "printf '%s' \"\$1\" | SUPER_STATUS_DISABLE=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "minimal payload renders the model and repo basename" {
    run_statusline "$MINIMAL_PAYLOAD"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" == *"child"* ]]
    [[ "$plain" == *"Ctx "*" 25%"* ]]
}

@test "garbage stdin never crashes" {
    run_statusline "this is not json"
    [ "$status" -eq 0 ]
}

@test "no rate_limits means no sessions bars and no subscription warning" {
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Reset"* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode without a declared start date shows the reminder" {
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63% Reset "* ]]
    # both resets carry an absolute "when" marker in parens; these fixtures land
    # on a later day, so the marker is a dd/MM date rather than an HH:MM time
    [[ "$plain" == *"5h "*" 63% Reset "*"("??"/"??")"* ]]
    [[ "$plain" == *" 44% Reset "*"("??"/"??")"* ]]
    [[ "$plain" == *"SUBSCRIPTION START DATE IS MISSING"* ]]
}

@test "subscription mode with a valid start date shows the cycle bar" {
    echo '"subscription_start_date": "14/07/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Sub "* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode with an invalid start date shows the INVALID reminder" {
    echo '"subscription_start_date": "31/02/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUBSCRIPTION START DATE IS INVALID"* ]]
}

# --- e2e: rate-limit persistence across /clear ------------------------------

@test "cached rate limits are restored when a fresh session omits them" {
    # First render carries rate_limits and seeds the cache.
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"5h "*" 63% Reset "* ]]
    # A fresh session (post-/clear) has no rate_limits; the bars come from cache.
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63% Reset "* ]]
    [[ "$plain" == *" 44% Reset "* ]]
}

@test "a cached window whose reset has passed is not resurrected" {
    mkdir -p "$XDG_CACHE_HOME/super-status"
    past=$(( $(date +%s) - 100 ))
    future=$(( $(date +%s) + 400000 ))
    printf '63\t%s\t44\t%s\n' "$past" "$future" \
        > "$XDG_CACHE_HOME/super-status/rate-limits.tsv"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"63%"* ]]
}

# --- e2e: config ------------------------------------------------------------

@test "malformed config.json warns once and still renders with defaults" {
    echo '{broken json' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUPER-STATUS CONFIG IS INVALID JSON"* ]]
    [[ "$plain" == *"◆ Opus"* ]]
}

@test "display toggle hides a single field" {
    echo '{"display":{"model":false}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Opus"* ]]
    [[ "$plain" == *"child"* ]]
}

@test "path_levels widens the repo location" {
    echo '{"path_levels":2}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"parent/child"* ]]
}

@test "max_width truncates lines with a trailing ellipsis, ANSI excluded" {
    echo '{"max_width":20}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    while IFS= read -r line; do
        plain=$(strip_ansi "$line")
        [ "${#plain}" -le 20 ]
    done <<< "$output"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"…"* ]]
}

@test "custom bar glyphs and width render intact (no mid-glyph byte splits)" {
    echo '{"bar_filled":"█","bar_empty":"░","bar_width":10}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"██░░░░░░░░"* ]]
}

@test "context_value remaining shows tokens left instead of used/max" {
    echo '{"context_value":"remaining"}' > "$HOME/.claude/super-status/config.json"
    run_statusline '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":25,"context_window_size":200000,"remaining_percentage":50}}'
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"100k left"* ]]
    [[ "$plain" != *"k/200k"* ]]
}

@test "custom lines layout reorders and merges segments" {
    echo '{"lines":[["context","model"],["repo"]]}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    first_line=$(head -n1 <<< "$plain")
    [[ "$first_line" == "Ctx "*"| ◆ Opus" ]]
}

@test "minimal preset collapses to the compact layout" {
    echo '{"preset":"minimal"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"child"* ]]
    [[ "$plain" == *"◆ Opus"* ]]
    [ "$(wc -l <<< "$plain" | tr -d '[:space:]')" -le 3 ]
}

# --- e2e: transcript-derived lines ------------------------------------------

write_transcript() {
    cat > "$BATS_TEST_TMPDIR/transcript.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":500},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/auth.ts"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x/b.ts"}},{"type":"tool_use","id":"t3","name":"Grep","input":{"pattern":"foo"}}]}}
{"timestamp":"2026-07-17T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"},{"type":"tool_result","tool_use_id":"t2"},{"type":"tool_result","tool_use_id":"t3"}]}}
{"timestamp":"2026-07-17T10:01:00.000Z","message":{"role":"assistant","usage":{"input_tokens":150,"output_tokens":700},"content":[{"type":"tool_use","id":"t4","name":"TodoWrite","input":{"todos":[{"content":"Fix auth bug","activeForm":"Fixing auth bug","status":"in_progress"},{"content":"Add tests","status":"pending"},{"content":"Read code","status":"completed"}]}},{"type":"tool_use","id":"t5","name":"Task","input":{"description":"Finding auth code","subagent_type":"Explore","model":"haiku"}},{"type":"tool_use","id":"t6","name":"Edit","input":{"file_path":"/x/auth.ts"}}]}}
{"timestamp":"2026-07-17T10:01:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4"}]}}
EOF
}

transcript_payload() {
    printf '{"model":{"display_name":"Opus"},"session_id":"bats-%s","transcript_path":"%s","context_window":{"used_percentage":25},"cost":{"total_lines_added":45,"total_lines_removed":12}}' \
        "$BATS_TEST_NUMBER" "$BATS_TEST_TMPDIR/transcript.jsonl"
}

@test "tool calls clause shows the total and only the non-zero buckets" {
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Calls 6 (Read 3, Code 1, Other 2)"* ]]
    [[ "$plain" == *"Tok 3.5k/1.2k"* ]]
}

@test "activity, agents, and todo lines are off by default" {
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Activity:"* ]]
    [[ "$plain" != *"Agents:"* ]]
    [[ "$plain" != *"Todo:"* ]]
}

@test "preset full enables activity (in-flight marker + grouped counts), agents, and todos" {
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Activity: ◐ Edit: auth.ts | ✓ Grep: foo | ✓ Read ×2"* ]]
    [[ "$plain" == *"Agents: ◐ Explore [haiku]: Finding auth code ("* ]]
    [[ "$plain" == *"Todo: ▸ Fixing auth bug (1/3)"* ]]
}

# --- e2e: git enrichment ----------------------------------------------------

@test "git dirty marker and file stats appear on a dirty repo" {
    repo="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo x > "$repo/untracked.txt"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *":main* ?1"* ]]
}

# --- e2e: orca/master live run state -----------------------------------------

@test "orchestrator line is off by default even with an active orca status.md" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-billing | task-billing | feature/billing | wt-billing | IN PROGRESS | 2026-07-17T10:00:00Z |'
    } > "$repo/.claude/status.md"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Orca:"* ]]
}

@test "orchestrator line buckets orca status.md rows by status" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-auth | task-auth | feature/auth | wt-auth | REBASED & MERGED | 2026-07-17T09:00:00Z |'
        echo '| task-billing | task-billing | feature/billing | wt-billing | IN PROGRESS | 2026-07-17T10:00:00Z |'
        echo '| task-ui | task-ui | feature/ui | wt-ui | CONFLICT — NEEDS YOU | 2026-07-17T09:30:00Z |'
    } > "$repo/.claude/status.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Orca: 1/3 merged | 1 in progress | 1 conflict ⚠"* ]]
}

@test "orchestrator line hides once every orca row is REBASED & MERGED" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-auth | task-auth | feature/auth | wt-auth | REBASED & MERGED | 2026-07-17T09:00:00Z |'
    } > "$repo/.claude/status.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Orca:"* ]]
}

@test "orchestrator line reports the open master stage with elapsed time" {
    repo="$BATS_TEST_TMPDIR/master-repo"
    mkdir -p "$repo/docs/status"
    git -C "$repo" init -q -b main
    spawned=$(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
           || date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ")
    {
        echo '# Master Stage Plan'
        echo '## Stages'
        echo '- Stage 1: COMMITTED — Scaffold data model'
        echo "- Stage 2: IN PROGRESS — Core calculation engine [window=win-2 spawned=${spawned}]"
        echo '- Stage 3: PLANNED — API endpoints'
    } > "$repo/docs/status/stage-plan.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Master: Stage 2/3 IN PROGRESS — Core calculation engine (5m"*")"* ]]
    [[ "$plain" == *"1 committed"* ]]
}

@test "orchestrator line hides once every master stage is COMMITTED" {
    repo="$BATS_TEST_TMPDIR/master-repo"
    mkdir -p "$repo/docs/status"
    git -C "$repo" init -q -b main
    {
        echo '## Stages'
        echo '- Stage 1: COMMITTED — Scaffold data model'
    } > "$repo/docs/status/stage-plan.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Master:"* ]]
}

# --- e2e: provider badge ----------------------------------------------------

@test "OpenRouter base URL adds a provider badge to the model segment" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [OpenRouter]"* ]]
}

@test "first-party Anthropic base URL shows no badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://api.anthropic.com bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"◆ Opus ["* ]]
}

@test "z.ai base URL adds a z.ai badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [z.ai]"* ]]
}

@test "an unknown proxy base URL shows its host as the badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://proxy.internal:8080/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [proxy.internal:8080]"* ]]
}

@test "provider display toggle off hides the badge" {
    echo '{"display":{"provider":false}}' > "$HOME/.claude/super-status/config.json"
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"[OpenRouter]"* ]]
}

# --- e2e: Bedrock / Vertex badges (R5) --------------------------------------

@test "CLAUDE_CODE_USE_BEDROCK=1 adds a Bedrock badge" {
    run bash -c "printf '%s' \"\$1\" | CLAUDE_CODE_USE_BEDROCK=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [Bedrock]"* ]]
}

@test "CLAUDE_CODE_USE_VERTEX=1 adds a Vertex badge" {
    run bash -c "printf '%s' \"\$1\" | CLAUDE_CODE_USE_VERTEX=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [Vertex]"* ]]
}

# --- unit: humanize_model_id (R5) -------------------------------------------

@test "humanize_model_id turns raw ids into readable names" {
    [ "$(humanize_model_id 'claude-sonnet-4-6-20250101')" = "Claude Sonnet 4.6" ]
    [ "$(humanize_model_id 'claude-3-5-haiku-20241022')" = "Claude 3.5 Haiku" ]
    [ "$(humanize_model_id 'claude-opus-4-1')" = "Claude Opus 4.1" ]
}

@test "humanize_model_id strips a Bedrock provider prefix" {
    [ "$(humanize_model_id 'us.anthropic.claude-opus-4-20250514')" = "Claude Opus 4" ]
}

@test "humanize_model_id returns a non-Claude id unchanged" {
    [ "$(humanize_model_id 'gpt-4o')" = "gpt-4o" ]
}

# --- e2e: model_source recovers the real model from the transcript (R5) -----

@test "model_source transcript overrides the stdin display_name" {
    cat > "$BATS_TEST_TMPDIR/tr.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6-20250101","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
EOF
    echo '{"model_source":"transcript"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"session_id":"ms1","transcript_path":"%s","context_window":{"used_percentage":25}}' "$BATS_TEST_TMPDIR/tr.jsonl")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Claude Sonnet 4.6"* ]]
    [[ "$plain" != *"◆ Opus"* ]]
}

@test "model_source auto only overrides behind a proxy" {
    cat > "$BATS_TEST_TMPDIR/tr.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6-20250101","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
EOF
    echo '{"model_source":"auto"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"session_id":"ms2","transcript_path":"%s","context_window":{"used_percentage":25}}' "$BATS_TEST_TMPDIR/tr.jsonl")
    # No proxy: keeps the stdin name.
    run_statusline "$payload"
    [[ "$(strip_ansi "$output")" == *"◆ Opus"* ]]
    # Behind a proxy: recovers the real name.
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://proxy.internal/v1 bash \"\$2\"" _ "$payload" "$SCRIPT"
    [[ "$(strip_ansi "$output")" == *"◆ Claude Sonnet 4.6 [proxy.internal]"* ]]
}

# --- e2e: auto_compact_window re-bases the context percentage (R4) -----------

@test "auto_compact_window re-bases Ctx % onto the configured window" {
    echo '{"auto_compact_window":160000}' > "$HOME/.claude/super-status/config.json"
    # 80k used tokens: 40% of the 200k window, but 50% of a 160k compact window.
    payload='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":40,"context_window_size":200000,"current_usage":{"input_tokens":80000}}}'
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Ctx "*" 50%"* ]]
    [[ "$plain" == *"80k/160k"* ]]
}

@test "without auto_compact_window Ctx % stays on the full window" {
    payload='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":40,"context_window_size":200000,"current_usage":{"input_tokens":80000}}}'
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Ctx "*" 40%"* ]]
}

# --- e2e: external usage snapshot (R3) --------------------------------------

@test "external usage snapshot fills the 5h/Nd bars when stdin omits them" {
    future_five=$(( $(date +%s) + 3000 ))
    future_seven=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future_five" "$future_seven" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 37%"* ]]
    [[ "$plain" == *" 52%"* ]]
}

@test "a stale external usage snapshot is ignored" {
    future_five=$(( $(date +%s) + 3000 ))
    future_seven=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future_five" "$future_seven" > "$snap"
    touch -t 202001010000 "$snap"
    printf '{"external_usage_path":"%s","external_usage_max_age":60}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"37%"* ]]
}

@test "stdin rate_limits win over the external snapshot" {
    future=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future" "$future" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63%"* ]]
    [[ "$plain" != *"37%"* ]]
}

@test "external snapshot model_scoped windows render per-model bars" {
    future=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s}},"model_scoped":{"Fable":{"used_percentage":66,"resets_at":%s}}}' \
        "$future" "$future" "$future" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Fable "*" 66%"* ]]
}
