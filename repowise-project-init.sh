#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
WITH_DOCS=0
TARGET_PATH="."

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--with-docs] [path]

Defaults:
  path       current directory
  mode       --index-only unless --with-docs is passed

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME ~/Repos/my-repo
  $SCRIPT_NAME --with-docs ~/Repos/my-workspace
EOF
}

log() {
  printf '%s\n' "$*"
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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --with-docs)
        WITH_DOCS=1
        ;;
      --help|-h)
        print_usage
        exit 0
        ;;
      *)
        TARGET_PATH="$1"
        ;;
    esac
    shift
  done
}

is_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

workspace_repo_count() {
  find "$1" -mindepth 1 -maxdepth 2 \( -type d -name .git -o -type f -name .git \) | wc -l | tr -d ' '
}

resolve_mode() {
  local path="$1"
  if [[ -f "$path/.repowise-workspace.yaml" ]]; then
    printf 'workspace'
    return 0
  fi

  if is_git_repo "$path"; then
    printf 'repo'
    return 0
  fi

  if [[ "$(workspace_repo_count "$path")" -ge 2 ]]; then
    printf 'workspace'
    return 0
  fi

  fail "Path is neither a git repo nor a detectable multi-repo workspace: $path"
}

print_provider_hint() {
  cat <<'EOF'

Repowise provider note:
- default helper mode uses `--index-only`, so API keys are not required
- for wiki/doc generation, re-run with `--with-docs` after configuring an LLM provider
- common provider env vars include `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`
EOF
}

main() {
  local abs_target
  local mode
  local init_args=()

  parse_args "$@"

  if ! command_exists repowise && [[ $DRY_RUN -ne 1 ]]; then
    fail "repowise is not installed."
  fi
  command_exists git || fail "git is required."

  abs_target="$(cd "$TARGET_PATH" 2>/dev/null && pwd)" || fail "Cannot access path: $TARGET_PATH"
  mode="$(resolve_mode "$abs_target")"

  if [[ $WITH_DOCS -eq 0 ]]; then
    init_args+=(--index-only)
  fi

  log "Target: $abs_target"
  log "Detected mode: $mode"

  if [[ "$mode" == "workspace" ]]; then
    run_cmd "Initialize Repowise workspace" bash -lc "cd \"$abs_target\" && repowise init . ${init_args[*]}"
    run_cmd "Install Repowise workspace hook" bash -lc "cd \"$abs_target\" && repowise hook install --workspace"
    run_cmd "Run Repowise workspace doctor" bash -lc "cd \"$abs_target\" && repowise doctor ."
    run_cmd "Show Repowise workspace status" bash -lc "cd \"$abs_target\" && repowise status ."
  else
    run_cmd "Initialize Repowise repo" bash -lc "cd \"$abs_target\" && repowise init . ${init_args[*]}"
    run_cmd "Install Repowise repo hook" bash -lc "cd \"$abs_target\" && repowise hook install"
    run_cmd "Run Repowise repo doctor" bash -lc "cd \"$abs_target\" && repowise doctor ."
    run_cmd "Show Repowise repo status" bash -lc "cd \"$abs_target\" && repowise status ."
  fi

  print_provider_hint
}

main "$@"
