#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ROOT_DIR="${GATEWAY_ROOT:-$HOME/Development/github/hashicorp/a2a/gateway}"

MODEL=""
AGENT=""
VARIANT=""
SANDBOX_NAME=""
OPENCODE_STEPS="${OPENCODE_STEPS:-10}"
MAX_ITERATIONS="${MAX_ITERATIONS:-100}"
MAX_STEP_RECOVERY_ATTEMPTS="${OPENCODE_MAX_STEP_RECOVERY_ATTEMPTS:-2}"
STEP_RECOVERY_INCREMENT="${OPENCODE_STEP_RECOVERY_INCREMENT:-10}"
PROGRESS_BONUS_RETRIES="${OPENCODE_PROGRESS_BONUS_RETRIES:-2}"
MAX_STEPS_MESSAGE="Maximum steps for this agent have been reached."
LOOP_LOG_FILE="${OPENCODE_LOOP_LOG_FILE:-.tmp/opencode-loop.log}"
REQUIRE_SESSION_REUSE="${OPENCODE_REQUIRE_SESSION_REUSE:-1}"
BOOTSTRAP_PLAN_SESSION="${OPENCODE_BOOTSTRAP_PLAN_SESSION:-1}"
BOOTSTRAP_PLAN_STEPS="${OPENCODE_BOOTSTRAP_PLAN_STEPS:-6}"
DRY_RUN=0
ISSUE_ID=""
OPENCODE_EXTRA_ARGS=()
ROOT_SESSION_ID="${OPENCODE_SESSION_ID:-}"
ROOT_RUN_COUNT=0
SESSION_ESTABLISHED=0

usage() {
	cat <<EOF
Usage:
  ${SCRIPT_NAME} [options] <issue-id> [-- <extra opencode args>]

Description:
  Simple Beads loop runner.
  - If <issue-id> is a task, run OpenCode on that task until it is closed.
  - If <issue-id> is an epic/parent, repeatedly pick the next ready descendant,
    run OpenCode on it, and continue until the full tree is complete.

Options:
  --model <provider/model>  Pass model through to opencode
  --agent <name>            Pass agent through to opencode
  --variant <name>          Pass model variant through to opencode
  --steps <count>           Set opencode step budget (default: 10)
  --sandbox-name <name>     Run through: docker sandbox run <name> -- -c "<cmd>"
  --session <session-id>    Reuse this OpenCode session id
  --max-iterations <count>  Safety cap for loop iterations (default: 100)
  --dry-run                 Print the opencode command and exit
  -h, --help                Show this help text

Environment:
  OPENCODE_MAX_STEP_RECOVERY_ATTEMPTS  Retry count when agent hits step limit (default: 2)
  OPENCODE_STEP_RECOVERY_INCREMENT     Steps to add per retry (default: 10)
  OPENCODE_PROGRESS_BONUS_RETRIES      Extra retries when Beads status changes (default: 2)
  OPENCODE_LOOP_LOG_FILE               Optional file path to tee all loop output
  OPENCODE_REQUIRE_SESSION_REUSE       Fail if a later run would not pass --session (0|1)
  OPENCODE_SESSION_ID                  Initial OpenCode session id to reuse
  OPENCODE_BOOTSTRAP_PLAN_SESSION      Create session with plan run when missing (0|1)
  OPENCODE_BOOTSTRAP_PLAN_STEPS        Step budget for bootstrap plan run (default: 6)
EOF
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '%s\n' "$*"
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
		--session)
			[[ $# -ge 2 ]] || fail "--session requires a value"
			ROOT_SESSION_ID="$2"
			shift 2
			;;
		--max-iterations)
			[[ $# -ge 2 ]] || fail "--max-iterations requires a value"
			MAX_ITERATIONS="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
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
	[[ "$MAX_STEP_RECOVERY_ATTEMPTS" =~ ^[0-9]+$ ]] || fail "OPENCODE_MAX_STEP_RECOVERY_ATTEMPTS must be an integer"
	[[ "$STEP_RECOVERY_INCREMENT" =~ ^[0-9]+$ ]] || fail "OPENCODE_STEP_RECOVERY_INCREMENT must be an integer"
	[[ "$PROGRESS_BONUS_RETRIES" =~ ^[0-9]+$ ]] || fail "OPENCODE_PROGRESS_BONUS_RETRIES must be an integer"
	case "$REQUIRE_SESSION_REUSE" in
	0 | 1) ;;
	*) fail "OPENCODE_REQUIRE_SESSION_REUSE must be 0 or 1" ;;
	esac
	case "$BOOTSTRAP_PLAN_SESSION" in
	0 | 1) ;;
	*) fail "OPENCODE_BOOTSTRAP_PLAN_SESSION must be 0 or 1" ;;
	esac
	[[ "$BOOTSTRAP_PLAN_STEPS" =~ ^[0-9]+$ ]] || fail "OPENCODE_BOOTSTRAP_PLAN_STEPS must be an integer"

	if [[ -n "$ROOT_SESSION_ID" ]] && [[ "$ROOT_SESSION_ID" != ses_* ]]; then
		fail "--session / OPENCODE_SESSION_ID must look like ses_*"
	fi
	if [[ -n "$ROOT_SESSION_ID" ]]; then
		SESSION_ESTABLISHED=1
	fi
}

shell_escape_join() {
	python3 - "$@" <<'PY'
import shlex
import sys
print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
}

build_opencode_config_content() {
	python3 - "$1" <<'PY'
import json
import sys

steps = int(sys.argv[1])
print(json.dumps({
    "agent": {
        "build": {"steps": steps},
        "general": {"steps": steps},
        "explore": {"steps": steps},
        "plan": {"steps": steps},
    }
}, separators=(",", ":")))
PY
}

bd_show_json() {
	(cd "$ROOT_DIR" && bd show "$1" --json)
}

latest_opencode_session_for_dir() {
	command -v opencode >/dev/null 2>&1 || return 1
	opencode session list --format json --max-count 200 2>/dev/null | python3 -c '
import json
import os
import sys

target = os.path.realpath(sys.argv[1])

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

best_id = ""
best_updated = -1

for item in data:
    sid = item.get("id")
    directory = item.get("directory")
    updated = item.get("updated")
    if not sid or not directory:
        continue
    if os.path.realpath(directory) != target:
        continue
    score = int(updated) if isinstance(updated, (int, float)) else 0
    if score > best_updated:
        best_updated = score
        best_id = sid

print(best_id)
' "$ROOT_DIR"
}

latest_opencode_session_any() {
	command -v opencode >/dev/null 2>&1 || return 1

	local sid
	sid="$(
		opencode session list --format json --max-count 200 2>/dev/null | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

best_id = ""
best_updated = -1
for item in data:
    candidate = item.get("id")
    updated = item.get("updated")
    if not candidate:
        continue
    score = int(updated) if isinstance(updated, (int, float)) else 0
    if score > best_updated:
        best_updated = score
        best_id = candidate

print(best_id)
'
	)"

	if valid_session_id "$sid"; then
		printf '%s\n' "$sid"
		return 0
	fi

	opencode session list --max-count 200 2>/dev/null | python3 -c '
import re
import sys

for line in sys.stdin:
    m = re.match(r"\s*(ses_[A-Za-z0-9_-]+)\b", line)
    if m:
        print(m.group(1))
        raise SystemExit(0)

print("")
'
}

valid_session_id() {
	[[ "$1" == ses_* ]]
}

session_id_from_log() {
	python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
matches = re.findall(r"\bses_[A-Za-z0-9_-]+\b", text)
print(matches[-1] if matches else "")
PY
}

refresh_root_session_id() {
	if [[ -n "$ROOT_SESSION_ID" ]]; then
		SESSION_ESTABLISHED=1
	fi
}

bootstrap_root_session_with_plan() {
	local scope_id="$1"
	local scope_title
	local bootstrap_prompt
	local bootstrap_steps
	local config_json
	local tmp_log
	local run_status
	local discovered
	local session_before
	local session_after

	if [[ "$DRY_RUN" -eq 1 || -n "$SANDBOX_NAME" ]]; then
		return 0
	fi
	if [[ "$BOOTSTRAP_PLAN_SESSION" != "1" ]]; then
		return 0
	fi
	if [[ -n "$ROOT_SESSION_ID" ]]; then
		return 0
	fi

	session_before="$(latest_opencode_session_any || true)"
	scope_title="$(issue_title "$scope_id" 2>/dev/null || true)"
	bootstrap_prompt="Examine Beads issue ${scope_id} (${scope_title}) in ${ROOT_DIR} and devise a concise execution plan. Planning only: do not modify files, do not commit, and do not close issues in this bootstrap run."
	bootstrap_steps="$BOOTSTRAP_PLAN_STEPS"
	config_json="$(build_opencode_config_content "$bootstrap_steps")"
	tmp_log="$(mktemp)"

	log "Bootstrapping OpenCode session with plan agent for ${scope_id}"

	set +e
	(cd "$ROOT_DIR" && env OPENCODE_CONFIG_CONTENT="$config_json" opencode run --dir "$ROOT_DIR" --agent plan "$bootstrap_prompt") 2>&1 | tee "$tmp_log"
	run_status=${PIPESTATUS[0]}
	set -e

	discovered="$(session_id_from_log "$tmp_log" || true)"
	session_after="$(latest_opencode_session_any || true)"

	if ! valid_session_id "$discovered" || [[ "$discovered" == "$session_before" ]]; then
		if valid_session_id "$session_after" && [[ "$session_after" != "$session_before" ]]; then
			discovered="$session_after"
		fi
	fi

	if valid_session_id "$discovered"; then
		ROOT_SESSION_ID="$discovered"
		SESSION_ESTABLISHED=1
		log "Bootstrap session ready: ${ROOT_SESSION_ID}"
		rm -f "$tmp_log"
		return 0
	fi

	rm -f "$tmp_log"
	if [[ "$run_status" -ne 0 ]]; then
		log "WARNING: bootstrap plan run exited non-zero (${run_status}); no session discovered"
	else
		log "WARNING: bootstrap plan run completed but no session id was discovered"
	fi
}

issue_title() {
	bd_show_json "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d[0] if isinstance(d,list) else d; print(o.get("title", ""))'
}

issue_status() {
	bd_show_json "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d[0] if isinstance(d,list) else d; print(o.get("status", ""))'
}

open_direct_child_count() {
	bd_show_json "$1" | python3 -c '
import json
import sys
d = json.load(sys.stdin)
o = d[0] if isinstance(d, list) else d
children = [c for c in (o.get("dependents") or []) if c.get("dependency_type") == "parent-child"]
print(sum(1 for c in children if c.get("status") != "closed"))
'
}

next_ready_descendant() {
	(cd "$ROOT_DIR" && bd ready --parent "$1" --json --limit 100) | python3 -c '
import json
import sys
items = json.load(sys.stdin)
print(items[0].get("id", "") if items else "")
'
}

build_prompt() {
	local issue_id="$1"
	local scope_id="$2"
	local title="$3"

	cat <<EOF
Work Beads issue ${issue_id} (${title}) in ${ROOT_DIR}.

Rules:
- Focus only on issue ${issue_id} (scope root: ${scope_id}).
- Work like a human on the console: inspect the issue, implement changes, run relevant tests/checks, and update Beads status appropriately.
- If ${issue_id} is a parent/epic and cannot be closed directly, do not stay stuck on the parent; identify and process actionable child tasks/branches needed to move the parent toward closure.
- If work is complete and acceptance criteria are met, close the issue.
- If blocked, leave a concise note explaining exactly what is blocked.
- Do not do unrelated work.
EOF
}

run_opencode_for_issue() {
	local issue_id="$1"
	local scope_id="$2"
	local title
	local prompt
	local config_json
	local steps
	local retries_used=0
	local bonus_used=0
	local run_status=0
	local tmp_log
	local status_before
	local status_after
	local progressed=false
	local -a base_cmd
	local -a run_cmd

	title="$(issue_title "$issue_id")"
	prompt="$(build_prompt "$issue_id" "$scope_id" "$title")"
	steps="$OPENCODE_STEPS"

	base_cmd=(opencode run --dir "$ROOT_DIR")
	if [[ -n "$MODEL" ]]; then
		base_cmd+=(--model "$MODEL")
	fi
	if [[ -n "$AGENT" ]]; then
		base_cmd+=(--agent "$AGENT")
	fi
	if [[ -n "$VARIANT" ]]; then
		base_cmd+=(--variant "$VARIANT")
	fi
	if [[ ${#OPENCODE_EXTRA_ARGS[@]} -gt 0 ]]; then
		base_cmd+=("${OPENCODE_EXTRA_ARGS[@]}")
	fi

	refresh_root_session_id
	if [[ -z "$ROOT_SESSION_ID" ]]; then
		bootstrap_root_session_with_plan "$scope_id"
		refresh_root_session_id
	fi

	log "Running issue ${issue_id}: ${title}"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		run_cmd=("${base_cmd[@]}")
		if [[ -n "$ROOT_SESSION_ID" ]]; then
			run_cmd+=(--session "$ROOT_SESSION_ID")
		fi
		run_cmd+=("$prompt")

		config_json="$(build_opencode_config_content "$steps")"
		printf 'DRY RUN: '
		if [[ -n "$SANDBOX_NAME" ]]; then
			local sandbox_cmd
			sandbox_cmd="$(shell_escape_join env "OPENCODE_CONFIG_CONTENT=$config_json" "${run_cmd[@]}")"
			printf '%q ' docker sandbox run "$SANDBOX_NAME" -- -c "$sandbox_cmd"
		else
			printf '%q ' env "OPENCODE_CONFIG_CONTENT=$config_json" "${run_cmd[@]}"
		fi
		printf '\n'
		return 0
	fi

	while true; do
		run_cmd=("${base_cmd[@]}")
		ROOT_RUN_COUNT=$((ROOT_RUN_COUNT + 1))
		refresh_root_session_id

		if [[ "$REQUIRE_SESSION_REUSE" == "1" && "$ROOT_RUN_COUNT" -gt 1 && "$SESSION_ESTABLISHED" -eq 1 && -z "$ROOT_SESSION_ID" ]]; then
			fail "Session reuse required: run ${ROOT_RUN_COUNT} for ${issue_id} lost previously established session id"
		fi

		if [[ "$REQUIRE_SESSION_REUSE" == "1" && "$ROOT_RUN_COUNT" -gt 1 && "$SESSION_ESTABLISHED" -eq 0 && -z "$ROOT_SESSION_ID" ]]; then
			log "WARNING: Session reuse required, but no session id has been discovered yet; continuing without --session"
		fi

		if [[ -n "$ROOT_SESSION_ID" ]]; then
			run_cmd+=(--session "$ROOT_SESSION_ID")
		fi
		run_cmd+=("$prompt")

		config_json="$(build_opencode_config_content "$steps")"
		log "OpenCode run config: issue=${issue_id} steps=${steps} session=${ROOT_SESSION_ID:-new}"
		tmp_log="$(mktemp)"
		status_before="$(issue_status "$issue_id" 2>/dev/null || true)"

		if [[ -n "$SANDBOX_NAME" ]]; then
			local sandbox_cmd
			sandbox_cmd="$(shell_escape_join env "OPENCODE_CONFIG_CONTENT=$config_json" "${run_cmd[@]}")"
			set +e
			(cd "$ROOT_DIR" && docker sandbox run "$SANDBOX_NAME" -- -c "$sandbox_cmd") 2>&1 | tee "$tmp_log"
			run_status=${PIPESTATUS[0]}
			set -e
		else
			set +e
			(cd "$ROOT_DIR" && env OPENCODE_CONFIG_CONTENT="$config_json" "${run_cmd[@]}") 2>&1 | tee "$tmp_log"
			run_status=${PIPESTATUS[0]}
			set -e
		fi

		if [[ -z "$SANDBOX_NAME" ]]; then
			local log_session_id
			log_session_id="$(session_id_from_log "$tmp_log" || true)"
			if valid_session_id "$log_session_id" && [[ "$log_session_id" != "$ROOT_SESSION_ID" ]]; then
				ROOT_SESSION_ID="$log_session_id"
				log "Using OpenCode session: ${ROOT_SESSION_ID}"
			fi
		fi

		refresh_root_session_id

		if grep -Fq "$MAX_STEPS_MESSAGE" "$tmp_log"; then
			status_after="$(issue_status "$issue_id" 2>/dev/null || true)"
			progressed=false
			if [[ -n "$status_before" && -n "$status_after" && "$status_before" != "$status_after" ]]; then
				progressed=true
			fi

			rm -f "$tmp_log"

			if [[ "$progressed" == "true" && "$bonus_used" -lt "$PROGRESS_BONUS_RETRIES" ]]; then
				bonus_used=$((bonus_used + 1))
				steps=$((steps + STEP_RECOVERY_INCREMENT))
				log "OpenCode hit max steps for ${issue_id}; Beads status changed (${status_before} -> ${status_after}), bonus retry ${bonus_used}/${PROGRESS_BONUS_RETRIES} with --steps=${steps}"
				continue
			fi

			if ((retries_used >= MAX_STEP_RECOVERY_ATTEMPTS)); then
				fail "OpenCode hit max steps for ${issue_id} after ${retries_used} retries (plus ${bonus_used} progress-bonus retries)"
			fi

			retries_used=$((retries_used + 1))
			steps=$((steps + STEP_RECOVERY_INCREMENT))
			log "OpenCode hit max steps for ${issue_id}; retry ${retries_used}/${MAX_STEP_RECOVERY_ATTEMPTS} with --steps=${steps}"
			continue
		fi

		rm -f "$tmp_log"
		return "$run_status"
	done
}

process_issue_tree() {
	local root_issue="$1"
	local iteration=0
	local root_status
	local open_children
	local next_issue

	while true; do
		iteration=$((iteration + 1))
		if ((iteration > MAX_ITERATIONS)); then
			fail "Reached max iterations (${MAX_ITERATIONS}) before completion"
		fi

		root_status="$(issue_status "$root_issue")"
		open_children="$(open_direct_child_count "$root_issue")"
		log "Loop iteration ${iteration}: root_status=${root_status} open_direct_children=${open_children}"

		if [[ "$root_status" == "closed" && "$open_children" == "0" ]]; then
			log "Done: ${root_issue} is closed and all direct children are closed."
			return 0
		fi

		next_issue="$(next_ready_descendant "$root_issue")"
		if [[ -z "$next_issue" ]]; then
			if [[ "$open_children" == "0" && "$root_status" != "closed" ]]; then
				next_issue="$root_issue"
			else
				log "No ready descendants under ${root_issue}; running root issue to unblock the tree."
				next_issue="$root_issue"
			fi
		fi

		run_opencode_for_issue "$next_issue" "$root_issue"

		if [[ "$DRY_RUN" -eq 1 ]]; then
			return 0
		fi
	done
}

main() {
	parse_args "$@"

	if [[ -n "$LOOP_LOG_FILE" ]]; then
		mkdir -p "$(dirname "$LOOP_LOG_FILE")"
		exec > >(tee -a "$LOOP_LOG_FILE") 2>&1
		log "Writing loop output to: ${LOOP_LOG_FILE}"
	fi

	require_command bd
	require_command python3
	if [[ -n "$SANDBOX_NAME" ]]; then
		require_command docker
	else
		require_command opencode
	fi

	if ! (cd "$ROOT_DIR" && bd show "$ISSUE_ID" --json >/dev/null 2>&1); then
		fail "Unable to load issue ${ISSUE_ID}"
	fi

	log "Repository: ${ROOT_DIR}"
	log "Root issue: ${ISSUE_ID}"

	process_issue_tree "$ISSUE_ID"
}

main "$@"
