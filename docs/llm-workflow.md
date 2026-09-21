# LLM Workflow — reference doc

Living reference for the agent tooling stack around this project: what is installed,
what was deliberately rejected, and the weakness register. Update this file when
skills/tools change or weaknesses move.

Last reviewed: 2026-09-06

## Installed skills (`~/.kimi-code/skills/`)

Restart the CLI session to pick up newly installed skills.

### Infrastructure (came with the CLI)

| Skill | What it does |
|---|---|
| codebase-memory (skill + MCP) | Codebase knowledge graph: search, trace callers, blast radius |
| write-goal | Craft `/goal` objectives for autonomous mode |
| update-config | Edit this CLI's own config |
| check-kimi-code-docs | Product docs Q&A for this CLI |

### Methodology (mattpocock/skills, installed 2026-09-06)

| Skill | What it does |
|---|---|
| grill-me + grilling | Relentless one-question-at-a-time interview before planning |
| handoff | Compress a live session into a cold-start prompt for the next one |
| tdd | Red-green-refactor with integration tests |
| diagnosing-bugs | Structured debugging loop |
| code-review | Review discipline |
| to-spec / to-tickets | Conversation → spec → tracer-bullet tickets |
| domain-modeling / codebase-design | DDD patterns, ADR + CONTEXT.md formats |
| improve-codebase-architecture | Find shallow modules, propose deepenings |
| triage / research / prototype / implement / wizard / wayfinder | Task routing & execution |
| teach / wait-what / to-questionnaire / writing-for-agents | Productivity |
| grill-with-docs | grill-me tested against repo docs → CONTEXT.md/ADRs |
| ask-matt | Router mapping all user-reachable skills |

### Meta

| Skill | What it does |
|---|---|
| skill-creator (anthropics/skills) | Mint, edit, and eval your own skills |

## MCP servers

| Server | Role |
|---|---|
| codebase-memory-mcp | Structural code graph |
| serena | LSP-grade editing + cross-session memories |
| context7 | Live library docs |
| sequential-thinking | Reasoning scaffold |

## Deliberately rejected (researched, do not re-propose without new evidence)

| Tool | Why |
|---|---|
| obra/superpowers | Overlaps mattpocock; auto-injected pipeline fights this repo's AGENTS.md discipline; assumes Claude Code hooks |
| alirezarezvani/claude-skills (380 skills) | Volume play, redundant with mattpocock + skill-creator |
| prompt-master, /48, /fable | Chatbot-era prompt polish; per-model-version tuning is astrology |
| personal-voice | Only for published prose |
| how-to | Plan mode covers it |
| anti-ai / stop-slop | Revisit only when publishing docs/README |

## Weakness register

| # | Weakness | Status | Notes |
|---|---|---|---|
| 1 | No LLM quality evals (benchmark measured speed only) | **FIXED 2026-09-06** | `scripts/llm-eval.py` + `evals/eval-set.json`. Deterministic checks (string/regex/JSON/executed Python), no judge model. Results in `evals/results/`. First run: 8/8 on Qwen3.6-35B. Future: LLM-as-judge for open-ended quality |

Gotcha recorded: Qwen3.6 (thinking model) burns ~500-1000 tokens on
`reasoning_content` before emitting content. With `MAX_TOKENS=512` every case
fails with empty content and `finish_reason="length"` — a harness bug that looks
like model failure. Default is 2048. The eval reports `truncated` explicitly if
a case still hits the cap.
| 2 | No GitHub/forge MCP | DEFERRED | Trigger: first time collaboration or PR review needs it |
| 3 | No browser/Playwright MCP | DEFERRED | Trigger: first project needing UX/E2E testing |
| 4 | No cross-session memory habit | IN PROGRESS | Serena memories started (`local-llm/benchmark-and-eval-config`); use `handoff` skill at context limits |
| 5 | Zero own skills distilled | **FIXED 2026-09-06** | `local-llm-ops` skill created and installed (benchmark + eval + stack ops + resource discipline). Tested via skill-creator A/B loop: 11/11 both arms — non-discriminating assertions, but the OOM incident it triggered produced the skill's key safety rule. Eval workspace: `~/.kimi-code/skills/local-llm-ops-workspace/` |
| 6 | mattpocock skills unproven in this CLI | OPEN | Smoke-test grill-me + handoff first; prune what misbehaves. `setup-matt-pocock-skills` is Claude-Code-specific, likely a no-op here |

## Eval usage

```bash
# Full eval (8 cases)
python3 scripts/llm-eval.py

# Smoke test (2 cases)
python3 scripts/llm-eval.py --limit 2

# Only coding cases
python3 scripts/llm-eval.py --tag coding

# Against a different server/model
SERVER_URL=http://llm-server:8080 MODEL_NAME=local-model python3 scripts/llm-eval.py
```

Same config convention as `benchmark.sh`: env vars `SERVER_URL`, `MODEL_NAME`,
`MAX_TOKENS`, `TEMPERATURE`; no config file.

**Rule: never claim a model is "better" from `benchmark.sh` alone. Speed comes from
benchmark, quality comes from eval. Cite both or neither.**
