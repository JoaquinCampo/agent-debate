# agent-debate

A Claude Code plugin that orchestrates a peer back-and-forth between Claude (`claude -p --effort max`) and Codex (`codex exec` with high reasoning), then produces a structured synthesis: decision, tradeoffs, unresolved disagreements.

When the agents are genuinely blocked on something only the user can answer, they pause; the orchestrating agent (Claude Code) proxies the question to you and feeds your answer back into the debate.

## Why

Single-model answers on contested architecture decisions are often confidently wrong. A peer dialogue between two strong models, where each can challenge the other and quote disagreements, surfaces tradeoffs and weak reasoning that one model on its own would smooth over.

## Install

```bash
claude plugin marketplace add JoaquinCampo/agent-debate
claude plugin install agent-debate
```

## Prerequisites

The plugin shells out to two CLIs:

1. **Claude Code CLI** (`claude`). You already have this if you're reading this.
2. **Codex CLI** (`codex`). Install per the [Codex docs](https://github.com/openai/codex), then authenticate:
   ```bash
   codex login
   ```

A preflight check in the script will fail-fast with a clear message if either CLI is missing. A missing `codex` auth token is harder to detect; if a debate hangs before Codex's first turn (~60s), suspect this.

## Usage

Just ask. The skill triggers on phrases like:

- "Have Claude and Codex debate whether I should use Drizzle or Prisma"
- "Get them to discuss this architecture choice"
- "Ask Codex too and let them work it out"

You can also be explicit by invoking the skill name (`agent-debate:agent-debate`).

The plugin will:

1. Frame your topic into a tight question.
2. Run a multi-round debate (default cap 100 rounds; agents typically converge well before that).
3. If either agent emits `[ASK_USER: ...]`, the orchestrator pauses and asks you, then resumes.
4. Return a synthesis: decision, tradeoffs, unresolved disagreements.
5. Save the full transcript to `~/agent-debates/<timestamp>-<slug>.md` so you can dig in later.

## Configuration

- `AGENT_DEBATE_DIR` (env var): override the transcript directory. Default `~/agent-debates`.

## How it works

- Two CLIs run sequentially per round, each seeing the full transcript so far.
- A seed prompt instructs both agents to disagree freely, ask sharp questions of each other, and only ask the user for input when truly blocked (after stating assumptions and engaging with the peer).
- An exit-42 protocol lets the script pause for user input without the debating agents knowing a proxy exists; they just see a `## User input` section in the transcript.
- When done, a final synthesis call (Claude, max effort) summarizes the debate.

## Caveats

- Each turn runs at full thinking budget. Debates take real time and tokens.
- The agents can't run tools that need approval. Topics that push Claude to "go check the codebase" can hang on permission prompts.
- The script is single-host; debates aren't resumable across machines.

## License

MIT.
