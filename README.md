# Global Mac Agent Bootstrap

Portable bootstrap for a fresh macOS machine with:

- Codex global setup
- RTK for compact shell output
- Caveman for Codex and Claude Code
- Repowise installed globally, initialized per project
- Local usage reporting for RTK savings and Claude token usage

## What this installs

- Homebrew shell setup in `~/.zshrc`
- `rtk`, `uv`, `gh`, `jq`, and `node` when needed
- Codex global docs in `~/.codex`
- Caveman for Codex with upstream `npx skills` install
- Caveman plugin for Claude Code if `claude` is installed
- Repowise CLI globally, without pinning any repo into global Codex config

## Install on a fresh Mac

```bash
chmod +x ./bootstrap-mac-agents.sh ./repowise-project-init.sh
./bootstrap-mac-agents.sh
```

Dry-run first:

```bash
./bootstrap-mac-agents.sh --dry-run
```

Skip optional components:

```bash
./bootstrap-mac-agents.sh --skip claude,gh
```

## New repo onboarding

Repowise is intentionally project-local. After cloning or opening a repo/workspace:

```bash
./repowise-project-init.sh /path/to/repo-or-workspace
```

By default the helper uses `--index-only`, so it works without API keys. To generate Repowise wiki/docs too:

```bash
./repowise-project-init.sh --with-docs /path/to/repo-or-workspace
```

Then verify:

```bash
ls /path/to/repo-or-workspace/.mcp.json
repowise status /path/to/repo-or-workspace
```

## Usage reporting

Check machine-level RTK savings and Claude token usage:

```bash
./agent-usage-report.py
```

Scope it to one project:

```bash
./agent-usage-report.py --project ~/Repos/some-repo
```

JSON output:

```bash
./agent-usage-report.py --json
```

Notes:

- RTK savings are exact and come from `rtk gain --format json`.
- Claude usage is aggregated from local `~/.claude/projects/*.jsonl` session logs.
- Claude Caveman savings are not exposed as a stable global file by default, so this tool reports real usage and points you to `/caveman-stats` for per-session Caveman savings inside Claude.

## Design rules

- Codex is the primary target.
- Claude support is installed only where upstream provides a clean native path.
- Caveman stays trigger-based for Codex; it is not forced always-on.
- Repowise stays repo/workspace-local; no global MCP server is pinned to one project.

## Verification

See [VERIFY.md](/Users/adammatis/Documents/Codex/2026-06-03/how-can-i-setup-codex-to/VERIFY.md) for a checklist and expected commands.
