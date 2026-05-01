---
name: agent-debate
description: 'Use when the user wants Claude and Codex to debate or discuss something together, or presents a hard "X vs Y" architecture tradeoff. Triggers: "have them debate", "ask Codex too", "discuss with another agent". Skip simple lookups and code edits.'
---

# agent-debate

Orchestrates a peer back-and-forth between Claude (`claude -p --effort max`) and Codex (`codex exec` with high reasoning). Captures the full transcript, lets the agents pause to ask the user a clarifying question when genuinely blocked, and produces a final synthesis (decision, tradeoffs, unresolved disagreements).

You are NOT a debater. Your job is: invoke the script, proxy any questions to the user, return the synthesis.

## How to invoke

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/agent-debate/agent-debate.sh" "<topic>" [rounds]
```

- Frame `<topic>` as a tight, single question. The user's words may be loose; tighten them.
- Default 4 rounds. Use 2 for narrow questions, 6+ for genuinely contested architecture.
- Transcript writes to `~/agent-debates/<timestamp>-<slug>.md`.
- Each turn takes 30 to 90 seconds, so a 4-round debate runs 5 to 10 minutes. Always run in background and wait via `run_in_background: true` or Monitor. Do NOT poll.

## Protocol: three exit conditions

### Exit 0, debate finished
- Stdout has the final synthesis. Present it to the user.
- Stderr's last line is `Transcript: <path>`. Mention this so the user can read the full debate.

### Exit 42, agents need user input
Stdout block:

```
AGENT_DEBATE_NEEDS_INPUT
TRANSCRIPT=<path>
QUESTIONS:
- <question 1>
- <question 2>
RESUME_WITH:
  echo "<your answer>" | <script> --resume "<path>"
```

Steps:
1. Parse lines after `QUESTIONS:` (each starts with `- `).
2. Ask the user, verbatim. Bundle all questions into one ask, do not serialize. Use AskUserQuestion if the questions have option-shaped answers; otherwise ask conversationally.
3. Resume: `echo "<user's full answer>" | bash "${CLAUDE_PLUGIN_ROOT}/skills/agent-debate/agent-debate.sh" --resume "<transcript path>"`.
4. The resumed run can itself exit 42 again. Loop until exit 0.

### Other non-zero exit, error
Show the user the stderr output and stop.

## Hard rules

- The debating agents do NOT know about the user proxy. The user appears to them as a `## User input` section in the transcript.
- Pass the agents' questions to the user verbatim. No paraphrasing, no filtering.
- Pipe the user's answer back verbatim. No editing.
- The agents have been instructed to ask sparingly. If they ask, the question is real. Do not second-guess; relay.
- Do not run the debate yourself.

## Reading the transcript

If the user asks "what did they actually say" or "show me the full debate", read the transcript file (path from stderr or the `TRANSCRIPT=` line) and quote relevant exchanges directly.

## Background invocation pattern

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/agent-debate/agent-debate.sh" "topic" 4 < /dev/null \
  > /tmp/debate-out.txt 2> /tmp/debate-err.txt
```

Run with `run_in_background: true`. When notified, read `/tmp/debate-out.txt` and check the exit code.

For resume, same pattern with `--resume "<path>"` and stdin piped from the user's answer.

## Gotchas

- **Codex auth not configured.** If `codex` is installed but the user has not run `codex login`, the script will hang in round 1 with no obvious error. The new preflight in `agent-debate.sh` catches a broken `codex` CLI but not a missing auth token. If a debate stalls before Codex's first turn, suspect this and tell the user to run `codex login`.
- **Stale `.state` file from a killed run.** If a previous debate was interrupted (Ctrl-C, killed process), `<transcript>.state` may persist and a `--resume` could continue an old session. If a resume behaves oddly, check if the state file matches the transcript you intend to continue. Delete it to force a fresh start.
- **Multi-line ASK_USER questions get truncated.** The script's regex for `[ASK_USER: ...]` is single-line. If an agent emits a question that spans multiple lines, only the first line is captured. Mitigation: when you see a question that looks cut off, read the transcript yourself and relay the full question to the user.
- **Claude permission prompts can block.** `claude -p` runs without `--dangerously-skip-permissions`. If Claude tries to invoke a tool that would require user approval (web fetch is fine, file edits or shell ops would prompt), the script will hang. Topics that nudge Claude toward "let me check the codebase" are riskier than pure design questions.
- **Long debates can exceed Monitor timeouts.** A 6-round debate with thinking can run 15+ minutes. Set generous timeouts on the background invocation.
- **Don't propose offering /schedule for a debate.** A debate is a one-off conversation, not a recurring task.

## When the user asks "have them discuss X"

That is the trigger. Tighten X into a single question, pick rounds (2 narrow, 4 default, 6+ contested), invoke the script, follow the protocol.
