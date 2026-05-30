# seedscope (Claude Code plugin)

SeedScope の idea-validation パイプラインを Claude Code から駆動する subagent を配布する plugin。

## Agents

| agent | 役割 |
|---|---|
| `seedscope-evaluate` | 単一アイデアの evaluate モード (SCAFFOLD/KILL 判定 + EV スコア) |
| `seedscope-ingest`   | raw signal posts からのフル pipeline (source→screen→evaluate→simulate→design) |

両 agent は `mcp__algocline__alc_run` / `mcp__algocline__alc_continue` を介して
seed-scope の Lua package (`seed_scope_orch`) を実行する。

## 前提 (Prerequisite)

この plugin は **algocline MCP を同梱しない**。利用前に algocline を別途 install し、
MCP サーバーを `algocline` という alias で登録しておくこと
(agent の `tools: mcp__algocline__...` がその alias に解決される)。

seed-scope の Lua package 群もリンク済みである必要がある:

```bash
alc pkg link <path-to>/seed-scope/packages
```

## Install

```bash
# 1. algocline をセットアップ (MCP を alias "algocline" で登録)
#    seed-scope の packages を link
alc pkg link <path-to>/seed-scope/packages

# 2. この plugin を marketplace 経由で追加
/plugin marketplace add ynishi/seed-scope
/plugin install seedscope@seed-scope

# 3. Claude Code を restart (新規 install は restart で反映)
```

ローカル開発時は `claude --plugin-dir ./plugins/seedscope` でも読み込める。
