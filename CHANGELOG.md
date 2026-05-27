# Changelog

## 0.1.0 — 2026-05-28

Initial release. 8 Lua packages for AI-native idea validation.

### Packages

- **seed_scope_orch**: SwarmFrame pipeline orchestrator (ingest / evaluate / re_evaluate / status)
- **sourcer**: Thompson Sampling idea sourcer with theme/source arms
- **screener**: Multi-stage idea filter (dedup + rules + LLM screen)
- **evaluator**: 5-persona panel debate + self-consistency scoring + EV calculation
- **simulator**: Incumbent analysis + ABM Monte Carlo market simulation
- **designer**: Competitive positioning + structured deliberation + MVP spec generation
- **portfolio**: Portfolio state management with eval history and Card emission
- **bandit**: Thompson Sampling Beta-Binomial model (pure math)

### Features

- 4 operation modes: ingest (full pipeline), evaluate (single idea), re_evaluate (telemetry grounding), status (read-only)
- Telemetry grounding in re_evaluate: revenue→WTP, retention→SSF, churn→Def, downloads→PR
- 32 spec tests across 7 spec files
- E2E non-LLM spec for seed_scope_orch (evaluate/status/re_evaluate)
- Apache-2.0 / MIT dual license
