# SeedScope

AI-native idea validation pipeline — from raw signal to validated MVP spec in Pure Lua.

Built entirely on [algocline](https://github.com/ynishi/algocline) bundled packages. No Python, no external APIs, no infra — just Lua + MCP.

## Why

Solo developers waste months building products nobody wants. SeedScope answers **"Should I build this, and if so, what exactly?"** by running a multi-stage evaluation pipeline that combines LLM reasoning with quantitative simulation.

## Pipeline

```
Web signals → Extract ideas → Screen & dedup → Bundle (market reference)
    → 5-persona debate + self-consistency EV scoring
    → ABM Monte Carlo market simulation (200 runs × 24 months)
    → Structured deliberation → MVP spec ready for Vibe Coding
    → Telemetry grounding (re-evaluate with real DL/revenue data)
```

## Bundled Package Showcase

SeedScope demonstrates what you can build with algocline's bundled packages alone:

| Bundled Package | Used In | What It Does |
|---|---|---|
| **panel** | evaluator | 5-persona adversarial debate (pragmatist / skeptic / builder / customer / contrarian) |
| **deliberate** | designer | 6-phase structured decision: abstract → consult → generate → debate → confidence → rank |
| **contrastive** | simulator | Incumbent absorption analysis with competitive landscape comparison |
| **calibrate** | simulator, evaluator | Probability calibration for risk confidence scoring and telemetry grounding |
| **abm** | simulator | Agent-based Monte Carlo market simulation with Agent.define + Model + mc.run_model |
| **SwarmFrame** | seed_scope_orch | Step-based pipeline orchestration with flow state persistence and resume |

## Packages (8 packages, ~1200 lines total)

| Package | Role | Key Feature |
|---|---|---|
| `seed_scope_orch` | Orchestrator | 4 modes: ingest / evaluate / re_evaluate / status |
| `sourcer` | Sourcing | Thompson Sampling theme arms + LLM idea extraction |
| `screener` | Filter | Fingerprint dedup → keyword rules → LLM batch screen |
| `evaluator` | Scoring | Panel debate + 5-lens self-consistency + EV formula + telemetry re-evaluation |
| `simulator` | Simulation | contrastive incumbent analysis + abm.mc.run_model (survival rate, Wilson CI, equilibrium) |
| `designer` | Design | Panel weakness analysis → feature classification → deliberate decision → MVP spec |
| `portfolio` | State | Eval history with EMA smoothing, Card emission, fingerprint dedup |
| `bandit` | Math | Thompson Sampling with Beta-Binomial (budget allocation + kill candidates) |

## Quick Start

```bash
# Install algocline
cargo install algocline

# Link the whole collection at once (collection mode — one call links every package)
alc pkg link packages

# Evaluate a single idea
alc run '
local orch = require("seed_scope_orch")
return orch.run({
    mode = "evaluate",
    task = "A browser extension that detects dark patterns on checkout pages and shows the real price",
    namespace = "demo",
})
'
```

## Example: Evaluate Mode Output

```lua
-- Input
{ mode = "evaluate", task = "Slack bot that auto-summarizes threads > 10 messages" }

-- Result (abbreviated)
{
    decision = "SCAFFOLD",
    expected_value = 18.742,
    metrics = {
        Pain_level = 8, Willingness_to_Pay = 6, Purchase_Realism = 5,
        Defensibility = 4, Self_Serve_Fit = 8, Time_to_MVP = 14,
    },
    debate_synthesis = "Strong pain signal in remote teams. Slack API limits are manageable...",
    simulation = {
        survived_rate = 0.67,
        survived_ci = { lower = 0.58, upper = 0.75 },
        final_revenue_median = 2100,
        equilibrium = "contested",
    },
}
```

## Example: Re-evaluate with Telemetry

After launching, feed real numbers back to ground the LLM evaluation:

```lua
alc run '
local orch = require("seed_scope_orch")
return orch.run({
    mode = "re_evaluate",
    task = "Slack bot that auto-summarizes threads > 10 messages",
    namespace = "demo",
    telemetry = {
        downloads = 340,
        revenue_usd = 1200,
        active_users = 180,
        churn_rate_pct = 8,
        months_live = 3,
    },
})
'
-- Result: EV 18.742 → 22.105 (+3.363), decision=SCAFFOLD, confidence=0.82
```

## Example: Full Ingest Pipeline

```lua
alc run '
local orch = require("seed_scope_orch")
return orch.run({
    mode = "ingest",
    namespace = "hn_weekly",
    raw_posts = {
        { title = "Ask HN: What tools do you wish existed?", body = "...", source = "hn" },
        { title = "I spent 6 months building X and nobody uses it", body = "...", source = "hn" },
    },
})
'
-- 7-step pipeline: source → screen → bundle → evaluate → simulate → design → record
-- Produces: screened ideas, EV scores, market simulations, MVP specs, portfolio Cards
```

## Specs

32 tests across 5 packages, all pure computation (no LLM calls in tests):

```bash
# Run all specs
for spec in packages/*/spec/*_spec.lua; do
    alc pkg test --code-file "$spec" --search-paths packages/
done
```

## Claude Code Agents (plugin)

The examples above drive the pipeline from the `alc` CLI. To run it from inside
Claude Code instead, SeedScope ships two subagents as a Claude Code plugin
(`plugins/seedscope/`):

| agent | mode |
|---|---|
| `seedscope-evaluate` | single-idea evaluate (SCAFFOLD/KILL + EV) |
| `seedscope-ingest`   | full pipeline from raw signal posts |

The plugin carries **agent definitions only** — algocline is a prerequisite, not
bundled. The agents call `mcp__algocline__alc_run` / `alc_continue`, which resolve
against your separately-installed algocline MCP server (registered under the
`algocline` alias).

```bash
# 1. Install algocline and register its MCP as alias "algocline", then link packages
cargo install algocline
alc pkg link packages

# 2. Add this repo as a plugin marketplace and install the plugin
/plugin marketplace add ynishi/seed-scope
/plugin install seedscope@seed-scope

# 3. Restart Claude Code (new installs apply on restart)
```

Then dispatch the agent (e.g. via the Task tool) with an idea or raw posts. See
[plugins/seedscope/README.md](plugins/seedscope/README.md) for details.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
