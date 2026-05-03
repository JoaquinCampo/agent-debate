#!/usr/bin/env bash
set -euo pipefail

# agent-debate.sh — peer back-and-forth between two AI agents.
#
# Modes:
#   agent-debate.sh [--pair <a>-<b>] "<topic>" [rounds]
#       Start a fresh debate. Pair format: <kind>-<kind> where each kind is
#       "claude" or "codex". Default: claude-codex. The first agent in the pair
#       goes first AND produces the final synthesis. Same-kind pairs are
#       labeled "<Kind> A" / "<Kind> B" so the agents can address each other.
#       Writes transcript to $AGENT_DEBATE_DIR (default ~/agent-debates).
#       On completion: prints synthesis to stdout, exits 0.
#       If an agent emits [ASK_USER: ...]: prints a structured NEEDS_INPUT block
#       to stdout and exits 42 so the orchestrating skill can collect the
#       answer from the user.
#
#   agent-debate.sh --resume <transcript_path>
#       Continue a previously paused debate. Reads the user's answer from stdin
#       and appends it to the transcript, then continues from where the script
#       paused. The pair is restored from the .state file.
#
# Exit codes:
#   0   debate finished, synthesis on stdout
#   42  paused for user input (see NEEDS_INPUT block on stdout)
#   1+  error

EXIT_NEED_INPUT=42

#─────────────────────────────────────────────────────────────────────────────
# Arg parsing
#─────────────────────────────────────────────────────────────────────────────
PAIR="claude-codex"
RESUME=0
RESUME_LOG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pair)
      PAIR="${2:?--pair requires <a>-<b> (e.g. claude-codex, codex-codex)}"
      shift 2
      ;;
    --pair=*)
      PAIR="${1#--pair=}"
      shift
      ;;
    --resume)
      RESUME=1
      RESUME_LOG="${2:?--resume requires <transcript_path>}"
      shift 2
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done
      break
      ;;
    -*)
      echo "agent-debate: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# Validate pair. Done before resume too — state file overrides if resuming.
case "$PAIR" in
  claude-codex|codex-claude|claude-claude|codex-codex) : ;;
  *)
    echo "agent-debate: invalid --pair '$PAIR'. Valid: claude-codex, codex-claude, claude-claude, codex-codex" >&2
    exit 2
    ;;
esac

A_KIND="${PAIR%-*}"
B_KIND="${PAIR#*-}"
if [ "$A_KIND" = "$B_KIND" ]; then
  case "$A_KIND" in
    claude) A_NAME="Claude A"; B_NAME="Claude B" ;;
    codex)  A_NAME="Codex A";  B_NAME="Codex B"  ;;
  esac
else
  case "$A_KIND" in claude) A_NAME="Claude" ;; codex) A_NAME="Codex" ;; esac
  case "$B_KIND" in claude) B_NAME="Claude" ;; codex) B_NAME="Codex" ;; esac
fi
SYNTH_KIND="$A_KIND"

#─────────────────────────────────────────────────────────────────────────────
# Preflight: only require CLIs we'll actually use.
#─────────────────────────────────────────────────────────────────────────────
need_claude=0
need_codex=0
if [ "$A_KIND" = claude ] || [ "$B_KIND" = claude ]; then need_claude=1; fi
if [ "$A_KIND" = codex  ] || [ "$B_KIND" = codex  ]; then need_codex=1; fi

if [ "$need_claude" = 1 ]; then
  command -v claude >/dev/null 2>&1 || { echo "agent-debate: 'claude' CLI not found in PATH" >&2; exit 2; }
fi
if [ "$need_codex" = 1 ]; then
  command -v codex >/dev/null 2>&1 || { echo "agent-debate: 'codex' CLI not found in PATH" >&2; exit 2; }
  codex --help >/dev/null 2>&1 || { echo "agent-debate: 'codex' CLI is broken or not configured. Run 'codex login' first." >&2; exit 2; }
fi

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
if [ "$RESUME" = 1 ]; then
  LOG="$RESUME_LOG"
  STATE="${LOG}.state"
  [ -f "$LOG" ] || { echo "transcript not found: $LOG" >&2; exit 1; }
  [ -f "$STATE" ] || { echo "state file not found: $STATE (debate may already be finished)" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE"
  # State restores: PAIR, A_KIND, B_KIND, A_NAME, B_NAME, SYNTH_KIND,
  # MAX_ROUNDS, ROUND, A_DONE, B_DONE, NEXT, TOPIC.
  ANSWER=$(cat)
  {
    echo
    echo "## User input"
    echo
    printf '%s\n' "$ANSWER"
  } >> "$LOG"
else
  if [ "${#ARGS[@]}" -lt 1 ]; then
    echo "usage: agent-debate.sh [--pair <a>-<b>] \"<topic>\" [rounds]   |   --resume <transcript_path>" >&2
    exit 2
  fi
  TOPIC="${ARGS[0]}"
  MAX_ROUNDS="${ARGS[1]:-100}"
  TS=$(date +%Y%m%d-%H%M%S)
  SLUG=$(printf '%s' "$TOPIC" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-50)
  DIR="${AGENT_DEBATE_DIR:-$HOME/agent-debates}"
  mkdir -p "$DIR"
  LOG="$DIR/${TS}-${SLUG}.md"
  STATE="${LOG}.state"
  ROUND=1
  A_DONE=0
  B_DONE=0
  NEXT=a
  {
    echo "# Agent debate: $TOPIC"
    echo
    echo "- Started: $(date)"
    echo "- Pair: $A_NAME ($A_KIND) vs $B_NAME ($B_KIND)"
    echo "- Synthesis by: $SYNTH_KIND"
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

call_claude() {
  build_prompt "$1" | claude -p --effort max 2>/dev/null
}

call_codex() {
  local out
  out=$(mktemp)
  build_prompt "$1" | codex exec --skip-git-repo-check \
    -c model_reasoning_effort='"high"' \
    -s read-only \
    -o "$out" - >/dev/null 2>&1
  cat "$out"
  rm -f "$out"
}

ask_agent() {
  # $1 = kind (claude|codex), $2 = display name
  case "$1" in
    claude) call_claude "$2" ;;
    codex)  call_codex  "$2" ;;
  esac
}

#─────────────────────────────────────────────────────────────────────────────
# State + ASK_USER handling
#─────────────────────────────────────────────────────────────────────────────
save_state() {
  cat > "$STATE" <<EOF
PAIR=$(printf '%q' "$PAIR")
A_KIND=$(printf '%q' "$A_KIND")
B_KIND=$(printf '%q' "$B_KIND")
A_NAME=$(printf '%q' "$A_NAME")
B_NAME=$(printf '%q' "$B_NAME")
SYNTH_KIND=$(printf '%q' "$SYNTH_KIND")
MAX_ROUNDS=$MAX_ROUNDS
ROUND=$ROUND
A_DONE=$A_DONE
B_DONE=$B_DONE
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
  if [ "$NEXT" = a ] && [ "$A_DONE" -eq 0 ]; then
    echo "── Round $ROUND: $A_NAME ──" >&2
    echo -e "\n## Round $ROUND — $A_NAME\n" >> "$LOG"
    resp=$(ask_agent "$A_KIND" "$A_NAME")
    echo "$resp" >> "$LOG"
    NEXT=b
    maybe_handle_questions "$resp"
    echo "$resp" | grep -q '\[CONVERGED\]' && A_DONE=1
  fi

  if [ "$NEXT" = b ] && [ "$B_DONE" -eq 0 ]; then
    echo "── Round $ROUND: $B_NAME ──" >&2
    echo -e "\n## Round $ROUND — $B_NAME\n" >> "$LOG"
    resp=$(ask_agent "$B_KIND" "$B_NAME")
    echo "$resp" >> "$LOG"
    NEXT=a
    ROUND=$((ROUND + 1))
    maybe_handle_questions "$resp"
    echo "$resp" | grep -q '\[CONVERGED\]' && B_DONE=1
  fi

  if [ "$A_DONE" -eq 1 ] && [ "$B_DONE" -eq 1 ]; then
    echo "── Both converged at round $((ROUND - 1)) ──" >&2
    break
  fi

  # If neither agent is going to advance (both done flags but loop didn't break), bail.
  if [ "$NEXT" = a ] && [ "$A_DONE" -eq 1 ] && [ "$B_DONE" -eq 1 ]; then
    break
  fi
done

#─────────────────────────────────────────────────────────────────────────────
# Final synthesis (run by the first agent's kind)
#─────────────────────────────────────────────────────────────────────────────
echo "── Final synthesis ($SYNTH_KIND) ──" >&2
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

case "$SYNTH_KIND" in
  claude)
    synth=$(printf '%s' "$SYNTH" | claude -p --effort max 2>/dev/null)
    ;;
  codex)
    synth_out=$(mktemp)
    printf '%s' "$SYNTH" | codex exec --skip-git-repo-check \
      -c model_reasoning_effort='"high"' \
      -s read-only \
      -o "$synth_out" - >/dev/null 2>&1
    synth=$(cat "$synth_out")
    rm -f "$synth_out"
    ;;
esac

echo "$synth" >> "$LOG"

# Cleanup state file — debate is done
rm -f "$STATE"

echo
echo "$synth"
echo
echo "Transcript: $LOG" >&2
