# Claude Code turn floor, 2026-10-29 (mini, Claude Code CLI, `--effort low`, 4 runs each)

| setup | cold first token p50 | booted 8 s before input p50 |
|---|---|---|
| Haiku 5.5, minimal flags | 2.38 s | 1.72 s |
| Sonnet 5.5, minimal flags | 2.88 s | 1.96 s |
| Haiku 5.5, Perry flags | 1.18 s | 1.98 s |
| Haiku 5.5, Perry flags + stub MCP (30 tools) | 1.43 s | 1.32 s |
| Haiku 5.5, Perry flags + MCP + 24 KB prompt | 2.52 s | 1.60 s |

Process boot costs under 1 s. A pre-spawned process would save at most ~0.9 s per turn,
so Task 2 (warm process) is skipped. The ~6 s seen in Perry is several model round trips
(observe, act, answer) on Sonnet; quick turns now use Haiku 5.5.

Script: `scripts/lab/claude-floor.py`.
