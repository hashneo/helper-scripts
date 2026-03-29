#!/usr/bin/env bash

set -euo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
INVOCATION_DIR="$(pwd)"
GATEWAY_ROOT="${GATEWAY_ROOT:-$HOME/Development/github/hashicorp/a2a/gateway}"
ROOT_DIR="$GATEWAY_ROOT"
MAIN_SCRIPT="${MAIN_SCRIPT:-$HELPER_DIR/run-opencode-beads-loop.sh}"
LOG_ROOT_RAW="${OPENCODE_LOG_ROOT:-$INVOCATION_DIR/.tmp}"
LOG_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$LOG_ROOT_RAW")"
ISSUE_ID="${1:-}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"
RECOVERY_STEP_INCREMENT="${RECOVERY_STEP_INCREMENT:-15}"
MAX_PATCH_ROUNDS="${MAX_PATCH_ROUNDS:-5}"
RUN_TIMESTAMP=""
HISTORY_DIR=""
LOG_PATH=""
ANALYSIS_LOG_PATH=""

usage() {
	cat <<EOF
Usage:
  ${SCRIPT_NAME} <issue-id> [-- <extra run-opencode-beads-loop args>]

Description:
  Wrapper eval loop that (against GATEWAY_ROOT=${ROOT_DIR}) using
  helper script ${MAIN_SCRIPT}:
  1) Ensures gateway repository is on main before each eval round
  2) Runs run-opencode-beads-loop once with --exit-after-loop and logs output
  3) Invokes opencode to inspect the log and patch prompts in ${MAIN_SCRIPT}
  4) Repeats eval rounds until clean+complete or max rounds reached

Environment:
  MAX_PATCH_ROUNDS=${MAX_PATCH_ROUNDS}
  OPENCODE_LOG_ROOT=${LOG_ROOT}

Logs:
  Latest loop log: 
    ${LOG_ROOT}/opencode-loop-<issue>.log
  Historical logs per wrapper run:
    ${LOG_ROOT}/opencode-loop-history/<issue>/<timestamp>/
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
		printf 'Switching gateway repo from %s to main...\n' "$branch"
		(cd "$ROOT_DIR" && git checkout main >/dev/null 2>&1) || fail "Unable to switch to main from ${branch}; ensure working tree is clean"
		branch="$(cd "$ROOT_DIR" && git branch --show-current)"
		[[ "$branch" == "main" ]] || fail "Expected to be on main but still on ${branch}"
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
	local round="$2"
	shift 2
	local cmd_status=0
	local round_log_path
	local round_analysis_log_path

	LOG_PATH="$LOG_ROOT/opencode-loop-${issue_id}.log"
	ANALYSIS_LOG_PATH="$LOG_ROOT/opencode-loop-${issue_id}.analysis.log"
	round_log_path="$HISTORY_DIR/opencode-loop-${issue_id}-round-${round}.log"
	round_analysis_log_path="$HISTORY_DIR/opencode-loop-${issue_id}-round-${round}.analysis.log"
	mkdir -p "$LOG_ROOT"

	set +e
	(cd "$ROOT_DIR" && GATEWAY_ROOT="$ROOT_DIR" OPENCODE_LOG_ROOT="$LOG_ROOT" "$MAIN_SCRIPT" --exit-after-loop --max-recovery-attempts "$MAX_RECOVERY_ATTEMPTS" --recovery-step-increment "$RECOVERY_STEP_INCREMENT" "$issue_id" "$@") 2>&1 | tee "$LOG_PATH"
	cmd_status=${PIPESTATUS[0]}
	set -e

	cp "$LOG_PATH" "$ANALYSIS_LOG_PATH"
	cp "$LOG_PATH" "$round_log_path"
	cp "$LOG_PATH" "$round_analysis_log_path"

	printf 'Saved round %d loop log: %s\n' "$round" "$round_log_path"
	return "$cmd_status"
}

build_patch_prompt() {
	local issue_id="$1"
	local evidence="$2"
	local hint_line="$3"
	cat <<EOF
You are tuning run-opencode-beads-loop.sh in the current working directory using log evidence.

Context:
- Gateway repository: ${ROOT_DIR}
- Helper script directory: ${HELPER_DIR}
- Issue: ${issue_id}
- Latest evidence (wrapper extracted from loop log):
${evidence}

Primary blocker hint:
${hint_line}

Goals (strict order):
1) First try to fix workflow quality by improving prompt instructions in build_prompt/build_recovery_prompt.
2) Only if prompt improvements are insufficient, make minimal script logic changes.
3) Keep changes local to run-opencode-beads-loop.sh unless absolutely necessary.

Important constraints:
- Do not read files outside current working directory.
- Do not rely on external paths for log inspection; use the provided evidence above.

Deep-analysis requirements (mandatory):
- Do NOT skim and do NOT apply speculative patches.
- Identify at least 3 distinct failure modes from the provided evidence.
- For each failure mode, include:
  - exact evidence snippet (quoted text)
  - root cause hypothesis
  - why this causes churn/retries
  - preferred fix type (prompt change first, script change only if needed)
- If evidence is insufficient for a safe patch, state that explicitly and make no code changes.

Required actions:
- Identify top failure modes from the provided evidence.
- Patch run-opencode-beads-loop.sh accordingly (prompt-first).
- Avoid broad refactors; apply smallest effective patch.
- Run bash -n run-opencode-beads-loop.sh after patching.
- In your final response, include:
  - failure analysis (>=3 modes, each with concrete evidence)
  - what was changed (prompt vs script)
  - why this should improve next run.

Stop after applying and validating the patch. Do not run the main loop script in this step.
EOF
}

extract_log_evidence() {
	local log_path="$1"
	python3 - "$log_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("- log file missing")
    raise SystemExit(0)

text = path.read_text(errors="replace")
lines = text.splitlines()

patterns = [
    ("invalid_contract", r"Invalid result contract:.*"),
    ("missing_contract", r"Missing required opencode result contract block.*"),
    ("contract_failure_counter", r"OpenCode result contract failed .*"),
    ("external_directory", r"permission requested: external_directory.*"),
    ("coverage_target_missing", r"Coverage validation failed .*no coverage package targets.*"),
    ("descendant_reopen", r"Reopening descendant issue .*"),
    ("no_actionable", r"ERROR: No actionable descendants.*"),
]

print("- total_log_lines=" + str(len(lines)))

for name, patt in patterns:
    m = re.findall(patt, text)
    print(f"- {name}_count={len(m)}")

interesting = []
for line in lines:
    if re.search(r"Invalid result contract|Missing required opencode result contract block|permission requested: external_directory|Coverage validation failed|Reopening descendant issue|ERROR:", line):
        interesting.append(line)

for sample in interesting[:12]:
    print("- sample: " + sample)
PY
}

primary_blocker_hint() {
	local log_path="$1"
	python3 - "$log_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("No log available; focus on improving result contract reliability first.")
    raise SystemExit(0)

text = path.read_text(errors="replace")

checks = [
    (r"Invalid result contract: linked PR mismatch", "Linked PR mismatch in contract is causing retries; prioritize prompt updates for canonical PR reporting and note normalization."),
    (r"Missing required opencode result contract block", "Missing contract block is causing retries; prioritize strict end-of-response contract generation."),
    (r"permission requested: external_directory", "External directory access is being rejected; reinforce local-only operations and avoid out-of-repo reads."),
    (r"Coverage validation failed .*no coverage package targets", "Coverage target extraction is reopening descendants; prompt should require metadata normalization before closure."),
]

for patt, msg in checks:
    if re.search(patt, text):
        print(msg)
        raise SystemExit(0)

print("General churn detected; tighten prompt ordering and explicit CLI verification steps.")
PY
}

patch_main_script_from_log() {
	local issue_id="$1"
	local log_path="$2"
	local round="$3"
	local prompt
	local evidence
	local hint_line
	local patch_log_path
	local patch_status

	evidence="$(extract_log_evidence "$log_path")"
	hint_line="$(primary_blocker_hint "$log_path")"
	prompt="$(build_patch_prompt "$issue_id" "$evidence" "$hint_line")"
	patch_log_path="$HISTORY_DIR/opencode-patch-round-${round}.log"

	set +e
	(cd "$HELPER_DIR" && opencode run --dir "$HELPER_DIR" "$prompt") 2>&1 | tee "$patch_log_path"
	patch_status=${PIPESTATUS[0]}
	set -e

	printf 'Saved round %d patch log: %s\n' "$round" "$patch_log_path"

	return "$patch_status"
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
	local -a passthrough_args=("$@")

	[[ "$MAX_PATCH_ROUNDS" =~ ^[0-9]+$ ]] || fail "MAX_PATCH_ROUNDS must be an integer"
	((MAX_PATCH_ROUNDS > 0)) || fail "MAX_PATCH_ROUNDS must be greater than 0"

	RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
	HISTORY_DIR="$LOG_ROOT/opencode-loop-history/$ISSUE_ID/$RUN_TIMESTAMP"
	mkdir -p "$HISTORY_DIR"
	printf 'Log root directory: %s\n' "$LOG_ROOT"
	printf 'Historical logs directory: %s\n' "$HISTORY_DIR"

	local round
	for ((round = 1; round <= MAX_PATCH_ROUNDS; round++)); do
		printf '\n=== Eval round %d/%d for %s ===\n' "$round" "$MAX_PATCH_ROUNDS" "$ISSUE_ID"
		ensure_on_main

		run_one_loop "$ISSUE_ID" "$round" "${passthrough_args[@]}" || true

		if log_has_no_errors "$LOG_PATH" && issue_tree_complete "$ISSUE_ID"; then
			printf 'No loop errors detected and issue tree is complete; exiting.\n'
			exit 0
		fi

		patch_main_script_from_log "$ISSUE_ID" "$ANALYSIS_LOG_PATH" "$round"
		bash -n "$MAIN_SCRIPT"
		printf 'Patched %s based on round %d log.\n' "$MAIN_SCRIPT" "$round"

		if ! (cd "$HELPER_DIR" && git diff --quiet -- run-opencode-beads-loop.sh); then
			printf 'Patch round %d produced script changes. Continuing to next eval round.\n' "$round"
		else
			printf 'Patch round %d produced no script changes; continuing anyway.\n' "$round"
		fi
	done

	fail "Reached MAX_PATCH_ROUNDS=${MAX_PATCH_ROUNDS} without clean+complete outcome"
}

main "$@"
