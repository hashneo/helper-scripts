#!/usr/bin/env bash

set -euo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
GATEWAY_ROOT="${GATEWAY_ROOT:-$HOME/Development/github/hashicorp/a2a/gateway}"
ROOT_DIR="$GATEWAY_ROOT"
MAIN_SCRIPT="${MAIN_SCRIPT:-$HELPER_DIR/run-opencode-beads-loop.sh}"
ISSUE_ID="${1:-}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"
RECOVERY_STEP_INCREMENT="${RECOVERY_STEP_INCREMENT:-15}"
LOG_PATH=""
ANALYSIS_LOG_PATH=""

usage() {
	cat <<EOF
Usage:
  ${SCRIPT_NAME} <issue-id> [-- <extra run-opencode-beads-loop args>]

Description:
  Wrapper eval loop that (against GATEWAY_ROOT=${ROOT_DIR}) using
  helper script ${MAIN_SCRIPT}:
  1) Ensures repository is on main
  2) Runs run-opencode-beads-loop once with --exit-after-loop and logs output
  3) Invokes opencode to inspect the log and patch prompts in ${MAIN_SCRIPT}
  4) Exits when logs indicate no issues and issue tree is complete
EOF
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ensure_on_main() {
	local branch
	branch="$(cd "$ROOT_DIR" && git branch --show-current)"
	if [[ "$branch" != "main" ]]; then
		fail "This wrapper requires branch main; current branch is ${branch}"
	fi
}

issue_tree_complete() {
	local issue_id="$1"
	(cd "$ROOT_DIR" && bd show "$issue_id" --json) | python3 -c '
import json
import sys

data = json.load(sys.stdin)
obj = data[0] if isinstance(data, list) else data

if obj.get("status") != "closed":
    raise SystemExit(1)

children = [d for d in obj.get("dependents", []) if d.get("dependency_type") == "parent-child"]
if any((c.get("status") != "closed") for c in children):
    raise SystemExit(1)

raise SystemExit(0)
'
}

log_has_no_errors() {
	local log_path="$1"
	if [[ ! -f "$log_path" ]]; then
		return 1
	fi

	if (cd "$ROOT_DIR" && grep -E "ERROR:|Invalid result contract|Missing required opencode result contract block|opencode failed for|external_directory|unbound variable" "$log_path" >/dev/null 2>&1); then
		return 1
	fi

	return 0
}

run_one_loop() {
	local issue_id="$1"
	shift
	LOG_PATH="$ROOT_DIR/.tmp/opencode-loop-${issue_id}.log"
	ANALYSIS_LOG_PATH="$HELPER_DIR/.tmp/opencode-loop-${issue_id}.log"
	mkdir -p "$ROOT_DIR/.tmp"
	mkdir -p "$HELPER_DIR/.tmp"

	(cd "$ROOT_DIR" && GATEWAY_ROOT="$ROOT_DIR" "$MAIN_SCRIPT" --exit-after-loop --max-recovery-attempts "$MAX_RECOVERY_ATTEMPTS" --recovery-step-increment "$RECOVERY_STEP_INCREMENT" "$issue_id" "$@") 2>&1 | tee "$LOG_PATH"
	cp "$LOG_PATH" "$ANALYSIS_LOG_PATH"
}

build_patch_prompt() {
	local issue_id="$1"
	local log_path="$2"
	cat <<EOF
You are tuning run-opencode-beads-loop.sh in the current working directory using log evidence.

Context:
- Gateway repository: ${ROOT_DIR}
- Helper script directory: ${HELPER_DIR}
- Issue: ${issue_id}
- Log file: ${log_path}

Goals (strict order):
1) First try to fix workflow quality by improving prompt instructions in build_prompt/build_recovery_prompt.
2) Only if prompt improvements are insufficient, make minimal script logic changes.
3) Keep changes local to run-opencode-beads-loop.sh unless absolutely necessary.

Required actions:
- Read ${log_path} and identify top failure modes from the latest run.
- Patch run-opencode-beads-loop.sh accordingly (prompt-first).
- Avoid broad refactors; apply smallest effective patch.
- Run bash -n run-opencode-beads-loop.sh after patching.
- In your final response, include:
  - what failed (with concrete log evidence)
  - what was changed (prompt vs script)
  - why this should improve next run.

Stop after applying and validating the patch. Do not run the main loop script in this step.
EOF
}

patch_main_script_from_log() {
	local issue_id="$1"
	local log_path="$2"
	local prompt

	prompt="$(build_patch_prompt "$issue_id" "$log_path")"
	(cd "$HELPER_DIR" && opencode run --dir "$HELPER_DIR" "$prompt")
}

main() {
	[[ -n "$ISSUE_ID" ]] || {
		usage
		exit 1
	}

	if [[ "$ISSUE_ID" == "-h" || "$ISSUE_ID" == "--help" ]]; then
		usage
		exit 0
	fi

	require_command bd
	require_command opencode
	require_command python3
	require_command git
	[[ -x "$MAIN_SCRIPT" ]] || fail "Main helper script not found or not executable: $MAIN_SCRIPT"

	ensure_on_main

	# Pass through optional extra args after --
	shift || true
	if [[ "${1:-}" == "--" ]]; then
		shift
	fi

	run_one_loop "$ISSUE_ID" "$@" || true

	if log_has_no_errors "$LOG_PATH" && issue_tree_complete "$ISSUE_ID"; then
		printf 'No loop errors detected and issue tree is complete; exiting.\n'
		exit 0
	fi

	patch_main_script_from_log "$ISSUE_ID" "$ANALYSIS_LOG_PATH"

	printf 'Patched scripts/run-opencode-beads-loop.sh based on log analysis. Re-run %s %s to iterate.\n' "$SCRIPT_NAME" "$ISSUE_ID"
}

main "$@"
