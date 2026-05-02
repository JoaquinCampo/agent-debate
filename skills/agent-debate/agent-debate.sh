#!/usr/bin/env bash
set -euo pipefail

# agent-debate.sh — peer back-and-forth between Claude (max effort) and Codex (high reasoning).
#
# Modes:
#   agent-debate.sh "<topic>" [rounds]
#       Start a fresh debate. Writes transcript to $AGENT_DEBATE_DIR (default ~/agent-debates).
#       On completion: prints synthesis to stdout, exits 0.
#       If an agent emits [ASK_USER: ...]: prints a structured NEEDS_INPUT block to stdout
#       and exits 42 so the orchestrating skill can collect the answer from the user.
#
#   agent-debate.sh --resume <transcript_path>
#       Continue a previously paused debate. Reads the user's answer from stdin and
#       appends it to the transcript, then continues from where the script paused.
#
# Exit codes:
#   0   debate finished, synthesis on stdout
#   42  paused for user input (see NEEDS_INPUT block on stdout)
#   1+  error

EXIT_NEED_INPUT=42

# Preflight: required CLIs must be installed and authenticated.
preflight() {
  command -v claude >/dev/null 2>&1 || { echo "agent-debate: 'claude' CLI not found in PATH" >&2; exit 2; }
  command -v codex  >/dev/null 2>&1 || { echo "agent-debate: 'codex' CLI not found in PATH" >&2; exit 2; }
  # Quick auth check on codex (claude has its own login flow that prompts on first use).
  if ! codex --help >/dev/null 2>&1; then
    echo "agent-debate: 'codex' CLI is broken or not configured. Run 'codex login' first." >&2
    exit 2
  fi
}
preflight

SEED='You are in a peer technical discussion with another highly capable AI agent. Goal: collaboratively reach the best possible answer or design. Disagree freely, surface tradeoffs, push back on weak reasoning, ask sharp questions of each other. Be concise but substantive, no filler, no recap of what the other said unless quoting to disagree.

The user is busy and trusts you to think. They are NOT a research assistant. Your job is to do the heavy lifting yourselves and only escalate to them when truly necessary.

Two special tokens are available:

- [ASK_USER: <one specific question>] — a last resort, not a first move. Before emitting this, you MUST have done all of the following:
    1. Explicitly stated the assumptions you would make in the absence of the answer, AND analyzed the problem under those assumptions.
    2. Considered: would the recommendation actually change based on the answer? If you would give the same advice either way, do not ask. Just state the assumption and proceed.
    3. Engaged with your peer at least once on the substance. Do not ask the user before you have heard from your peer (your peer may already address the gap, or the question may dissolve under their reasoning).
    4. Confirmed the answer is something only the user can provide (a private constraint, a preference, a fact about their situation). Do NOT ask things you can research, infer from common patterns, or work out together.
  Prefer the form "we are assuming X because Y; proceeding" over "what is X?". Only escalate when proceeding under any reasonable assumption would lead to materially different recommendations and the user would be misled by a default. Use [ASK_USER: ...] on its own line, sparingly. One genuinely-blocking question is far better than three speculative ones.

- [CONVERGED] — emit on the final line of your turn ONLY after you have read at least one substantive response from your peer AND you genuinely have nothing more to add. Do not converge on your first turn. Do not converge just to be polite.'

#─────────────────────────────────────────────────────────────────────────────
# Mode dispatch: fresh start vs resume
#─────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--resume" ]; then
  LOG="${2:?usage: agent-debate.sh --resume <transcript_path>}"
  STATE="${LOG}.state"
  [ -f "$LOG" ] || { echo "transcript not found: $LOG" >&2; exit 1; }
  [ -f "$STATE" ] || { echo "state file not found: $STATE (debate may already be finished)" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE"
  ANSWER=$(cat)
  {
    echo
    echo "## User input"
    echo
    printf '%s\n' "$ANSWER"
  } >> "$LOG"
else
  TOPIC="${1:?usage: agent-debate.sh \"<topic>\" [rounds]   |   --resume <transcript_path>}"
  MAX_ROUNDS="${2:-100}"
  TS=$(date +%Y%m%d-%H%M%S)
  SLUG=$(printf '%s' "$TOPIC" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-50)
  DIR="${AGENT_DEBATE_DIR:-$HOME/agent-debates}"
  mkdir -p "$DIR"
  LOG="$DIR/${TS}-${SLUG}.md"
  STATE="${LOG}.state"
  ROUND=1
  CLAUDE_DONE=0
  CODEX_DONE=0
  NEXT=claude
  {
    echo "# Agent debate: $TOPIC"
    echo
    echo "- Started: $(date)"
    echo "- Max rounds: $MAX_ROUNDS"
    echo
    echo "## Topic"
    echo
    echo "$TOPIC"
    echo
  } > "$LOG"
fi

#─────────────────────────────────────────────────────────────────────────────
# Prompt + agent invocations
#─────────────────────────────────────────────────────────────────────────────
build_prompt() {
  local who="$1"
  cat <<EOF
$SEED

You are "$who". Below is the full transcript so far. Add ONLY your next turn. Do not restate the topic, do not repeat prior content. Sign off with your name on the final line.

================ TRANSCRIPT ================
$(cat "$LOG")
============== END TRANSCRIPT ==============

Your turn ($who):
EOF
}

ask_claude() {
  build_prompt "Claude" | claude -p --effort max 2>/dev/null
}

ask_codex() {
  local out
  out=$(mktemp)
  build_prompt "Codex" | codex exec --skip-git-repo-check \
    -c model_reasoning_effort='"high"' \
    -s read-only \
    -o "$out" - >/dev/null 2>&1
  cat "$out"
  rm -f "$out"
}

#─────────────────────────────────────────────────────────────────────────────
# State + ASK_USER handling
#─────────────────────────────────────────────────────────────────────────────
save_state() {
  cat > "$STATE" <<EOF
MAX_ROUNDS=$MAX_ROUNDS
ROUND=$ROUND
CLAUDE_DONE=$CLAUDE_DONE
CODEX_DONE=$CODEX_DONE
NEXT=$NEXT
TOPIC=$(printf '%q' "$TOPIC")
EOF
}

extract_questions() {
  printf '%s\n' "$1" | grep -oE '\[ASK_USER:[^]]+\]' | sed -E 's/^\[ASK_USER:[[:space:]]*/- /; s/\]$//'
}

maybe_handle_questions() {
  local resp="$1"
  printf '%s\n' "$resp" | grep -q '\[ASK_USER:' || return 0
  save_state
  {
    echo "AGENT_DEBATE_NEEDS_INPUT"
    echo "TRANSCRIPT=$LOG"
    echo "QUESTIONS:"
    extract_questions "$resp"
    echo
    echo "RESUME_WITH:"
    echo "  echo \"<your answer>\" | $0 --resume \"$LOG\""
  }
  exit "$EXIT_NEED_INPUT"
}

#─────────────────────────────────────────────────────────────────────────────
# Main loop (entered fresh OR resumed mid-debate)
#─────────────────────────────────────────────────────────────────────────────
while [ "$ROUND" -le "$MAX_ROUNDS" ]; do
  if [ "$NEXT" = claude ] && [ "$CLAUDE_DONE" -eq 0 ]; then
    echo "── Round $ROUND: Claude ──" >&2
    echo -e "\n## Round $ROUND — Claude\n" >> "$LOG"
    resp=$(ask_claude)
    echo "$resp" >> "$LOG"
    NEXT=codex
    maybe_handle_questions "$resp"
    echo "$resp" | grep -q '\[CONVERGED\]' && CLAUDE_DONE=1
  fi

  if [ "$NEXT" = codex ] && [ "$CODEX_DONE" -eq 0 ]; then
    echo "── Round $ROUND: Codex ──" >&2
    echo -e "\n## Round $ROUND — Codex\n" >> "$LOG"
    resp=$(ask_codex)
    echo "$resp" >> "$LOG"
    NEXT=claude
    ROUND=$((ROUND + 1))
    maybe_handle_questions "$resp"
    echo "$resp" | grep -q '\[CONVERGED\]' && CODEX_DONE=1
  fi

  if [ "$CLAUDE_DONE" -eq 1 ] && [ "$CODEX_DONE" -eq 1 ]; then
    echo "── Both converged at round $((ROUND - 1)) ──" >&2
    break
  fi

  # If neither agent is going to advance (both done flags but loop didn't break), bail.
  if [ "$NEXT" = claude ] && [ "$CLAUDE_DONE" -eq 1 ] && [ "$CODEX_DONE" -eq 1 ]; then
    break
  fi
done

#─────────────────────────────────────────────────────────────────────────────
# Final synthesis
#─────────────────────────────────────────────────────────────────────────────
echo "── Final synthesis ──" >&2
echo -e "\n## Final synthesis\n" >> "$LOG"

SYNTH=$(cat <<EOF
Read the debate transcript above. Produce a final synthesis with:
1. The decision or recommendation (the best answer the two of you converged on, or your call if they disagreed).
2. Key tradeoffs surfaced.
3. Any unresolved disagreements and why they matter.
Be concise. No fluff.

================ TRANSCRIPT ================
$(cat "$LOG")
============== END TRANSCRIPT ==============
EOF
)

synth=$(printf '%s' "$SYNTH" | claude -p --effort max 2>/dev/null)
echo "$synth" >> "$LOG"

# Cleanup state file — debate is done
rm -f "$STATE"

echo
echo "$synth"
echo
echo "Transcript: $LOG" >&2
