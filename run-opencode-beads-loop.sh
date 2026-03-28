#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
GATEWAY_ROOT="${GATEWAY_ROOT:-$HOME/Development/github/hashicorp/a2a/gateway}"
ROOT_DIR="$GATEWAY_ROOT"

MODEL=""
AGENT=""
VARIANT=""
SANDBOX_NAME=""
OPENCODE_STEPS="${OPENCODE_STEPS:-10}"
MAX_ITERATIONS=100
MAX_RECOVERY_ATTEMPTS=2
RECOVERY_STEP_INCREMENT=10
DRY_RUN=0
SINGLE_JOB=0
EXIT_AFTER_LOOP=0
ISSUE_ID=""
OPENCODE_EXTRA_ARGS=()
MAX_STEPS_MESSAGE="Maximum steps for this agent have been reached."
CURRENT_ACTIVE_ISSUE=""
LAST_OPENCODE_LOG_FILE=""
FAILED_ISSUES_IN_RUN=()
READY_PARENT_SCOPE=""
AWAITING_MERGE_LABEL="${AWAITING_MERGE_LABEL:-awaiting-merge}"
CONTRACT_FAILURE_SKIP_THRESHOLD="${CONTRACT_FAILURE_SKIP_THRESHOLD:-3}"
LOCKS_BASE_DIR="${OPENCODE_BEADS_LOCKS_DIR:-$HOME/.tmp/opencode-beads-locks}"
LOCKS_DIR=""
CURRENT_ISSUE_LOCK_DIR=""
RUN_SNAPSHOT_HEAD=""
RUN_SNAPSHOT_BRANCH=""
RUN_SNAPSHOT_ISSUE_STATUS=""
RUN_SNAPSHOT_PR_STATE=""

usage() {
	cat <<'EOF'
Usage:
  ${SCRIPT_NAME} [options] <issue-id> [-- <extra opencode args>]

Description:
  Runs opencode against a specific Beads issue. If the issue has parent-child
  dependents, the script repeatedly selects the next child task to process and
	  exits successfully only after all direct child tasks are closed and the
	  parent issue itself is resolved.

Options:
  --model <provider/model>   Pass a model through to opencode
  --agent <name>             Pass an agent through to opencode
  --variant <name>           Pass a model variant through to opencode
  --steps <count>            Set opencode agentic iterations (default: 10)
  --sandbox-name <name>      Run opencode inside an existing Docker sandbox
                              using: docker sandbox run <name> -- -c "<cmd>"
  --max-iterations <count>   Stop after this many loop iterations (default: 100)
  --max-recovery-attempts <n>
                              Retry a failed opencode run this many times with a
                              focused recovery prompt (default: 2)
  --recovery-step-increment <n>
                             Increase step budget by this amount on each
                             recovery attempt (default: 10)
  --dry-run                  Print the selected issue and opencode command only
  --single-job               Process only one actionable descendant, then exit
  --exit-after-loop          Run one loop cycle and exit (wrapper-friendly)
  -h, --help                 Show this help text

Examples:
  ${SCRIPT_NAME} gateway-xgj8
  ${SCRIPT_NAME} --model openai/gpt-5 gateway-xrnd
  ${SCRIPT_NAME} --sandbox-name opencode-gateway gateway-xgj8
  ${SCRIPT_NAME} gateway-xgj8 -- --thinking
EOF
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '%s\n' "$*"
}

log_stderr() {
	printf '%s\n' "$*" >&2
}

repo_lock_scope() {
	local remote_url

	remote_url="$(cd "$ROOT_DIR" && git remote get-url origin 2>/dev/null || true)"
	if [[ -z "$remote_url" ]]; then
		remote_url="$ROOT_DIR"
	fi

	python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$remote_url"
}

init_locks_dir() {
	local scope

	scope="$(repo_lock_scope)"
	LOCKS_DIR="$LOCKS_BASE_DIR/$scope"
}

issue_locked_locally() {
	local issue_id="$1"
	local lock_dir="$LOCKS_DIR/${issue_id}.lock"
	local pid_file="$lock_dir/pid"
	local lock_pid=""

	if [[ ! -d "$lock_dir" ]]; then
		return 1
	fi

	if [[ -f "$pid_file" ]]; then
		lock_pid="$(python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.read_text().strip() if p.exists() else "")' "$pid_file")"
		if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" >/dev/null 2>&1; then
			return 0
		fi
	fi

	rm -rf "$lock_dir"
	return 1
}

acquire_issue_lock() {
	local issue_id="$1"
	local lock_dir="$LOCKS_DIR/${issue_id}.lock"
	local pid_file="$lock_dir/pid"

	mkdir -p "$LOCKS_DIR"
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"$pid_file"
		CURRENT_ISSUE_LOCK_DIR="$lock_dir"
		return 0
	fi

	if issue_locked_locally "$issue_id"; then
		return 1
	fi

	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"$pid_file"
		CURRENT_ISSUE_LOCK_DIR="$lock_dir"
		return 0
	fi

	return 1
}

release_issue_lock() {
	if [[ -n "$CURRENT_ISSUE_LOCK_DIR" && -d "$CURRENT_ISSUE_LOCK_DIR" ]]; then
		rm -rf "$CURRENT_ISSUE_LOCK_DIR"
	fi
	CURRENT_ISSUE_LOCK_DIR=""
}

clear_current_issue_context() {
	release_issue_lock
	CURRENT_ACTIVE_ISSUE=""
	LAST_OPENCODE_LOG_FILE=""
	RUN_SNAPSHOT_HEAD=""
	RUN_SNAPSHOT_BRANCH=""
	RUN_SNAPSHOT_ISSUE_STATUS=""
	RUN_SNAPSHOT_PR_STATE=""
}

issue_contract_fail_count_file() {
	local issue_id="$1"
	printf '%s/.tmp/opencode-contract-fail-%s.count\n' "$ROOT_DIR" "$issue_id"
}

reset_issue_contract_fail_count() {
	local issue_id="$1"
	local count_file
	count_file="$(issue_contract_fail_count_file "$issue_id")"
	rm -f "$count_file"
}

increment_issue_contract_fail_count() {
	local issue_id="$1"
	local count_file
	local current=0

	count_file="$(issue_contract_fail_count_file "$issue_id")"
	mkdir -p "$ROOT_DIR/.tmp"
	if [[ -f "$count_file" ]]; then
		current="$(python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); t=p.read_text().strip() if p.exists() else "0"; print(t if t.isdigit() else "0")' "$count_file")"
	fi
	current=$((current + 1))
	printf '%s\n' "$current" >"$count_file"
	printf '%s\n' "$current"
}

maybe_skip_issue_after_contract_failures() {
	local issue_id="$1"
	local reason="$2"
	local count

	count="$(increment_issue_contract_fail_count "$issue_id")"
	if [[ "$count" =~ ^[0-9]+$ ]] && ((count >= CONTRACT_FAILURE_SKIP_THRESHOLD)); then
		log_stderr "Contract validation failed ${count} times for ${issue_id}; adding Beads comment and skipping this issue for now"
		(cd "$ROOT_DIR" && bd comments add "$issue_id" "OpenCode result contract failed ${count} consecutive runs. Reason: ${reason}. Skipping this issue once to avoid hot-looping." --json >/dev/null 2>&1 || true)
		return 0
	fi

	return 1
}

record_run_snapshot() {
	local issue_id="$1"

	RUN_SNAPSHOT_HEAD="$(cd "$ROOT_DIR" && git rev-parse HEAD 2>/dev/null || true)"
	RUN_SNAPSHOT_BRANCH="$(cd "$ROOT_DIR" && git branch --show-current 2>/dev/null || true)"
	RUN_SNAPSHOT_ISSUE_STATUS="$(issue_status "$issue_id")"
	if issue_has_linked_pr "$issue_id"; then
		RUN_SNAPSHOT_PR_STATE="$(pr_state_for_issue "$issue_id" || true)"
	else
		RUN_SNAPSHOT_PR_STATE="NONE"
	fi
}

is_noop_completed_result() {
	local issue_id="$1"
	local status
	local current_head
	local current_branch
	local current_pr_state
	local contract_status

	contract_status="$(opencode_result_field status || true)"
	if [[ "$contract_status" != "completed" ]]; then
		return 1
	fi

	status="$(issue_status "$issue_id")"
	current_head="$(cd "$ROOT_DIR" && git rev-parse HEAD 2>/dev/null || true)"
	current_branch="$(cd "$ROOT_DIR" && git branch --show-current 2>/dev/null || true)"
	if issue_has_linked_pr "$issue_id"; then
		current_pr_state="$(pr_state_for_issue "$issue_id" || true)"
	else
		current_pr_state="NONE"
	fi

	if [[ "$status" == "$RUN_SNAPSHOT_ISSUE_STATUS" && "$current_head" == "$RUN_SNAPSHOT_HEAD" && "$current_branch" == "$RUN_SNAPSHOT_BRANCH" && "$current_pr_state" == "$RUN_SNAPSHOT_PR_STATE" ]]; then
		return 0
	fi

	return 1
}

emit_attempt_telemetry() {
	local issue_id="$1"
	local attempt_type="$2"
	local result="$3"
	local duration_ms="$4"
	local pr_number
	local contract_status
	local merged
	local beads_closed
	local issue_status_now

	pr_number="$(opencode_result_field pr_number || true)"
	contract_status="$(opencode_result_field status || true)"
	merged="$(opencode_result_field merged || true)"
	beads_closed="$(opencode_result_field beads_closed || true)"
	issue_status_now="$(issue_status "$issue_id" 2>/dev/null || true)"

	printf '{"event":"opencode_attempt","issue_id":"%s","attempt_type":"%s","result":"%s","contract_status":"%s","pr_number":"%s","merged":"%s","beads_closed":"%s","issue_status":"%s","duration_ms":%s}\n' \
		"$issue_id" "$attempt_type" "$result" "${contract_status:-unknown}" "${pr_number:-none}" "${merged:-false}" "${beads_closed:-false}" "${issue_status_now:-unknown}" "$duration_ms"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			[[ $# -ge 2 ]] || fail "--model requires a value"
			MODEL="$2"
			shift 2
			;;
		--agent)
			[[ $# -ge 2 ]] || fail "--agent requires a value"
			AGENT="$2"
			shift 2
			;;
		--variant)
			[[ $# -ge 2 ]] || fail "--variant requires a value"
			VARIANT="$2"
			shift 2
			;;
		--steps)
			[[ $# -ge 2 ]] || fail "--steps requires a value"
			OPENCODE_STEPS="$2"
			shift 2
			;;
		--sandbox-name)
			[[ $# -ge 2 ]] || fail "--sandbox-name requires a value"
			SANDBOX_NAME="$2"
			shift 2
			;;
		--max-iterations)
			[[ $# -ge 2 ]] || fail "--max-iterations requires a value"
			MAX_ITERATIONS="$2"
			shift 2
			;;
		--max-recovery-attempts)
			[[ $# -ge 2 ]] || fail "--max-recovery-attempts requires a value"
			MAX_RECOVERY_ATTEMPTS="$2"
			shift 2
			;;
		--recovery-step-increment)
			[[ $# -ge 2 ]] || fail "--recovery-step-increment requires a value"
			RECOVERY_STEP_INCREMENT="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--single-job)
			SINGLE_JOB=1
			shift
			;;
		--exit-after-loop)
			EXIT_AFTER_LOOP=1
			SINGLE_JOB=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			OPENCODE_EXTRA_ARGS=("$@")
			break
			;;
		-*)
			fail "Unknown option: $1"
			;;
		*)
			if [[ -z "$ISSUE_ID" ]]; then
				ISSUE_ID="$1"
				shift
			else
				fail "Unexpected argument: $1"
			fi
			;;
		esac
	done

	[[ -n "$ISSUE_ID" ]] || fail "An issue id is required"
	[[ "$OPENCODE_STEPS" =~ ^[0-9]+$ ]] || fail "--steps must be an integer"
	[[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || fail "--max-iterations must be an integer"
	[[ "$MAX_RECOVERY_ATTEMPTS" =~ ^[0-9]+$ ]] || fail "--max-recovery-attempts must be an integer"
	[[ "$RECOVERY_STEP_INCREMENT" =~ ^[0-9]+$ ]] || fail "--recovery-step-increment must be an integer"
}

build_opencode_config_content() {
	local steps="${1:-$OPENCODE_STEPS}"
	python3 - "$steps" <<'PY'
import json
import os
import sys

steps = int(sys.argv[1])
raw = os.environ.get("OPENCODE_CONFIG_CONTENT", "")

if raw:
	try:
		config = json.loads(raw)
	except json.JSONDecodeError as exc:
		raise SystemExit(f"Invalid OPENCODE_CONFIG_CONTENT JSON: {exc}")
else:
	config = {}

agent = config.setdefault("agent", {})
for name in ("build", "general", "explore", "plan"):
	current = agent.get(name)
	if not isinstance(current, dict):
		current = {}
		agent[name] = current
	current["steps"] = steps

print(json.dumps(config, separators=(",", ":")))
PY
}

bd_show_json() {
	(cd "$ROOT_DIR" && bd show "$1" --json)
}

issue_title() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("title", ""))'
}

issue_status() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("status", ""))'
}

issue_notes() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("notes", "") or "")'
}

issue_acceptance_criteria() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("acceptance_criteria", "") or "")'
}

issue_labels() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; labels=obj.get("labels", []) or []; print("\n".join(label for label in labels if label))'
}

issue_has_label() {
	local issue_id="$1"
	local target_label="$2"

	issue_labels "$issue_id" | python3 -c 'import sys; target=sys.argv[1]; labels={line.strip() for line in sys.stdin if line.strip()}; raise SystemExit(0 if target in labels else 1)' "$target_label"
}

extract_issue_pr_number() {
	issue_notes "$1" | python3 -c '
import re
import sys

notes = sys.stdin.read()
matches = re.findall(r"PR #(\d+)", notes)
if matches:
    print(matches[-1])
'
}

issue_has_linked_pr() {
	local issue_id="$1"
	local pr_number

	pr_number="$(extract_issue_pr_number "$issue_id")"
	[[ -n "$pr_number" ]]
}

coverage_threshold_for_issue() {
	local issue_id="$1"
	local acceptance

	acceptance="$(issue_acceptance_criteria "$issue_id")"
	python3 -c '
import re
import sys

text = sys.stdin.read()
matches = re.findall(r"(?:>=|>|=)\s*([0-9]+(?:\.[0-9]+)?)\s*%", text)
if matches:
    print(matches[-1])
else:
    print("80")
' <<<"$acceptance"
}

coverage_targets_for_issue() {
	local issue_id="$1"
	local acceptance
	local title

	acceptance="$(issue_acceptance_criteria "$issue_id")"
	title="$(issue_title "$issue_id")"

	python3 -c '
import re
import sys

acceptance = sys.argv[1]
title = sys.argv[2]

targets = []
for token in re.findall(r"\./[A-Za-z0-9_./-]+", acceptance):
    if token.startswith("./") and token not in targets:
        targets.append(token)

if not targets:
    for token in re.findall(r"\b(?:internal|cmd)/[A-Za-z0-9_./-]+", acceptance + " " + title):
        candidate = "./" + token
        if candidate not in targets:
            targets.append(candidate)

for target in targets:
    print(target)
' "$acceptance" "$title"
}

package_coverage_percent() {
	local pkg="$1"
	(cd "$ROOT_DIR" && go test -count=1 -cover "$pkg" 2>/dev/null) | python3 -c '
import re
import sys

content = sys.stdin.read()
values = [float(v) for v in re.findall(r"coverage:\s*([0-9]+(?:\.[0-9]+)?)% of statements", content)]
if not values:
    raise SystemExit(1)
print(min(values))
'
}

coverage_issue_meets_threshold() {
	local issue_id="$1"
	local threshold
	local target
	local pct
	local has_targets=1

	threshold="$(coverage_threshold_for_issue "$issue_id")"

	while IFS= read -r target; do
		[[ -n "$target" ]] || continue
		has_targets=0
		pct="$(package_coverage_percent "$target" || true)"
		if [[ -z "$pct" ]]; then
			log_stderr "Coverage validation failed for ${issue_id}: unable to compute coverage for ${target}"
			return 1
		fi
		if ! python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$pct" "$threshold"; then
			log_stderr "Coverage validation failed for ${issue_id}: ${target} is ${pct}% (< ${threshold}%)"
			return 1
		fi
	done < <(coverage_targets_for_issue "$issue_id")

	if [[ "$has_targets" -eq 1 ]]; then
		log_stderr "Coverage validation failed for ${issue_id}: no coverage package targets found in acceptance criteria/title"
		return 1
	fi

	return 0
}

issue_meets_closure_criteria() {
	local issue_id="$1"
	local acceptance

	acceptance="$(issue_acceptance_criteria "$issue_id")"
	if [[ -z "$acceptance" ]]; then
		return 0
	fi

	if grep -qi "coverage" <<<"$acceptance" || grep -qi "coverage:" <<<"$(issue_title "$issue_id")"; then
		coverage_issue_meets_threshold "$issue_id"
		return $?
	fi

	return 0
}

issue_children_closure_satisfied() {
	local issue_id="$1"
	local children

	children="$(child_count "$issue_id")"
	if [[ "$children" -gt 0 ]] && ! all_children_closed "$issue_id"; then
		log_stderr "Issue ${issue_id} has open child tasks and cannot be closed yet"
		return 1
	fi

	return 0
}

issue_can_close() {
	local issue_id="$1"

	if ! issue_children_closure_satisfied "$issue_id"; then
		return 1
	fi

	if ! issue_meets_closure_criteria "$issue_id"; then
		return 1
	fi

	return 0
}

enforce_issue_closure_criteria() {
	local issue_id="$1"

	if issue_can_close "$issue_id"; then
		return 0
	fi

	log "Issue ${issue_id} was closed without meeting acceptance criteria; reopening."
	(cd "$ROOT_DIR" && bd reopen "$issue_id" --reason "Closure criteria not met" --json >/dev/null)
	return 1
}

reopen_invalid_closed_descendants() {
	local issue_id="$1"
	local child_id
	local child_status
	local reopened_total=0
	local reopened_nested=0

	while IFS= read -r child_id; do
		[[ -n "$child_id" ]] || continue

		reopened_nested="$(reopen_invalid_closed_descendants "$child_id")"
		if [[ "$reopened_nested" =~ ^[0-9]+$ ]]; then
			reopened_total=$((reopened_total + reopened_nested))
		fi

		child_status="$(issue_status "$child_id")"
		if [[ "$child_status" != "closed" ]]; then
			continue
		fi

		if issue_can_close "$child_id"; then
			continue
		fi

		log_stderr "Reopening descendant issue ${child_id}: closure criteria are not satisfied"
		(cd "$ROOT_DIR" && bd reopen "$child_id" --reason "Closure criteria not met" --json >/dev/null)
		reopened_total=$((reopened_total + 1))
	done < <(direct_child_ids "$issue_id")

	printf '%s\n' "$reopened_total"
}

current_branch_pr_number() {
	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi

	(cd "$ROOT_DIR" && gh pr view --json number --jq '.number' 2>/dev/null || true)
}

pr_state_for_issue() {
	local issue_id="$1"
	local pr_number

	pr_number="$(extract_issue_pr_number "$issue_id")"
	if [[ -z "$pr_number" ]] || ! command -v gh >/dev/null 2>&1; then
		return 1
	fi

	(cd "$ROOT_DIR" && gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || true)
}

issue_pr_is_merged() {
	local issue_id="$1"
	local pr_state

	pr_state="$(pr_state_for_issue "$issue_id")"
	[[ "$pr_state" == "MERGED" ]]
}

mark_issue_awaiting_merge() {
	local issue_id="$1"
	local status
	local pr_number
	local existing_notes
	local note

	status="$(issue_status "$issue_id")"
	if [[ "$status" == "closed" ]]; then
		return 0
	fi

	pr_number="$(current_branch_pr_number)"
	if [[ -z "$pr_number" ]]; then
		pr_number="$(extract_issue_pr_number "$issue_id")"
	fi

	existing_notes="$(issue_notes "$issue_id")"
	if [[ -n "$pr_number" ]]; then
		note="Awaiting merge for PR #${pr_number}"
	else
		note="Awaiting merge for an open PR"
	fi

	if ! grep -Fq "$note" <<<"$existing_notes"; then
		(cd "$ROOT_DIR" && bd update "$issue_id" --append-notes "$note" --json >/dev/null)
	fi

	if ! issue_has_label "$issue_id" "$AWAITING_MERGE_LABEL"; then
		(cd "$ROOT_DIR" && bd update "$issue_id" --add-label "$AWAITING_MERGE_LABEL" --json >/dev/null)
	fi

	if [[ "$status" != "blocked" ]]; then
		(cd "$ROOT_DIR" && bd update "$issue_id" --status blocked --json >/dev/null)
	fi
}

close_issue_if_pr_merged() {
	local issue_id="$1"
	local status
	local pr_number
	local pr_state
	local existing_notes
	local canonical_note

	status="$(issue_status "$issue_id")"
	if [[ "$status" == "closed" ]]; then
		return 0
	fi

	pr_number="$(extract_issue_pr_number "$issue_id")"
	if [[ -z "$pr_number" ]]; then
		return 1
	fi

	pr_state="$(pr_state_for_issue "$issue_id")"
	if [[ "$pr_state" != "MERGED" ]]; then
		return 1
	fi

	existing_notes="$(issue_notes "$issue_id")"
	canonical_note="Awaiting merge for PR #${pr_number}"
	if [[ -n "$existing_notes" ]]; then
		if ! python3 -c 'import re,sys; notes=sys.argv[1]; current=sys.argv[2]; matches=re.findall(r"Awaiting merge for PR #(\d+)", notes); raise SystemExit(0 if all(m == current for m in matches) else 1)' "$existing_notes" "$pr_number"; then
			(cd "$ROOT_DIR" && bd update "$issue_id" --append-notes "Normalized linked PR to #${pr_number} based on latest issue notes state" --json >/dev/null)
		fi
	fi

	if ! issue_can_close "$issue_id"; then
		log "PR is merged but issue ${issue_id} does not meet acceptance criteria; not closing."
		return 1
	fi

	log "PR #${pr_number} is merged; closing issue ${issue_id}."
	(cd "$ROOT_DIR" && bd close "$issue_id" --reason "PR #${pr_number} merged" --json >/dev/null)
	return 0
}

issue_pr_ready_to_merge() {
	local issue_id="$1"
	local pr_number
	local details
	local pr_state
	local is_draft
	local merge_state
	local mergeable

	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi

	pr_number="$(extract_issue_pr_number "$issue_id")"
	if [[ -z "$pr_number" ]]; then
		return 1
	fi

	details="$(cd "$ROOT_DIR" && gh pr view "$pr_number" --json state,isDraft,mergeStateStatus,mergeable --jq '[.state, (.isDraft|tostring), (.mergeStateStatus // ""), (.mergeable // "")] | @tsv' 2>/dev/null || true)"
	if [[ -z "$details" ]]; then
		return 1
	fi

	IFS=$'\t' read -r pr_state is_draft merge_state mergeable <<<"$details"

	[[ "$pr_state" == "OPEN" ]] || return 1
	[[ "$is_draft" == "false" ]] || return 1
	[[ "$mergeable" == "MERGEABLE" ]] || return 1
	[[ "$merge_state" == "CLEAN" || "$merge_state" == "HAS_HOOKS" ]] || return 1

	if ! (cd "$ROOT_DIR" && gh pr view "$pr_number" --json statusCheckRollup 2>/dev/null | python3 -c '
import json
import sys

data = json.load(sys.stdin)
checks = data.get("statusCheckRollup") or []
if not checks:
    raise SystemExit(0)

for check in checks:
    typename = check.get("__typename")
    if typename == "CheckRun":
        status = (check.get("status") or "").upper()
        conclusion = (check.get("conclusion") or "").upper()
        if status != "COMPLETED":
            raise SystemExit(1)
        if conclusion not in {"SUCCESS", "SKIPPED", "NEUTRAL"}:
            raise SystemExit(1)
    elif typename == "StatusContext":
        state = (check.get("state") or "").upper()
        if state not in {"SUCCESS", "EXPECTED"}:
            raise SystemExit(1)

raise SystemExit(0)
'); then
		return 1
	fi

	return 0
}

merge_issue_pr_if_ready() {
	return 1
}

issue_is_pr_awaiting_external_approval() {
	local issue_id="$1"
	local status
	local pr_state

	status="$(issue_status "$issue_id")"
	if [[ "$status" != "blocked" ]]; then
		return 1
	fi

	if ! issue_has_linked_pr "$issue_id"; then
		return 1
	fi

	pr_state="$(pr_state_for_issue "$issue_id")"
	if [[ "$pr_state" != "OPEN" ]]; then
		return 1
	fi

	if issue_pr_ready_to_merge "$issue_id"; then
		return 1
	fi

	return 0
}

issue_assignee() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("assignee", "") or "")'
}

issue_owner() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("owner", "") or "")'
}

identity_matches_issue_claim() {
	local issue_id="$1"
	local assignee
	local owner
	local git_name
	local git_email

	assignee="$(issue_assignee "$issue_id")"
	owner="$(issue_owner "$issue_id")"
	git_name="$(cd "$ROOT_DIR" && git config --get user.name 2>/dev/null || true)"
	git_email="$(cd "$ROOT_DIR" && git config --get user.email 2>/dev/null || true)"

	if [[ -n "$assignee" && -n "$git_name" && "$assignee" == "$git_name" ]]; then
		return 0
	fi

	if [[ -n "$owner" && -n "$git_email" && "$owner" == "$git_email" ]]; then
		return 0
	fi

	if [[ -n "$assignee" && -n "${USER:-}" && "$assignee" == "${USER}" ]]; then
		return 0
	fi

	return 1
}

ensure_issue_claimed() {
	local issue_id="$1"
	local claim_status
	local claim_err
	local err_file

	mkdir -p "$ROOT_DIR/.tmp"
	err_file="$ROOT_DIR/.tmp/bd-claim-${issue_id}.err"

	set +e
	(cd "$ROOT_DIR" && bd update "$issue_id" --claim --json >/dev/null 2>"$err_file")
	claim_status=$?
	set -e

	if [[ "$claim_status" -eq 0 ]]; then
		return 0
	fi

	claim_err="$(python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.read_text() if p.exists() else "")' "$err_file")"
	rm -f "$err_file"

	if [[ "$claim_err" == *"already claimed by"* ]] && identity_matches_issue_claim "$issue_id"; then
		log "Issue ${issue_id} is already claimed by the current identity; continuing."
		return 0
	fi

	log "Unable to claim issue ${issue_id}: ${claim_err}"
	return 1
}

issue_parent() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; print(obj.get("parent", ""))'
}

child_count() {
	bd_show_json "$1" | python3 -c 'import json,sys; data=json.load(sys.stdin); obj=data[0] if isinstance(data,list) else data; dependents=obj.get("dependents", []); print(sum(1 for dep in dependents if dep.get("dependency_type") == "parent-child"))'
}

children_report() {
	bd_show_json "$1" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
obj = data[0] if isinstance(data, list) else data
children = [dep for dep in obj.get("dependents", []) if dep.get("dependency_type") == "parent-child"]
for child in children:
    print("{}\t{}\t{}".format(
        child.get("id", ""),
        child.get("status", ""),
        child.get("title", ""),
    ))
'
}

direct_child_ids() {
	bd_show_json "$1" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
obj = data[0] if isinstance(data, list) else data
children = [dep for dep in obj.get("dependents", []) if dep.get("dependency_type") == "parent-child"]
for child in children:
    cid = child.get("id", "")
    if cid:
        print(cid)
'
}

issue_is_ready() {
	local issue_id="$1"
	local -a ready_cmd=(bd ready --json --limit 100)
	if [[ -n "$READY_PARENT_SCOPE" ]]; then
		ready_cmd=(bd ready --parent "$READY_PARENT_SCOPE" --json --limit 100)
	fi
	(cd "$ROOT_DIR" && "${ready_cmd[@]}") | python3 -c 'import json,sys; target=sys.argv[1]; data=json.load(sys.stdin); raise SystemExit(0 if any(item.get("id") == target for item in data) else 1)' "$issue_id"
}

issue_in_failed_skiplist() {
	local issue_id="$1"
	local failed
	for failed in "${FAILED_ISSUES_IN_RUN[@]}"; do
		if [[ "$failed" == "$issue_id" ]]; then
			return 0
		fi
	done
	return 1
}

all_children_closed() {
	bd_show_json "$1" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
obj = data[0] if isinstance(data, list) else data
children = [dep for dep in obj.get("dependents", []) if dep.get("dependency_type") == "parent-child"]
sys.exit(0 if children and all(child.get("status") == "closed" for child in children) else 1)
'
}

has_children_blocked_on_external_approval() {
	local issue_id="$1"
	local child_id
	local status
	local has_unclosed=1

	while IFS= read -r child_id; do
		[[ -n "$child_id" ]] || continue
		status="$(issue_status "$child_id")"
		if [[ "$status" == "closed" ]]; then
			continue
		fi
		has_unclosed=0
		if ! issue_is_pr_awaiting_external_approval "$child_id"; then
			return 1
		fi
	done < <(direct_child_ids "$issue_id")

	[[ "$has_unclosed" -eq 0 ]]
}

has_unclosed_children() {
	bd_show_json "$1" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
obj = data[0] if isinstance(data, list) else data
children = [dep for dep in obj.get("dependents", []) if dep.get("dependency_type") == "parent-child"]
sys.exit(0 if any(child.get("status") != "closed" for child in children) else 1)
'
}

choose_next_child() {
	local target_json
	local ready_json
	local failed_json="[]"
	local -a ready_cmd=(bd ready --json --limit 100)

	target_json="$(bd_show_json "$1")"
	if [[ -n "$READY_PARENT_SCOPE" ]]; then
		ready_cmd=(bd ready --parent "$READY_PARENT_SCOPE" --json --limit 100)
	fi
	ready_json="$(cd "$ROOT_DIR" && "${ready_cmd[@]}")"
	if [[ ${#FAILED_ISSUES_IN_RUN[@]} -gt 0 ]]; then
		failed_json="$(
			python3 - "${FAILED_ISSUES_IN_RUN[@]}" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
		)"
	fi

	TARGET_JSON="$target_json" READY_JSON="$ready_json" FAILED_JSON="$failed_json" python3 -c '
import json
import os

target = json.loads(os.environ["TARGET_JSON"])
target_obj = target[0] if isinstance(target, list) else target
ready = json.loads(os.environ["READY_JSON"])
failed = set(json.loads(os.environ["FAILED_JSON"]))

children = [dep for dep in target_obj.get("dependents", []) if dep.get("dependency_type") == "parent-child"]
open_children = [child for child in children if child.get("status") != "closed" and child.get("id") not in failed]
ready_ids = {item.get("id") for item in ready}

# Prefer direct ready children first.
for child in open_children:
    if child.get("id") in ready_ids:
        print(child.get("id", ""))
        raise SystemExit(0)

# Fall back to direct in-progress children only when nothing directly ready exists.
for child in open_children:
    if child.get("status") == "in_progress":
        print(child.get("id", ""))
        raise SystemExit(0)

print("")
'
}

choose_next_actionable_issue() {
	local issue_id="$1"
	local child_id
	local nested_issue
	local status

	if issue_in_failed_skiplist "$issue_id"; then
		return 0
	fi

	status="$(issue_status "$issue_id")"
	if [[ "$status" != "closed" ]]; then
		close_issue_if_pr_merged "$issue_id" >/dev/null 2>&1 || true
		status="$(issue_status "$issue_id")"
	fi

	if issue_locked_locally "$issue_id"; then
		return 0
	fi

	if [[ "$status" == "closed" ]]; then
		if issue_is_closed_and_committed "$issue_id" 1; then
			return 0
		fi
		status="$(issue_status "$issue_id")"
	fi

	if [[ "$(child_count "$issue_id")" -gt 0 ]] && ! all_children_closed "$issue_id"; then
		while IFS= read -r child_id; do
			[[ -n "$child_id" ]] || continue
			nested_issue="$(choose_next_actionable_issue "$child_id")"
			if [[ -n "$nested_issue" ]]; then
				printf '%s\n' "$nested_issue"
				return 0
			fi
		done < <(direct_child_ids "$issue_id")
	fi

	if issue_is_ready "$issue_id" || [[ "$status" == "in_progress" ]] || issue_is_pr_awaiting_external_approval "$issue_id"; then
		printf '%s\n' "$issue_id"
	fi
}

opencode_result_has_contract() {
	local log_file="${1:-$LAST_OPENCODE_LOG_FILE}"

	[[ -n "$log_file" && -f "$log_file" ]] || return 1
	python3 -c '
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
blocks = re.findall(r"BEGIN_OPENCODE_RESULT\s*(.*?)\s*END_OPENCODE_RESULT", text, re.S)
raise SystemExit(0 if len(blocks) == 1 else 1)
' "$log_file"
}

opencode_result_field() {
	local key="$1"
	local log_file="${2:-$LAST_OPENCODE_LOG_FILE}"

	[[ -n "$log_file" && -f "$log_file" ]] || return 1
	python3 -c '
import re
import sys
from pathlib import Path

key = sys.argv[1]
text = Path(sys.argv[2]).read_text(errors="replace")
blocks = re.findall(r"BEGIN_OPENCODE_RESULT\s*(.*?)\s*END_OPENCODE_RESULT", text, re.S)
if not blocks:
    raise SystemExit(1)

data = {}
for line in blocks[-1].splitlines():
    line = line.strip()
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    data[k.strip()] = v.strip()

if key not in data:
    raise SystemExit(1)

print(data[key])
' "$key" "$log_file"
}

validate_opencode_result_contract() {
	local issue_id="$1"
	local issue_status
	local linked_pr_number
	local contract_issue_id
	local acceptance_verified
	local pr_number
	local pr_state
	local ready_to_merge
	local merged
	local branch_deleted
	local branch_cleanup_done
	local branch_cleanup_deleted_count
	local beads_closed
	local status

	if ! opencode_result_has_contract; then
		log_stderr "Missing required opencode result contract block for ${issue_id} (exactly one block required)"
		return 1
	fi

	contract_issue_id="$(opencode_result_field issue_id || true)"
	acceptance_verified="$(opencode_result_field acceptance_verified || true)"
	pr_number="$(opencode_result_field pr_number || true)"
	pr_state="$(opencode_result_field pr_state || true)"
	ready_to_merge="$(opencode_result_field ready_to_merge || true)"
	merged="$(opencode_result_field merged || true)"
	branch_deleted="$(opencode_result_field branch_deleted || true)"
	branch_cleanup_done="$(opencode_result_field branch_cleanup_done || true)"
	branch_cleanup_deleted_count="$(opencode_result_field branch_cleanup_deleted_count || true)"
	beads_closed="$(opencode_result_field beads_closed || true)"
	status="$(opencode_result_field status || true)"

	if [[ "$contract_issue_id" != "$issue_id" ]]; then
		log_stderr "Invalid result contract: issue_id mismatch (${contract_issue_id} != ${issue_id})"
		return 1
	fi

	linked_pr_number="$(extract_issue_pr_number "$issue_id")"
	if [[ -n "$linked_pr_number" && ("$pr_number" == "none" || -z "$pr_number") ]]; then
		log_stderr "Invalid result contract: issue ${issue_id} has linked PR #${linked_pr_number}, but contract reported pr_number=${pr_number:-<empty>}"
		return 1
	fi
	if [[ -n "$linked_pr_number" && "$pr_number" != "$linked_pr_number" ]]; then
		log_stderr "Invalid result contract: linked PR mismatch (expected #${linked_pr_number}, got #${pr_number})"
		return 1
	fi

	for v in "$acceptance_verified" "$ready_to_merge" "$merged" "$branch_deleted" "$branch_cleanup_done" "$beads_closed"; do
		if [[ "$v" != "true" && "$v" != "false" ]]; then
			log_stderr "Invalid result contract: boolean field must be true|false"
			return 1
		fi
	done

	if [[ ! "$branch_cleanup_deleted_count" =~ ^[0-9]+$ ]]; then
		log_stderr "Invalid result contract: branch_cleanup_deleted_count must be a non-negative integer"
		return 1
	fi

	if [[ "$branch_cleanup_done" != "true" ]]; then
		log_stderr "Invalid result contract: branch_cleanup_done must be true"
		return 1
	fi

	if [[ -z "$pr_number" || -z "$pr_state" || -z "$status" ]]; then
		log_stderr "Invalid result contract: missing required fields"
		return 1
	fi

	if [[ "$status" != "completed" && "$status" != "blocked" && "$status" != "failed" ]]; then
		log_stderr "Invalid result contract: status must be completed|blocked|failed"
		return 1
	fi

	if [[ "$status" == "blocked" ]]; then
		if [[ "$pr_state" != "OPEN" ]]; then
			log_stderr "Invalid result contract: status=blocked requires pr_state=OPEN"
			return 1
		fi
	fi

	if [[ "$status" == "completed" ]]; then
		if [[ "$beads_closed" != "true" ]]; then
			log_stderr "Invalid result contract: status=completed requires beads_closed=true"
			return 1
		fi
		if [[ "$pr_state" != "MERGED" && "$pr_state" != "NONE" ]]; then
			log_stderr "Invalid result contract: status=completed requires pr_state=MERGED|NONE"
			return 1
		fi
	fi

	if [[ "$ready_to_merge" == "true" ]]; then
		if [[ "$merged" != "true" || "$branch_deleted" != "true" || "$beads_closed" != "true" ]]; then
			log_stderr "Invalid result contract: ready_to_merge=true requires merged=true, branch_deleted=true, beads_closed=true"
			return 1
		fi
	fi

	if [[ "$merged" == "true" && "$pr_state" != "MERGED" ]]; then
		log_stderr "Invalid result contract: merged=true but pr_state=${pr_state}"
		return 1
	fi

	issue_status="$(issue_status "$issue_id")"
	if [[ "$issue_status" == "closed" ]]; then
		if [[ "$acceptance_verified" != "true" || "$beads_closed" != "true" ]]; then
			log_stderr "Invalid result contract: closed issue requires acceptance_verified=true and beads_closed=true"
			return 1
		fi
	fi

	return 0
}

verify_opencode_result_effects() {
	local issue_id="$1"
	local pr_number
	local pr_state_contract
	local merged
	local branch_deleted
	local beads_closed
	local status_contract
	local issue_status
	local pr_state_actual=""
	local pr_head_ref=""

	pr_number="$(opencode_result_field pr_number || true)"
	pr_state_contract="$(opencode_result_field pr_state || true)"
	merged="$(opencode_result_field merged || true)"
	branch_deleted="$(opencode_result_field branch_deleted || true)"
	beads_closed="$(opencode_result_field beads_closed || true)"
	status_contract="$(opencode_result_field status || true)"

	issue_status="$(issue_status "$issue_id")"
	if [[ "$beads_closed" == "true" && "$issue_status" != "closed" ]]; then
		log_stderr "Result contract mismatch: beads_closed=true but issue ${issue_id} status=${issue_status}"
		return 1
	fi

	if [[ "$status_contract" == "completed" && "$issue_status" != "closed" ]]; then
		log_stderr "Result contract mismatch: status=completed but issue ${issue_id} status=${issue_status}"
		return 1
	fi

	if [[ "$pr_number" == "none" || -z "$pr_number" ]]; then
		return 0
	fi

	if command -v gh >/dev/null 2>&1; then
		pr_state_actual="$(cd "$ROOT_DIR" && gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || true)"
		if [[ -n "$pr_state_actual" && "$pr_state_contract" != "$pr_state_actual" ]]; then
			log_stderr "Result contract mismatch: PR #${pr_number} state contract=${pr_state_contract} actual=${pr_state_actual}"
			return 1
		fi

		if [[ "$merged" == "true" && "$pr_state_actual" != "MERGED" ]]; then
			log_stderr "Result contract mismatch: merged=true but PR #${pr_number} state=${pr_state_actual}"
			return 1
		fi

		if [[ "$branch_deleted" == "true" ]]; then
			pr_head_ref="$(cd "$ROOT_DIR" && gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
			if [[ -n "$pr_head_ref" ]]; then
				if (cd "$ROOT_DIR" && git show-ref --verify --quiet "refs/heads/${pr_head_ref}"); then
					log_stderr "Result contract mismatch: branch_deleted=true but local branch ${pr_head_ref} still exists"
					return 1
				fi
				if (cd "$ROOT_DIR" && git ls-remote --exit-code --heads origin "$pr_head_ref" >/dev/null 2>&1); then
					log_stderr "Result contract mismatch: branch_deleted=true but remote branch ${pr_head_ref} still exists"
					return 1
				fi
			fi
		fi
	fi

	return 0
}

build_prompt() {
	local issue_id="$1"
	local scope_id="$2"
	local title="$3"

	cat <<EOF
Process Beads issue ${issue_id} (${title}) in ${ROOT_DIR}.

Strict workflow (execute in order):
1) Intake and scope lock
- Run: bd show ${issue_id} --json
- Claim or move to in_progress if needed; if claim says already claimed by same identity, continue.
- Only work issue ${issue_id} under scope root ${scope_id}. No sibling scope.

2) Mandatory branch hygiene and setup (before coding)
- Operate only inside ${ROOT_DIR}. Do NOT use git worktree add and do NOT run commands against external directories.
- Run exactly:
- a) git fetch --prune origin
- b) current_branch=\$(git branch --show-current)
- c) deleted_count=0; for branch in \$(git for-each-ref --format='%(refname:short)' refs/heads --merged origin/main); do if [ "\$branch" != "\$current_branch" ] && [ "\$branch" != "main" ] && [ "\$branch" != "master" ] && [ "\$branch" != "develop" ]; then if git branch -d "\$branch" >/dev/null 2>&1; then deleted_count=\$((deleted_count+1)); fi; fi; done
- d) for line in \$(git for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads); do branch=\${line%%|*}; track=\${line#*|}; if [ "\$branch" = "\$current_branch" ] || [ "\$branch" = "main" ] || [ "\$branch" = "master" ] || [ "\$branch" = "develop" ]; then continue; fi; if echo "\$track" | grep -q '\[gone\]' && git merge-base --is-ancestor "\$branch" origin/main; then if git branch -d "\$branch" >/dev/null 2>&1; then deleted_count=\$((deleted_count+1)); fi; fi; done
- e) determine/create working branch for this issue; if intended name is occupied by another worktree, create -v2/-v3 suffix branch in this repo.
- f) record deleted_count in result contract as branch_cleanup_deleted_count.

3) Implement and verify
- Work this issue on its own feature branch; keep commits logically grouped.
- Create checkpoint commits for meaningful milestones.
- Run relevant verification for all changes.
- For coverage issues: verify package-level coverage for each package named in acceptance/title; if explicit package targets are missing, update issue metadata before closure.

4) PR handling and merge (no defer)
- If linked PR exists in notes, inspect with gh.
- If PR is OPEN and mergeable with passing checks, merge immediately:
- a) gh pr view <number> --json state,mergeable,mergeStateStatus,statusCheckRollup
- b) gh pr merge <number> --merge --delete-branch
- c) bd close ${issue_id} --reason "PR #<number> merged" --json
- d) verify with gh pr view <number> --json state and bd show ${issue_id} --json
- If linked PR note is stale vs merged PR, append note with canonical latest PR number before result contract.

5) Closure rules (mandatory)
- Never close unless every acceptance criterion is satisfied.
- If parent/epic not resolvable, create explicit child subtasks and leave parent open.
- If parent acceptance fails, inspect descendants and reopen any closed descendant whose criteria are not truly met.
- If blocked and cannot finish, reset issue to open before exiting non-zero.
- Do not start unrelated work.

6) Result contract (exactly one block, no markdown fence)
- BEGIN_OPENCODE_RESULT
- issue_id=${issue_id}
- status=<completed|blocked|failed>
- acceptance_verified=<true|false>
- pr_number=<number|none>
- pr_state=<OPEN|MERGED|CLOSED|NONE>
- ready_to_merge=<true|false>
- merged=<true|false>
- branch_deleted=<true|false>
- branch_cleanup_done=<true|false>
- branch_cleanup_deleted_count=<non-negative integer>
- beads_closed=<true|false>
- notes=<short one-line summary>
- END_OPENCODE_RESULT
EOF
}

build_recovery_prompt() {
	local issue_id="$1"
	local scope_id="$2"
	local title="$3"
	local attempt="$4"

	cat <<EOF
Resume Beads issue ${issue_id} (${title}) in ${ROOT_DIR} after the previous attempt failed.

Recovery attempt: ${attempt} of ${MAX_RECOVERY_ATTEMPTS}

Strict recovery workflow (execute in order):
1) Triage first
- Run: bd show ${issue_id} --json
- If claim says already claimed by same identity, continue.
- Identify the exact failure from the previous run and fix that first.

2) Mandatory branch hygiene and setup (before coding)
- Operate only inside ${ROOT_DIR}. Do NOT use git worktree add and do NOT run commands against external directories.
- Run exactly:
- a) git fetch --prune origin
- b) current_branch=\$(git branch --show-current)
- c) deleted_count=0; for branch in \$(git for-each-ref --format='%(refname:short)' refs/heads --merged origin/main); do if [ "\$branch" != "\$current_branch" ] && [ "\$branch" != "main" ] && [ "\$branch" != "master" ] && [ "\$branch" != "develop" ]; then if git branch -d "\$branch" >/dev/null 2>&1; then deleted_count=\$((deleted_count+1)); fi; fi; done
- d) for line in \$(git for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads); do branch=\${line%%|*}; track=\${line#*|}; if [ "\$branch" = "\$current_branch" ] || [ "\$branch" = "main" ] || [ "\$branch" = "master" ] || [ "\$branch" = "develop" ]; then continue; fi; if echo "\$track" | grep -q '\[gone\]' && git merge-base --is-ancestor "\$branch" origin/main; then if git branch -d "\$branch" >/dev/null 2>&1; then deleted_count=\$((deleted_count+1)); fi; fi; done
- e) determine/create working branch for this issue; if intended name is occupied by another worktree, create -v2/-v3 suffix branch in this repo.
- f) record deleted_count in result contract as branch_cleanup_deleted_count.

3) Repair and verify
- Keep work isolated to this issue branch/PR only.
- If meaningful progress exists, checkpoint with logical commit.
- Re-run verification for affected files/packages.
- For coverage issues: verify package-level coverage for each package named in acceptance/title; if explicit package targets are missing, update issue metadata before closure.

4) PR handling and merge (no defer)
- If linked PR exists in notes, inspect with gh.
- If PR is OPEN and mergeable with passing checks, merge immediately:
- a) gh pr view <number> --json state,mergeable,mergeStateStatus,statusCheckRollup
- b) gh pr merge <number> --merge --delete-branch
- c) bd close ${issue_id} --reason "PR #<number> merged" --json
- d) verify with gh pr view <number> --json state and bd show ${issue_id} --json
- If linked PR note is stale vs merged PR, append note with canonical latest PR number before result contract.

5) Closure rules (mandatory)
- Never close unless every acceptance criterion is satisfied.
- If parent/epic not resolvable, create explicit child subtasks and leave parent open.
- If parent acceptance fails, inspect descendants and reopen any closed descendant whose criteria are not truly met.
- If still blocked after repair, reset issue to open before exiting non-zero.
- Do not start unrelated work.

6) Result contract (exactly one block, no markdown fence)
- BEGIN_OPENCODE_RESULT
- issue_id=${issue_id}
- status=<completed|blocked|failed>
- acceptance_verified=<true|false>
- pr_number=<number|none>
- pr_state=<OPEN|MERGED|CLOSED|NONE>
- ready_to_merge=<true|false>
- merged=<true|false>
- branch_deleted=<true|false>
- branch_cleanup_done=<true|false>
- branch_cleanup_deleted_count=<non-negative integer>
- beads_closed=<true|false>
- notes=<short one-line summary>
- END_OPENCODE_RESULT
EOF
}

shell_escape_join() {
	python3 - "$@" <<'PY'
import shlex
import sys

print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
}

release_issue_if_in_progress() {
	local issue_id="$1"
	local status

	status="$(issue_status "$issue_id")"
	if [[ "$status" == "in_progress" ]]; then
		log "Resetting ${issue_id} from in_progress to open"
		(cd "$ROOT_DIR" && bd update "$issue_id" --status open --json >/dev/null)
	fi
}

issue_is_closed_and_committed() {
	local issue_id="$1"
	local allow_merged="${2:-0}"
	local status
	local branch
	local base_ref="main"
	local ahead_count
	local worktree_status

	status="$(issue_status "$issue_id")"
	if [[ "$status" != "closed" ]]; then
		return 1
	fi

	if ! enforce_issue_closure_criteria "$issue_id"; then
		return 1
	fi

	worktree_status="$(cd "$ROOT_DIR" && git status --short)"
	if [[ -n "$worktree_status" ]]; then
		log_stderr "Issue ${issue_id} is closed but the worktree is not clean"
		return 1
	fi

	branch="$(cd "$ROOT_DIR" && git branch --show-current)"
	if [[ -z "$branch" || "$branch" == "main" ]]; then
		log_stderr "Issue ${issue_id} is closed but branch ${branch:-<none>} has no issue-specific commits to validate"
		return 1
	fi

	ahead_count="$(cd "$ROOT_DIR" && git rev-list --count "${base_ref}..HEAD")"
	if [[ "$ahead_count" =~ ^0$ ]]; then
		if [[ "$allow_merged" == "1" ]]; then
			if close_issue_if_pr_merged "$issue_id"; then
				return 0
			fi
			status="$(issue_status "$issue_id")"
			if [[ "$status" == "closed" ]]; then
				return 0
			fi
			log_stderr "Issue ${issue_id} has no commits ahead of ${base_ref} and linked PR is not merged"
			return 1
		fi
		log_stderr "Issue ${issue_id} is closed but current branch has no commits ahead of ${base_ref}"
		return 1
	fi

	return 0
}

issue_has_reviewable_checkpoint() {
	local issue_id="$1"
	local status
	local branch
	local ahead_count
	local worktree_status
	local pr_state=""

	status="$(issue_status "$issue_id")"
	if [[ "$status" != "open" && "$status" != "in_progress" ]]; then
		return 1
	fi

	worktree_status="$(cd "$ROOT_DIR" && git status --short)"
	if [[ -n "$worktree_status" ]]; then
		return 1
	fi

	branch="$(cd "$ROOT_DIR" && git branch --show-current)"
	if [[ -z "$branch" || "$branch" == "main" ]]; then
		return 1
	fi

	ahead_count="$(cd "$ROOT_DIR" && git rev-list --count "main..HEAD")"
	if [[ "$ahead_count" =~ ^0$ ]]; then
		return 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi

	pr_state="$(cd "$ROOT_DIR" && gh pr view --json state --jq '.state' 2>/dev/null || true)"
	[[ "$pr_state" == "OPEN" ]]
}

issue_is_awaiting_merge() {
	local issue_id="$1"
	local status

	status="$(issue_status "$issue_id")"
	if [[ "$status" != "blocked" ]]; then
		return 1
	fi

	if ! issue_has_label "$issue_id" "$AWAITING_MERGE_LABEL"; then
		return 1
	fi

	return 0
}

append_issue_completion_metadata() {
	local issue_id="$1"
	local branch
	local short_sha
	local pr_number=""
	local pr_suffix=""
	local existing_notes
	local note

	branch="$(cd "$ROOT_DIR" && git branch --show-current)"
	short_sha="$(cd "$ROOT_DIR" && git rev-parse --short HEAD)"
	existing_notes="$(issue_notes "$issue_id")"

	if grep -Fq "commit ${short_sha}" <<<"$existing_notes"; then
		return 0
	fi

	if command -v gh >/dev/null 2>&1; then
		pr_number="$(cd "$ROOT_DIR" && gh pr view --json number --jq '.number' 2>/dev/null || true)"
		if [[ -n "$pr_number" ]]; then
			pr_suffix=" (PR #${pr_number})"
		fi
	fi

	note="Completion checkpoint: branch ${branch}, commit ${short_sha}${pr_suffix}"
	(cd "$ROOT_DIR" && bd update "$issue_id" --append-notes "$note" --json >/dev/null)
}

cleanup_active_issue_on_exit() {
	local exit_code=$?

	if [[ "$exit_code" -ne 0 && -n "$CURRENT_ACTIVE_ISSUE" ]]; then
		set +e
		release_issue_if_in_progress "$CURRENT_ACTIVE_ISSUE"
		release_issue_lock
		set -e
	fi
}

trap cleanup_active_issue_on_exit EXIT

run_opencode_for_issue() {
	local issue_id="$1"
	local scope_id="$2"
	local title
	local prompt
	local attempt=0
	local exit_code=0
	local current_status
	local step_budget="$OPENCODE_STEPS"
	local -a cmd

	CURRENT_ACTIVE_ISSUE="$issue_id"
	title="$(issue_title "$issue_id")"
	current_status="$(issue_status "$issue_id")"
	record_run_snapshot "$issue_id"

	if [[ "$DRY_RUN" -eq 0 ]]; then
		if ! acquire_issue_lock "$issue_id"; then
			log "Issue ${issue_id} is currently being processed in another local terminal; skipping for now."
			clear_current_issue_context
			return 89
		fi
	fi

	if [[ "$DRY_RUN" -eq 0 && "$current_status" == "open" ]]; then
		if ! ensure_issue_claimed "$issue_id"; then
			clear_current_issue_context
			return 88
		fi
	elif [[ "$DRY_RUN" -eq 0 ]]; then
		if identity_matches_issue_claim "$issue_id"; then
			log "Issue ${issue_id} is ${current_status} and already assigned to current identity; skipping claim."
		else
			log "Issue ${issue_id} is ${current_status}; skipping claim step."
		fi
	fi

	build_cmd_for_prompt() {
		local prompt_text="$1"
		cmd=(opencode run --dir "$ROOT_DIR")

		if [[ -n "$MODEL" ]]; then
			cmd+=(--model "$MODEL")
		fi
		if [[ -n "$AGENT" ]]; then
			cmd+=(--agent "$AGENT")
		fi
		if [[ -n "$VARIANT" ]]; then
			cmd+=(--variant "$VARIANT")
		fi

		if [[ ${#OPENCODE_EXTRA_ARGS[@]} -gt 0 ]]; then
			cmd+=("${OPENCODE_EXTRA_ARGS[@]}")
		fi

		cmd+=("$prompt_text")
	}

	execute_current_cmd() {
		local config_json
		local log_file
		local cmd_status
		local start_ns
		local end_ns
		local duration_ms=0
		local reason
		config_json="$(build_opencode_config_content "$step_budget")"

		if [[ "$DRY_RUN" -eq 1 ]]; then
			printf 'DRY RUN (steps=%s): ' "$step_budget"
			if [[ -n "$SANDBOX_NAME" ]]; then
				local sandbox_cmd
				sandbox_cmd="$(shell_escape_join env "OPENCODE_CONFIG_CONTENT=$config_json" "${cmd[@]}")"
				printf '%q ' docker sandbox run "$SANDBOX_NAME" -- -c "$sandbox_cmd"
			else
				printf '%q ' env "OPENCODE_CONFIG_CONTENT=$config_json" "${cmd[@]}"
			fi
			printf '\n'
			return 0
		fi

		mkdir -p "$ROOT_DIR/.tmp"
		log_file="$ROOT_DIR/.tmp/opencode-${issue_id}.log"
		LAST_OPENCODE_LOG_FILE="$log_file"

		if [[ -n "$SANDBOX_NAME" ]]; then
			local sandbox_cmd
			sandbox_cmd="$(shell_escape_join env "OPENCODE_CONFIG_CONTENT=$config_json" "${cmd[@]}")"
			start_ns="$(
				python3 - <<'PY'
import time
print(time.time_ns())
PY
			)"
			set +e
			(cd "$ROOT_DIR" && docker sandbox run "$SANDBOX_NAME" -- -c "$sandbox_cmd") 2>&1 | tee "$log_file"
			cmd_status=${PIPESTATUS[0]}
			set -e
		else
			start_ns="$(
				python3 - <<'PY'
import time
print(time.time_ns())
PY
			)"
			set +e
			(cd "$ROOT_DIR" && env OPENCODE_CONFIG_CONTENT="$config_json" "${cmd[@]}") 2>&1 | tee "$log_file"
			cmd_status=${PIPESTATUS[0]}
			set -e
		fi

		end_ns="$(
			python3 - <<'PY'
import time
print(time.time_ns())
PY
		)"
		if [[ "$start_ns" =~ ^[0-9]+$ && "$end_ns" =~ ^[0-9]+$ && "$end_ns" -ge "$start_ns" ]]; then
			duration_ms=$(((end_ns - start_ns) / 1000000))
		fi

		if [[ "$cmd_status" -eq 0 ]] && grep -Fq "$MAX_STEPS_MESSAGE" "$log_file"; then
			log "OpenCode hit the maximum-step limit; treating this as a recoverable failure"
			emit_attempt_telemetry "$issue_id" "opencode" "max_steps" "$duration_ms"
			return 86
		fi

		if [[ "$cmd_status" -eq 0 ]]; then
			if ! validate_opencode_result_contract "$issue_id"; then
				reason="contract_validation_failed"
				emit_attempt_telemetry "$issue_id" "opencode" "$reason" "$duration_ms"
				if maybe_skip_issue_after_contract_failures "$issue_id" "$reason"; then
					return 89
				fi
				log_stderr "Opencode result contract validation failed for ${issue_id}"
				return 87
			fi
			if ! verify_opencode_result_effects "$issue_id"; then
				reason="contract_effect_verification_failed"
				emit_attempt_telemetry "$issue_id" "opencode" "$reason" "$duration_ms"
				if maybe_skip_issue_after_contract_failures "$issue_id" "$reason"; then
					return 89
				fi
				log_stderr "Opencode result effect verification failed for ${issue_id}"
				return 87
			fi
			if is_noop_completed_result "$issue_id"; then
				reason="noop_completed_result"
				emit_attempt_telemetry "$issue_id" "opencode" "$reason" "$duration_ms"
				if maybe_skip_issue_after_contract_failures "$issue_id" "$reason"; then
					return 89
				fi
				log_stderr "Opencode reported completed but produced no observable state changes for ${issue_id}"
				return 87
			fi
			reset_issue_contract_fail_count "$issue_id"
			emit_attempt_telemetry "$issue_id" "opencode" "success" "$duration_ms"
		else
			if grep -Fq "permission requested: external_directory" "$log_file"; then
				log_stderr "OpenCode attempted external_directory access; this run must stay within ${ROOT_DIR}"
				emit_attempt_telemetry "$issue_id" "opencode" "external_directory_rejected" "$duration_ms"
				(cd "$ROOT_DIR" && bd comments add "$issue_id" "Run failed: external_directory permission was requested (likely via git worktree or commands outside ${ROOT_DIR}). Use only local branch workflow inside ${ROOT_DIR}." --json >/dev/null 2>&1 || true)
				return 87
			fi
			emit_attempt_telemetry "$issue_id" "opencode" "command_failure" "$duration_ms"
		fi

		return "$cmd_status"
	}

	log "Running opencode for ${issue_id}: ${title}"

	prompt="$(build_prompt "$issue_id" "$scope_id" "$title")"
	build_cmd_for_prompt "$prompt"
	if execute_current_cmd; then
		if [[ "$DRY_RUN" -eq 1 ]]; then
			clear_current_issue_context
			return 0
		fi
		if issue_is_closed_and_committed "$issue_id"; then
			append_issue_completion_metadata "$issue_id"
			clear_current_issue_context
			return 0
		fi
		if issue_has_reviewable_checkpoint "$issue_id"; then
			mark_issue_awaiting_merge "$issue_id"
			log "Issue ${issue_id} has reviewable checkpoint progress (open PR + clean branch); treating this run as success"
			clear_current_issue_context
			return 0
		fi
		if issue_is_pr_awaiting_external_approval "$issue_id"; then
			log "Issue ${issue_id} is blocked only on external PR approval; treating this run as success"
			clear_current_issue_context
			return 0
		fi
		current_status="$(issue_status "$issue_id")"
		log "OpenCode exited without closing ${issue_id}; current status is ${current_status}. Treating this as a recoverable failure"
		exit_code=87
	else
		exit_code=$?
	fi

	while ((attempt < MAX_RECOVERY_ATTEMPTS)); do
		attempt=$((attempt + 1))
		step_budget=$((OPENCODE_STEPS + (attempt * RECOVERY_STEP_INCREMENT)))
		log "opencode failed for ${issue_id}; recovery attempt ${attempt}/${MAX_RECOVERY_ATTEMPTS}"
		log "Recovery attempt step budget: ${step_budget}"
		prompt="$(build_recovery_prompt "$issue_id" "$scope_id" "$title" "$attempt")"
		build_cmd_for_prompt "$prompt"
		if execute_current_cmd; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				clear_current_issue_context
				return 0
			fi
			if issue_is_closed_and_committed "$issue_id"; then
				append_issue_completion_metadata "$issue_id"
				clear_current_issue_context
				return 0
			fi
			if issue_has_reviewable_checkpoint "$issue_id"; then
				mark_issue_awaiting_merge "$issue_id"
				log "Issue ${issue_id} has reviewable checkpoint progress (open PR + clean branch); treating recovery run as success"
				clear_current_issue_context
				return 0
			fi
			if issue_is_pr_awaiting_external_approval "$issue_id"; then
				log "Issue ${issue_id} is blocked only on external PR approval; treating recovery run as success"
				clear_current_issue_context
				return 0
			fi
			current_status="$(issue_status "$issue_id")"
			log "Recovery attempt ${attempt} exited without closing ${issue_id}; current status is ${current_status}"
			exit_code=87
		else
			exit_code=$?
		fi
	done

	if [[ "$DRY_RUN" -eq 0 ]]; then
		release_issue_if_in_progress "$issue_id"
	fi
	clear_current_issue_context

	return "$exit_code"
}

print_children_statuses() {
	local report

	report="$(children_report "$1")"
	if [[ -z "$report" ]]; then
		log "No direct child tasks found."
		return
	fi

	log "Child task statuses:"
	while IFS=$'\t' read -r child_id child_status child_title; do
		[[ -n "$child_id" ]] || continue
		log "- ${child_id} [${child_status}] ${child_title}"
	done <<<"$report"
}

print_failed_issue_skiplist() {
	local issue_id

	if [[ ${#FAILED_ISSUES_IN_RUN[@]} -eq 0 ]]; then
		return
	fi

	log "Skipped child issues in this run after earlier failures:"
	for issue_id in "${FAILED_ISSUES_IN_RUN[@]}"; do
		log "- ${issue_id} [$(issue_status "$issue_id")] $(issue_title "$issue_id")"
	done
}

resolve_issue_chain() {
	local current_issue="$1"
	local scope_root="$2"
	local parent_issue
	local parent_status

	while true; do
		parent_issue="$(issue_parent "$current_issue")"
		if [[ -z "$parent_issue" ]]; then
			return 0
		fi

		if ! all_children_closed "$parent_issue"; then
			return 0
		fi

		parent_status="$(issue_status "$parent_issue")"
		if [[ "$parent_status" != "closed" ]]; then
			log "All child tasks for ${parent_issue} are closed; resolving parent issue."
			if ! run_opencode_for_issue "$parent_issue" "$scope_root"; then
				release_issue_if_in_progress "$parent_issue"
				fail "opencode failed while resolving parent issue ${parent_issue}"
			fi

			if [[ "$DRY_RUN" -eq 1 ]]; then
				return 0
			fi

			parent_status="$(issue_status "$parent_issue")"
			if [[ "$parent_status" != "closed" ]]; then
				fail "opencode returned successfully, but parent issue ${parent_issue} is still ${parent_status}"
			fi

			log "Parent issue ${parent_issue} is closed."
		fi

		if [[ "$parent_issue" == "$scope_root" ]]; then
			return 0
		fi

		current_issue="$parent_issue"
	done
}

process_single_issue() {
	local status

	status="$(issue_status "$ISSUE_ID")"
	if [[ "$status" == "closed" ]]; then
		if issue_is_closed_and_committed "$ISSUE_ID" 1; then
			log "Issue ${ISSUE_ID} is already closed."
			return 0
		fi
		if has_unclosed_children "$ISSUE_ID"; then
			log "Issue ${ISSUE_ID} is closed but has open descendants; reopening parent and continuing."
			(cd "$ROOT_DIR" && bd reopen "$ISSUE_ID" --reason "Parent closed while descendants remain open" --json >/dev/null)
			status="$(issue_status "$ISSUE_ID")"
		fi
		status="$(issue_status "$ISSUE_ID")"
		log "Issue ${ISSUE_ID} was closed but did not meet closure criteria; continuing processing (status=${status})."
	fi

	if ! run_opencode_for_issue "$ISSUE_ID" "$ISSUE_ID"; then
		release_issue_if_in_progress "$ISSUE_ID"
		fail "opencode failed for ${ISSUE_ID}"
	fi

	if [[ "$DRY_RUN" -eq 1 ]]; then
		return 0
	fi

	if [[ "$EXIT_AFTER_LOOP" -eq 1 ]]; then
		log "Exit-after-loop enabled; finishing after this loop cycle."
		return 0
	fi

	if ! issue_is_closed_and_committed "$ISSUE_ID"; then
		if issue_is_pr_awaiting_external_approval "$ISSUE_ID"; then
			log "Issue ${ISSUE_ID} is blocked only on external PR approval; stopping as requested."
			return 0
		fi
		if issue_is_awaiting_merge "$ISSUE_ID"; then
			log "Issue ${ISSUE_ID} is awaiting PR merge; stopping as requested."
			return 0
		fi
		if ! issue_has_reviewable_checkpoint "$ISSUE_ID"; then
			status="$(issue_status "$ISSUE_ID")"
			fail "opencode returned successfully, but ${ISSUE_ID} is neither closed-and-committed nor in a reviewable checkpoint state (status=${status})"
		fi
		log "Issue ${ISSUE_ID} remains open with reviewable checkpoint progress; stopping as requested."
		return 0
	fi

	log "Issue ${ISSUE_ID} is closed."
}

process_child_loop() {
	local iteration=0
	local next_issue
	local status

	READY_PARENT_SCOPE="$ISSUE_ID"

	while true; do
		iteration=$((iteration + 1))
		if ((iteration > MAX_ITERATIONS)); then
			print_children_statuses "$ISSUE_ID"
			print_failed_issue_skiplist
			READY_PARENT_SCOPE=""
			fail "Reached max iterations (${MAX_ITERATIONS}) before exhausting actionable descendants"
		fi

		if [[ "$(issue_status "$ISSUE_ID")" == "closed" ]]; then
			if has_unclosed_children "$ISSUE_ID"; then
				log "Issue ${ISSUE_ID} is closed but has open descendants; reopening parent and continuing."
				(cd "$ROOT_DIR" && bd reopen "$ISSUE_ID" --reason "Parent closed while descendants remain open" --json >/dev/null)
				continue
			fi
			if issue_is_closed_and_committed "$ISSUE_ID" 1; then
				log "Issue ${ISSUE_ID} is closed."
				READY_PARENT_SCOPE=""
				return 0
			fi
			log "Issue ${ISSUE_ID} was closed but failed closure validation; continuing loop."
		fi

		next_issue="$(choose_next_actionable_issue "$ISSUE_ID")"
		if [[ -z "$next_issue" || "$next_issue" == "$ISSUE_ID" ]]; then
			print_children_statuses "$ISSUE_ID"
			print_failed_issue_skiplist
			if ! issue_can_close "$ISSUE_ID"; then
				local reopened
				reopened="$(reopen_invalid_closed_descendants "$ISSUE_ID")"
				if [[ "$reopened" =~ ^[0-9]+$ ]] && [[ "$reopened" -gt 0 ]]; then
					log "Reopened ${reopened} descendant issue(s) under ${ISSUE_ID} after closure-criteria audit."
					continue
				fi
			fi
			if all_children_closed "$ISSUE_ID" && [[ "$(issue_status "$ISSUE_ID")" != "closed" ]]; then
				log "All child tasks for ${ISSUE_ID} are closed; processing parent issue."
				if ! run_opencode_for_issue "$ISSUE_ID" "$ISSUE_ID"; then
					release_issue_if_in_progress "$ISSUE_ID"
					READY_PARENT_SCOPE=""
					fail "opencode failed while processing parent issue ${ISSUE_ID}"
				fi

				if [[ "$DRY_RUN" -eq 1 ]]; then
					READY_PARENT_SCOPE=""
					return 0
				fi

				status="$(issue_status "$ISSUE_ID")"
				if [[ "$status" == "closed" ]]; then
					READY_PARENT_SCOPE=""
					log "Issue ${ISSUE_ID} is closed."
					return 0
				fi
				if issue_is_pr_awaiting_external_approval "$ISSUE_ID" || issue_is_awaiting_merge "$ISSUE_ID" || issue_has_reviewable_checkpoint "$ISSUE_ID"; then
					READY_PARENT_SCOPE=""
					log "Issue ${ISSUE_ID} remains in a valid PR-awaiting/reviewable state; stopping cleanly."
					return 0
				fi
				if has_unclosed_children "$ISSUE_ID"; then
					log "Parent issue ${ISSUE_ID} is not yet resolved and now has new child tasks; continuing loop to process them."
					continue
				fi

				READY_PARENT_SCOPE=""
				fail "all child tasks are closed, but parent issue ${ISSUE_ID} is still ${status}"
			fi
			if has_children_blocked_on_external_approval "$ISSUE_ID"; then
				READY_PARENT_SCOPE=""
				log "All remaining non-closed children are waiting on external PR approval; stopping cleanly."
				return 0
			fi
			if has_unclosed_children "$ISSUE_ID"; then
				if [[ ${#FAILED_ISSUES_IN_RUN[@]} -gt 0 ]]; then
					log "No actionable descendants found, but some were skipped after earlier failures; clearing skiplist and retrying."
					FAILED_ISSUES_IN_RUN=()
					continue
				fi
				READY_PARENT_SCOPE=""
				fail "No actionable descendants found, but parent issue ${ISSUE_ID} still has non-closed child tasks"
			fi
			READY_PARENT_SCOPE=""
			log "No more actionable descendants found under ${ISSUE_ID}; stopping cleanly."
			return 0
		fi

		status="$(issue_status "$next_issue")"
		if [[ "$status" == "closed" ]]; then
			if issue_is_closed_and_committed "$next_issue" 1; then
				log "Selected child issue ${next_issue} is already closed; skipping."
				if ! resolve_issue_chain "$next_issue" "$ISSUE_ID"; then
					print_children_statuses "$ISSUE_ID"
					READY_PARENT_SCOPE=""
					fail "failed while resolving parent chain for already-closed child ${next_issue}"
				fi
				if [[ "$SINGLE_JOB" -eq 1 ]]; then
					READY_PARENT_SCOPE=""
					return 0
				fi
				continue
			fi
		fi

		log "Selected child issue ${next_issue}; processing in current run."

		if ! run_opencode_for_issue "$next_issue" "$ISSUE_ID"; then
			release_issue_if_in_progress "$next_issue"
			FAILED_ISSUES_IN_RUN+=("$next_issue")
			print_children_statuses "$ISSUE_ID"
			print_failed_issue_skiplist
			if [[ "$SINGLE_JOB" -eq 1 ]]; then
				READY_PARENT_SCOPE=""
				fail "opencode failed for child issue ${next_issue}"
			fi
			continue
		fi

		if [[ "$DRY_RUN" -eq 1 ]]; then
			READY_PARENT_SCOPE=""
			return 0
		fi

		if issue_is_closed_and_committed "$next_issue"; then
			if ! resolve_issue_chain "$next_issue" "$ISSUE_ID"; then
				print_children_statuses "$ISSUE_ID"
				READY_PARENT_SCOPE=""
				fail "failed while resolving parent chain for ${next_issue}"
			fi
			if [[ "$SINGLE_JOB" -eq 1 ]]; then
				READY_PARENT_SCOPE=""
				return 0
			fi
			continue
		fi

		if issue_has_reviewable_checkpoint "$next_issue"; then
			mark_issue_awaiting_merge "$next_issue"
			log "Child issue ${next_issue} remains open with reviewable checkpoint progress; moving to next actionable descendant."
			if [[ "$SINGLE_JOB" -eq 1 ]]; then
				READY_PARENT_SCOPE=""
				return 0
			fi
			continue
		fi

		if issue_is_pr_awaiting_external_approval "$next_issue"; then
			log "Child issue ${next_issue} is blocked only on external PR approval; moving to next actionable descendant."
			if [[ "$SINGLE_JOB" -eq 1 ]]; then
				READY_PARENT_SCOPE=""
				return 0
			fi
			continue
		fi

		if issue_is_awaiting_merge "$next_issue"; then
			log "Child issue ${next_issue} is awaiting PR merge; moving to next actionable descendant."
			if [[ "$SINGLE_JOB" -eq 1 ]]; then
				READY_PARENT_SCOPE=""
				return 0
			fi
			continue
		fi

		status="$(issue_status "$next_issue")"
		print_children_statuses "$ISSUE_ID"
		READY_PARENT_SCOPE=""
		fail "opencode returned successfully, but child issue ${next_issue} is neither closed-and-committed nor in a reviewable checkpoint state (status=${status})"
	done
}

main() {
	parse_args "$@"

	require_command bd
	require_command python3
	if [[ -n "$SANDBOX_NAME" ]]; then
		require_command docker
	else
		require_command opencode
	fi

	if ! (cd "$ROOT_DIR" && bd show "$ISSUE_ID" --json >/dev/null); then
		fail "Unable to load issue ${ISSUE_ID}"
	fi

	init_locks_dir

	log "Repository: ${ROOT_DIR}"
	log "Target issue: ${ISSUE_ID}"

	if [[ "$(child_count "$ISSUE_ID")" -gt 0 ]]; then
		process_child_loop
	else
		process_single_issue
	fi
}

main "$@"
