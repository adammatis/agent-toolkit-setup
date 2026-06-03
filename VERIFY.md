# Verification

## Machine bootstrap

Run:

```bash
./bootstrap-mac-agents.sh --dry-run
./bootstrap-mac-agents.sh
```

Expected checks:

- `brew --version`
- `gh --version`
- `jq --version`
- `uv --version`
- `rtk --version`
- `repowise --version`
- `node --version`
- `npx --version`
- optional: `claude --version`

Expected files:

- `~/.codex/AGENTS.md`
- `~/.codex/GLOBAL-MAC-AGENTS.md`
- `~/.codex/RTK.md`
- `~/.codex/REPOWISE.md`
- `~/.codex/CAVEMAN.md`

Expected RTK integration:

```bash
rtk init -g --codex
rtk gain
```

Expected usage reporting:

```bash
./agent-usage-report.py
./agent-usage-report.py --json
./agent-usage-report.py --project /path/to/repo
```

Expected behavior:

- RTK section reports exact savings if `rtk` is installed.
- Claude section reports real token usage if local Claude session logs exist.
- Claude Caveman savings are clearly marked unavailable unless you inspect them in-session with `/caveman-stats`.

Expected Caveman integration:

```bash
npx skills add JuliusBrussee/caveman -a codex
```

If Claude Code is installed:

```bash
claude plugin marketplace add JuliusBrussee/caveman
claude plugin install caveman@caveman
```

## Repowise helper

Single repo:

```bash
mkdir -p /tmp/repowise-test-repo
cd /tmp/repowise-test-repo
git init
./repowise-project-init.sh --dry-run /tmp/repowise-test-repo
```

Workspace:

```bash
mkdir -p /tmp/repowise-test-workspace/repo-a
mkdir -p /tmp/repowise-test-workspace/repo-b
git -C /tmp/repowise-test-workspace/repo-a init
git -C /tmp/repowise-test-workspace/repo-b init
./repowise-project-init.sh --dry-run /tmp/repowise-test-workspace
```

Expected behavior:

- detects repo vs workspace automatically
- uses `repowise init . --index-only` by default
- installs the appropriate hook mode
- runs `repowise doctor`
- runs `repowise status`
- prints provider setup guidance for `--with-docs`

## Negative paths

- No `claude` binary: bootstrap warns and continues.
- No API key: global bootstrap still succeeds; only `repowise-project-init.sh --with-docs` needs provider config.
- Re-run bootstrap: managed blocks remain single-copy and docs remain stable.
