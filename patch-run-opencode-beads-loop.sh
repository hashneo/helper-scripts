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
  1) Runs run-opencode-beads-loop once with --exit-after-loop and logs output
  2) Invokes opencode to inspect the log and patch prompts in ${MAIN_SCRIPT}
  3) Repeats eval rounds until clean+complete or max rounds reached

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

file_sha256() {
	local target="$1"
	python3 - "$target" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("")
    raise SystemExit(0)

print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
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
	local cycle_reason="$4"
	local cycle_signature="$5"
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

Cycle gate context (from wrapper analysis):
- cycle_reason=${cycle_reason}
- cycle_signature=${cycle_signature}

Goals (strict order):
1) Decide whether any patch is needed at all.
2) If needed, fix exactly one repeated root-cause failure pattern from the evidence.
3) Keep changes minimal, local, and surgical; avoid broad prompt rewrites.
4) Keep changes local to run-opencode-beads-loop.sh unless absolutely necessary.

Important constraints:
- Do not read files outside current working directory.
- Do not rely on external paths for log inspection; use the provided evidence above.
- Do not execute shell commands in this patch step.
- Do not run tests, go commands, bd commands, run-opencode-beads-loop.sh, or any other workflow command.
- Allowed actions in this patch step: inspect files and apply minimal edits only.
- Git operations are strictly forbidden in this patch step.
- Do not run any git command (including status/diff/log/commit/checkout/branch/merge/rebase/stash/pull/push).
- Do not run gh commands.
- If your default workflow would run repository-inspection commands, skip them and continue with file-only analysis/edits.
- It is valid and preferred to make no code changes when evidence does not show a repeated/stuck cycle.
- Do not rewrite large instruction blocks just to rephrase text.

Deep-analysis requirements (mandatory):
- Do NOT skim and do NOT apply speculative patches.
- Identify one primary repeated failure mode and at most two secondary modes.
- Prefer deterministic bug fixes over prompt churn.
- If the observed issue is not a repeated cycle, return NO_CHANGE_NEEDED and make no edits.

Required actions:
- Decide patch/no-patch first and state decision clearly.
- If patching, touch only run-opencode-beads-loop.sh and keep edits small.
- Patch size limits: at most 2 focused hunks, and avoid mass rewrites.
- If no patch needed, output NO_CHANGE_NEEDED with one-sentence rationale.
- In your final response, include:
  - decision (patched or no-change)
  - repeated failure evidence
  - exact minimal change made (if any)
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
    ("coverage_uncomputable", r"STEP 3 FAIL: coverage target .*uncomputable.*"),
    ("coverage_unable_compute", r"Coverage validation failed .*unable to compute coverage for .*"),
    ("no_go_files", r"no Go files in .*"),
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
    if re.search(r"Invalid result contract|Missing required opencode result contract block|permission requested: external_directory|Coverage validation failed|STEP 3 FAIL: coverage target .*uncomputable|no Go files in |SHORT_CIRCUIT_TO_STEP6 reason=.*coverage|Reopening descendant issue|ERROR:", line):
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
    (r"STEP 3 FAIL: coverage target .*uncomputable|no Go files in ", "Coverage target is uncomputable (no Go files at selected package root); prioritize script fixes for target normalization to computable package patterns (for example ./internal/cli/... instead of ./internal/cli) before any contract-churn prompt tuning."),
    (r"Coverage validation failed .*unable to compute coverage for ", "Coverage computation is failing on selected package target; prioritize script fixes in coverage target normalization/preflight before prompt-only changes."),
    (r"Coverage validation failed .*no coverage package targets", "Coverage target extraction is missing explicit package targets; prioritize metadata normalization and extraction logic fixes before prompt tuning."),
    (r"Invalid result contract: linked PR mismatch", "Linked PR mismatch in contract is causing retries; prioritize prompt updates for canonical PR reporting and note normalization."),
    (r"permission requested: external_directory", "External directory access is being rejected; reinforce local-only operations and avoid out-of-repo reads."),
    (r"Missing required opencode result contract block", "Missing contract block is causing retries; prioritize strict end-of-response contract generation after root-cause blockers are addressed."),
]

for patt, msg in checks:
    if re.search(patt, text):
        print(msg)
        raise SystemExit(0)

print("General churn detected; tighten prompt ordering and explicit CLI verification steps.")
PY
}

analyze_patch_need() {
	local log_path="$1"
	python3 - "$log_path" <<'PY'
import collections
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("false\tmissing-log\tlog_missing")
    raise SystemExit(0)

text = path.read_text(errors="replace")

triage_lines = re.findall(r"TRIAGE_ROOT_CAUSE:?\s*(.*)", text)
triage_keys = []
for raw in triage_lines:
    line = " ".join(raw.strip().split())
    if not line:
        continue
    lowered = line.lower()
    if "missing required opencode result contract block" in lowered:
        triage_keys.append("missing_contract")
    elif "no go files" in lowered or "uncomputable" in lowered or "unable to compute coverage" in lowered:
        triage_keys.append("coverage_uncomputable")
    elif "coverage validation failed" in lowered or "coverage gate failed" in lowered:
        triage_keys.append("coverage_threshold")
    elif "step limit" in lowered or "max steps" in lowered:
        triage_keys.append("step_budget")
    else:
        triage_keys.append(line[:80])

top_triage = "none"
top_triage_count = 0
if triage_keys:
    top_triage, top_triage_count = collections.Counter(triage_keys).most_common(1)[0]

missing_contract = len(re.findall(r"Missing required opencode result contract block", text))
coverage_uncomputable = len(re.findall(r"no Go files in |unable to compute coverage for|coverage target .*uncomputable", text))
coverage_threshold = len(re.findall(r"Coverage validation failed .*<\s*[0-9]+%|Coverage gate failed .*<\s*[0-9]+", text))
syntax_error = len(re.findall(r"SyntaxError:", text))
tool_aborted = len(re.findall(r"Tool execution aborted", text))
max_steps = len(re.findall(r"MAX_STEPS_REACHED|Maximum steps for this agent run have been reached", text))
child_fail = len(re.findall(r"ERROR: opencode failed for child issue", text))
reopen_parse_bug = bool(re.search(r'no issue found matching "Issue .*reopening\.', text))

cycle = False
reason = "no_persistent_cycle"

if reopen_parse_bug:
    cycle = True
    reason = "deterministic_reopen_parse_bug"
elif top_triage_count >= 3:
    cycle = True
    reason = f"repeated_triage:{top_triage}:{top_triage_count}"
elif missing_contract >= 2:
    cycle = True
    reason = f"missing_contract_repeats:{missing_contract}"
elif coverage_uncomputable >= 2:
    cycle = True
    reason = f"coverage_uncomputable_repeats:{coverage_uncomputable}"
elif syntax_error >= 2:
    cycle = True
    reason = f"syntax_error_repeats:{syntax_error}"
elif tool_aborted >= 2:
    cycle = True
    reason = f"tool_abort_repeats:{tool_aborted}"
elif max_steps >= 2:
    cycle = True
    reason = f"step_budget_repeats:{max_steps}"
elif child_fail >= 2 and top_triage_count >= 2:
    cycle = True
    reason = f"child_failure_cycle:{child_fail}:{top_triage}"

signature = (
    f"triage={top_triage};"
    f"triage_count={top_triage_count};"
    f"missing_contract={missing_contract};"
    f"coverage_uncomputable={coverage_uncomputable};"
    f"coverage_threshold={coverage_threshold};"
    f"syntax_error={syntax_error};"
    f"tool_aborted={tool_aborted};"
    f"max_steps={max_steps};"
    f"child_fail={child_fail};"
    f"reopen_bug={1 if reopen_parse_bug else 0}"
)

print(("true" if cycle else "false") + "\t" + signature + "\t" + reason)
PY
}

patch_main_script_from_log() {
	local issue_id="$1"
	local log_path="$2"
	local round="$3"
	local cycle_reason="$4"
	local cycle_signature="$5"
	local prompt
	local evidence
	local hint_line
	local patch_log_path
	local patch_status
	local hash_before
	local hash_after

	evidence="$(extract_log_evidence "$log_path")"
	hint_line="$(primary_blocker_hint "$log_path")"
	prompt="$(build_patch_prompt "$issue_id" "$evidence" "$hint_line" "$cycle_reason" "$cycle_signature")"
	patch_log_path="$HISTORY_DIR/opencode-patch-round-${round}.log"
	hash_before="$(file_sha256 "$MAIN_SCRIPT")"

	set +e
	(cd "$HELPER_DIR" && opencode run --dir "$HELPER_DIR" "$prompt") 2>&1 | tee "$patch_log_path"
	patch_status=${PIPESTATUS[0]}
	set -e
	hash_after="$(file_sha256 "$MAIN_SCRIPT")"

	printf 'Saved round %d patch log: %s\n' "$round" "$patch_log_path"
	if [[ "$hash_before" == "$hash_after" ]]; then
		printf 'Round %d patch decision: no changes applied to %s (allowed).\n' "$round" "$MAIN_SCRIPT"
	else
		printf 'Round %d patch decision: updated %s with minimal edits.\n' "$round" "$MAIN_SCRIPT"
	fi

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
	[[ -x "$MAIN_SCRIPT" ]] || fail "Main helper script not found or not executable: $MAIN_SCRIPT"

	# Pass through optional extra args after --
	shift || true
	if [[ "${1:-}" == "--" ]]; then
		shift
	fi
	local -a passthrough_args=("$@")
	local last_patch_signature=""

	[[ "$MAX_PATCH_ROUNDS" =~ ^[0-9]+$ ]] || fail "MAX_PATCH_ROUNDS must be an integer"
	((MAX_PATCH_ROUNDS > 0)) || fail "MAX_PATCH_ROUNDS must be greater than 0"

	RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
	HISTORY_DIR="$LOG_ROOT/opencode-loop-history/$ISSUE_ID/$RUN_TIMESTAMP"
	mkdir -p "$HISTORY_DIR"
	printf 'Log root directory: %s\n' "$LOG_ROOT"
	printf 'Historical logs directory: %s\n' "$HISTORY_DIR"

	local round
	for ((round = 1; round <= MAX_PATCH_ROUNDS; round++)); do
		local patch_needed
		local patch_signature
		local patch_reason
		local analysis_line
		printf '\n=== Eval round %d/%d for %s ===\n' "$round" "$MAX_PATCH_ROUNDS" "$ISSUE_ID"

		run_one_loop "$ISSUE_ID" "$round" "${passthrough_args[@]}" || true

		if log_has_no_errors "$LOG_PATH" && issue_tree_complete "$ISSUE_ID"; then
			printf 'No loop errors detected and issue tree is complete; exiting.\n'
			exit 0
		fi

		analysis_line="$(analyze_patch_need "$ANALYSIS_LOG_PATH")"
		IFS=$'\t' read -r patch_needed patch_signature patch_reason <<<"$analysis_line"

		if [[ "$patch_needed" != "true" ]]; then
			printf 'Patch skipped for round %d: %s\n' "$round" "$patch_reason"
			printf 'Continuing to next eval round without prompt rewrites.\n'
			continue
		fi

		if [[ "$patch_signature" == "$last_patch_signature" ]]; then
			printf 'Patch skipped for round %d: cycle signature unchanged (%s); avoiding repeated prompt rewrites.\n' "$round" "$patch_signature"
			printf 'Continuing to next eval round.\n'
			continue
		fi

		printf 'Patch enabled for round %d: %s\n' "$round" "$patch_reason"
		patch_main_script_from_log "$ISSUE_ID" "$ANALYSIS_LOG_PATH" "$round" "$patch_reason" "$patch_signature"
		bash -n "$MAIN_SCRIPT"
		last_patch_signature="$patch_signature"
		printf 'Patched %s based on round %d log with minimal changes.\n' "$MAIN_SCRIPT" "$round"
		printf 'Continuing to next eval round.\n'
	done

	fail "Reached MAX_PATCH_ROUNDS=${MAX_PATCH_ROUNDS} without clean+complete outcome"
}

main "$@"
