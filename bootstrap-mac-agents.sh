#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
SKIP_LIST=""
WARNINGS=()

MANAGED_ZSH_BLOCK_START="# >>> codex-agent-bootstrap >>>"
MANAGED_ZSH_BLOCK_END="# <<< codex-agent-bootstrap <<<"
MANAGED_AGENTS_BLOCK_START="<!-- codex-agent-bootstrap:start -->"
MANAGED_AGENTS_BLOCK_END="<!-- codex-agent-bootstrap:end -->"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ZSHRC_PATH="$HOME/.zshrc"
AGENTS_PATH="$CODEX_HOME/AGENTS.md"
GLOBAL_RULES_PATH="$CODEX_HOME/GLOBAL-MAC-AGENTS.md"
RTK_DOC_PATH="$CODEX_HOME/RTK.md"
REPOWISE_DOC_PATH="$CODEX_HOME/REPOWISE.md"
CAVEMAN_DOC_PATH="$CODEX_HOME/CAVEMAN.md"
CLAUDE_APP_PATH="/Applications/Claude.app"

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--skip component[,component...]]

Components:
  brew       Homebrew install + shellenv block
  codex      ~/.codex docs and AGENTS.md wiring
  claude     Claude Code caveman plugin install
  rtk        RTK install + Codex integration
  caveman    Caveman install for Codex (and Claude if available)
  repowise   Repowise install
  gh         GitHub CLI install

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --skip claude,gh
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*"
  WARNINGS+=("$*")
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  local description="$1"
  shift

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] $description"
    printf '  %q' "$@"
    printf '\n'
    return 0
  fi

  log "==> $description"
  "$@"
}

run_shell() {
  local description="$1"
  local command_string="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] $description"
    printf '  %s\n' "$command_string"
    return 0
  fi

  log "==> $description"
  bash -lc "$command_string"
}

should_skip() {
  local component="$1"
  case ",$SKIP_LIST," in
    *,"$component",*) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --skip)
        shift || fail "--skip requires a value"
        SKIP_LIST="$1"
        ;;
      --help|-h)
        print_usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

claude_app_installed() {
  [[ -d "$CLAUDE_APP_PATH" ]]
}

brew_prefix_guess() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '/opt/homebrew'
  elif [[ -x /usr/local/bin/brew ]]; then
    printf '/usr/local'
  else
    printf ''
  fi
}

upsert_managed_block() {
  local file="$1"
  local start="$2"
  local end="$3"
  local content="$4"
  local tmp

  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : > "$file"
  tmp="$(mktemp)"

  START="$start" END="$end" CONTENT="$content" FILE_PATH="$file" perl -0pe '
    my $start = $ENV{"START"};
    my $end = $ENV{"END"};
    my $content = $ENV{"CONTENT"};
    if (index($_, $start) >= 0) {
      s/\Q$start\E.*?\Q$end\E/$content/s;
    } else {
      $_ .= "\n" if length($_) && $_ !~ /\n\z/;
      $_ .= "\n" if length($_);
      $_ .= $content;
    }
  ' "$file" > "$tmp"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] update managed block in $file"
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
}

write_file() {
  local file="$1"
  local content="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] write $file"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$file"
}

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools: ready"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would require Xcode Command Line Tools install"
    return 0
  fi

  fail "Xcode Command Line Tools are not installed. Run xcode-select --install, complete the installer, then re-run $SCRIPT_NAME."
}

ensure_homebrew() {
  local brew_prefix
  local zsh_block

  brew_prefix="$(brew_prefix_guess)"

  if ! command_exists brew && [[ -z "$brew_prefix" ]]; then
    if should_skip brew; then
      fail "Homebrew is required unless brew and all dependent components are skipped."
    fi
    run_shell "Install Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    brew_prefix="$(brew_prefix_guess)"
  fi

  if [[ -z "$brew_prefix" ]] && command_exists brew; then
    brew_prefix="$(brew --prefix)"
  fi

  [[ -n "$brew_prefix" ]] || fail "Unable to determine Homebrew prefix."

  if [[ -x "$brew_prefix/bin/brew" ]]; then
    # Load brew into the current non-login shell so subsequent checks work in the same run.
    eval "$("$brew_prefix/bin/brew" shellenv)"
  fi

  zsh_block="$(cat <<EOF
$MANAGED_ZSH_BLOCK_START
if [ -x "$brew_prefix/bin/brew" ]; then
  eval "\$($brew_prefix/bin/brew shellenv)"
fi

case ":\$PATH:" in
  *":\$HOME/.local/bin:"*) ;;
  *) export PATH="\$HOME/.local/bin:\$PATH" ;;
esac
$MANAGED_ZSH_BLOCK_END
EOF
)"

  upsert_managed_block "$ZSHRC_PATH" "$MANAGED_ZSH_BLOCK_START" "$MANAGED_ZSH_BLOCK_END" "$zsh_block"
}

brew_install_if_missing() {
  local binary_name="$1"
  local brew_package="${2:-$1}"

  if command_exists "$binary_name"; then
    log "$binary_name: already installed"
    return 0
  fi

  run_cmd "brew install $brew_package" brew install "$brew_package"
}

ensure_shared_packages() {
  if ! should_skip gh; then
    brew_install_if_missing gh
  fi

  brew_install_if_missing jq

  if ! command_exists uv; then
    if should_skip repowise; then
      warn "uv is not installed and repowise is skipped."
    else
      run_cmd "brew install uv" brew install uv
    fi
  fi

  if ! should_skip caveman && ! command_exists npx; then
    run_cmd "brew install node" brew install node
  fi
}

ensure_rtk() {
  if should_skip rtk; then
    log "Skipping RTK"
    return 0
  fi

  if ! command_exists rtk; then
    run_cmd "brew install rtk" brew install rtk
  else
    log "rtk: already installed"
  fi

  run_cmd "Configure RTK for Codex" rtk init -g --codex
}

ensure_repowise() {
  if should_skip repowise; then
    log "Skipping Repowise"
    return 0
  fi

  if ! command_exists uv && [[ $DRY_RUN -ne 1 ]]; then
    fail "uv is required for Repowise installation."
  fi

  if command_exists repowise; then
    run_cmd "Upgrade Repowise" uv tool upgrade repowise
  else
    run_cmd "Install Repowise" uv tool install repowise
  fi
}

ensure_caveman() {
  if should_skip caveman; then
    log "Skipping Caveman"
    return 0
  fi

  if ! command_exists npx && [[ $DRY_RUN -ne 1 ]]; then
    fail "npx is required for Caveman installation. Install Node.js or do not skip caveman."
  fi

  run_cmd "Install Caveman for Codex" npx skills add JuliusBrussee/caveman -a codex

  if should_skip claude; then
    log "Skipping Claude plugin setup"
    return 0
  fi

  if command_exists claude; then
    run_shell "Install Caveman plugin for Claude Code" 'claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman'
  elif claude_app_installed; then
    warn "Claude.app is installed, but the 'claude' CLI is not on PATH; skipped Caveman Claude plugin install."
  else
    warn "Claude CLI and Claude.app were not found; skipped Caveman Claude plugin install."
  fi
}

write_codex_docs() {
  local user_name
  local global_rules
  local rtk_doc
  local repowise_doc
  local caveman_doc
  local agents_block

  if should_skip codex; then
    log "Skipping Codex global docs"
    return 0
  fi

  user_name="$(id -un)"

  global_rules="$(cat <<EOF
Prefer installed local capabilities over generic fallbacks when they are available on this machine.

Use the Repowise MCP tool first for codebase exploration, architecture lookup, semantic search, and change-risk analysis when it is available in the current project.

Use caveman skills only when the user explicitly asks for caveman mode, fewer tokens, or very brief output.

Prefer \`rtk\` for shell commands when it is available and the task is naturally a shell command.

@/Users/$user_name/.codex/RTK.md
@/Users/$user_name/.codex/REPOWISE.md
@/Users/$user_name/.codex/CAVEMAN.md
EOF
)"

  rtk_doc="$(cat <<'EOF'
# RTK

Use RTK for shell commands when compact command output helps preserve context.

Preferred pattern:
- use normal shell commands if RTK hooks already rewrite them for the active agent
- otherwise call `rtk <command>` explicitly

Useful checks:
- `rtk --version`
- `rtk gain`
- `rtk telemetry status`

If output fidelity matters more than compression, use normal shell commands or `rtk proxy <command>`.
EOF
)"

  repowise_doc="$(cat <<'EOF'
# Repowise

Use Repowise MCP before generic shell search when it is available and the task is about understanding a codebase.

Global setup rule: do not hardcode one specific repo or workspace into global Codex config.

Project setup rule:
- for a single repo, run `repowise init .` at the repo root
- for a multi-repo workspace, run `repowise init .` at the workspace root
- let Repowise write the project `.mcp.json` so the MCP server follows that project instead of one globally pinned path

If you later want one truly global Repowise endpoint across many projects, prefer a hosted/global Repowise MCP endpoint over a locally hardcoded repo path.

Prefer workspace-level Repowise targets over single-repo targets when a multi-repo workspace is already configured.

Preferred uses:
- repo overview and architecture map
- semantic search for concepts, files, and symbols
- context for files or symbols before editing
- why a design exists before architectural changes
- risk and blast-radius checks before modifying important files

Before relying on Repowise output, check whether the index appears current for the repo in question.

Signals that the index may be stale:
- cited files or symbols do not exist locally
- recent local changes are missing from Repowise answers
- answers conflict with direct file reads
- file paths, module names, or architecture summaries look outdated
- `repowise status` shows new commits, stale repos, or missing docs

Use this maintenance flow:
- `repowise status <path>` to inspect freshness
- `repowise doctor <path>` to validate setup health
- `repowise update <path>` or `repowise update --workspace <path>` to refresh stale indexes
- `repowise reindex <path>` if search/index drift is suspected
- `repowise hook install <path>` or `repowise hook install --workspace <path>` to keep indexes current after commits

If the index appears stale and you cannot refresh it yourself, say so clearly and ask a human to refresh or rebuild the Repowise index before treating it as authoritative. Fall back to direct local inspection in the meantime.

If `repowise status` shows generated docs are missing or skipped, do not treat Repowise wiki summaries as authoritative. Use graph and git signals carefully, prefer direct file reads, and ask a human to run a docs-generating refresh if wiki-level answers are needed.

Repowise is a preference rule, not a hard requirement. Fall back to normal file inspection when Repowise is unavailable or the task is simpler with direct local reads.
EOF
)"

  caveman_doc="$(cat <<'EOF'
# Caveman

Use caveman only when the user asks for it or clearly asks for maximum brevity or token efficiency.

Triggers include:
- `caveman`
- `caveman mode`
- `talk like caveman`
- `less tokens`
- `be brief`

For Codex, Caveman is trigger-based, not always-on. Use the installed skill rather than inventing a custom compressed style.

For Claude Code, plugin and hook behavior should come from the upstream Caveman plugin install, not from custom global instructions.
EOF
)"

  agents_block="$(cat <<EOF
$MANAGED_AGENTS_BLOCK_START
Check \`~/.zshrc\` for Homebrew paths if a package appears missing.

@$GLOBAL_RULES_PATH
$MANAGED_AGENTS_BLOCK_END
EOF
)"

  write_file "$GLOBAL_RULES_PATH" "$global_rules"
  write_file "$RTK_DOC_PATH" "$rtk_doc"
  write_file "$REPOWISE_DOC_PATH" "$repowise_doc"
  write_file "$CAVEMAN_DOC_PATH" "$caveman_doc"
  upsert_managed_block "$AGENTS_PATH" "$MANAGED_AGENTS_BLOCK_START" "$MANAGED_AGENTS_BLOCK_END" "$agents_block"
}

verify_binary() {
  local label="$1"
  local cmd="$2"
  if command_exists "$cmd"; then
    printf '  [ok] %s\n' "$label"
  else
    printf '  [missing] %s\n' "$label"
  fi
}

print_summary() {
  local warning

  log ""
  log "Verification summary"
  verify_binary "brew" brew
  verify_binary "gh" gh
  verify_binary "jq" jq
  verify_binary "uv" uv
  verify_binary "rtk" rtk
  verify_binary "repowise" repowise
  verify_binary "node" node
  verify_binary "npx" npx
  if command_exists claude; then
    printf '  [ok] %s\n' "claude CLI"
  elif claude_app_installed; then
    printf '  [app-only] %s\n' "$CLAUDE_APP_PATH"
  else
    printf '  [missing] %s\n' "claude CLI / Claude.app"
  fi

  if [[ -f "$AGENTS_PATH" ]]; then
    printf '  [ok] %s\n' "$AGENTS_PATH"
  else
    printf '  [missing] %s\n' "$AGENTS_PATH"
  fi
  if [[ -f "$GLOBAL_RULES_PATH" ]]; then
    printf '  [ok] %s\n' "$GLOBAL_RULES_PATH"
  else
    printf '  [missing] %s\n' "$GLOBAL_RULES_PATH"
  fi
  if [[ -f "$RTK_DOC_PATH" ]]; then
    printf '  [ok] %s\n' "$RTK_DOC_PATH"
  else
    printf '  [missing] %s\n' "$RTK_DOC_PATH"
  fi
  if [[ -f "$REPOWISE_DOC_PATH" ]]; then
    printf '  [ok] %s\n' "$REPOWISE_DOC_PATH"
  else
    printf '  [missing] %s\n' "$REPOWISE_DOC_PATH"
  fi
  if [[ -f "$CAVEMAN_DOC_PATH" ]]; then
    printf '  [ok] %s\n' "$CAVEMAN_DOC_PATH"
  else
    printf '  [missing] %s\n' "$CAVEMAN_DOC_PATH"
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    log ""
    log "Warnings"
    for warning in "${WARNINGS[@]}"; do
      printf '  - %s\n' "$warning"
    done
  fi

  log ""
  log "Next step for each new repo/workspace:"
  log "  ./repowise-project-init.sh /path/to/repo-or-workspace"
}

main() {
  parse_args "$@"

  ensure_xcode_clt
  ensure_homebrew
  ensure_shared_packages
  ensure_rtk
  ensure_repowise
  ensure_caveman
  write_codex_docs
  print_summary
}

main "$@"
