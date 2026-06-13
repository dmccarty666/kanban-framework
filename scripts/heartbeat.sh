#!/usr/bin/env bash
# heartbeat.sh — generic single-tick driver for any kanban-orchestrated project.
#
# This script is the framework version. Per-project scripts call it via:
#   ~/.hermes/PROJECTS/<slug>/scripts/heartbeat.sh
# which is a thin shim that just invokes this one with PROJECT_DIR set.
#
# Reads ~/.hermes/PROJECTS/<slug>/project.yaml for orchestrator config:
#   project.slug                  → profile name (<slug>-orchestrator)
#   orchestrator.heartbeat_cooldown_minutes  → loop guard
#   orchestrator.hard_timeout_seconds        → tick timeout
#
# Invoked by cron every (project.yaml: orchestrator.cron_schedule).
# Spawns a fresh `hermes -p <slug>-orchestrator chat -q "..."` and a hard timeout.
# The SOUL governs behavior; this script is just plumbing.
#
# Required environment:
#   PROJECT_DIR  — absolute path to the project directory under
#                  ~/.hermes/PROJECTS/<slug>/. The framework shim sets this.
#
# Manual invocations:
#   PROJECT_DIR=~/.hermes/PROJECTS/fin ./heartbeat.sh          # run once
#   PROJECT_DIR=~/.hermes/PROJECTS/fin ./heartbeat.sh --dry-run
#   PROJECT_DIR=~/.hermes/PROJECTS/fin ./heartbeat.sh --verbose
#
# Exit codes:
#   0 — tick ran cleanly
#   1 — internal error
#   2 — invocation error (bad args, missing PROJECT_DIR, missing project.yaml)
#   3 — guard tripped (lock file present, cooldown not met) — NOT an error

set -euo pipefail

# Ensure hermes CLI is on PATH (cron uses minimal PATH; user shells source .bashrc)
export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"

# Source ~/.hermes/.env if present (API keys live there; cron doesn't inherit them)
if [[ -f "$HOME/.hermes/.env" ]]; then
    set -a
    source "$HOME/.hermes/.env"
    set +a
fi

# ---------------------------------------------------------------------------
# Resolve PROJECT_DIR
# ---------------------------------------------------------------------------

if [[ -z "${PROJECT_DIR:-}" ]]; then
    echo "ERROR: PROJECT_DIR not set" >&2
    echo "  Usage: PROJECT_DIR=<abs path> $0" >&2
    exit 2
fi
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: PROJECT_DIR does not exist: $PROJECT_DIR" >&2
    exit 2
fi
PROJECT_YAML="${PROJECT_DIR}/project.yaml"
if [[ ! -f "$PROJECT_YAML" ]]; then
    echo "ERROR: project.yaml missing: $PROJECT_YAML" >&2
    exit 2
fi

# Use python to parse yaml — bash + sed isn't reliable for nested keys
read_yaml() {
    local key="$1"
    local default="${2:-}"
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$PROJECT_YAML'))
keys = '$key'.split('.')
val = data
try:
    for k in keys:
        val = val[k]
    print(val)
except (KeyError, TypeError):
    print('$default')
" 2>/dev/null
}

PROJECT_SLUG=$(read_yaml "project.slug")
PROJECT_DIR_NAME=$(read_yaml "project.dir_name" "$PROJECT_SLUG")
COOLDOWN_MIN=$(read_yaml "orchestrator.heartbeat_cooldown_minutes" "10")
HARD_TIMEOUT_SECONDS=$(read_yaml "orchestrator.hard_timeout_seconds" "900")

if [[ -z "$PROJECT_SLUG" ]]; then
    echo "ERROR: could not read project.slug from $PROJECT_YAML" >&2
    exit 2
fi

ORCHESTRATOR_PROFILE="${PROJECT_SLUG}-orchestrator"
ORCH_DIR="${PROJECT_DIR}/orchestrator"
# Lock-file cleanup contract:
#   heartbeat.sh OWNS the .lock file. The trap on EXIT below removes it.
#   The orchestrator agent MUST NOT `rm` the lock directly — the cron
#   approvals.cron_mode policy may deny the `rm`, and even if it passes,
#   racing the trap can cause spurious "no lock" log lines.
#   To release the lock, the agent should simply exit; the trap handles it.
LOCK_FILE="${ORCH_DIR}/.lock"
LOG_FILE="${ORCH_DIR}/heartbeat.log"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

dry_run=0
verbose=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --verbose) verbose=1 ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [[ ! -d "$ORCH_DIR" ]]; then
    echo "ERROR: orchestrator dir missing: $ORCH_DIR" >&2
    exit 1
fi

if [[ ! -f "${ORCH_DIR}/GOAL.md" ]]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: skipped (no GOAL.md)" >> "$LOG_FILE"
    exit 0
fi

# Lock guard — if another tick is in progress, bail. After 30 min, take over.
if [[ -f "$LOCK_FILE" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE") ))
    if [[ $lock_age -lt 1800 ]]; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: skipped (lock held, age ${lock_age}s)" >> "$LOG_FILE"
        exit 3
    fi
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: stale lock removed (age ${lock_age}s)" >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
fi

# ---------------------------------------------------------------------------
# Set up orchestrator profile symlinks
# ---------------------------------------------------------------------------

# The orchestrator SOUL resolves ~ relative to the subprocess $HOME, not this
# script's $HOME. Symlink GOAL/STATE/HISTORY so the orchestrator finds them.
_set_orchestrator_symlinks() {
    local profile_dir="${HOME}/.hermes/profiles/${ORCHESTRATOR_PROFILE}"
    mkdir -p "$profile_dir"
    ln -sf "${ORCH_DIR}/GOAL.md"    "${profile_dir}/GOAL.md"
    ln -sf "${ORCH_DIR}/STATE.md"   "${profile_dir}/STATE.md"
    ln -sf "${ORCH_DIR}/HISTORY.md" "${profile_dir}/HISTORY.md"
}

# ---------------------------------------------------------------------------
# Compose the prompt (stable, generic — SOUL.md does the heavy lifting)
# ---------------------------------------------------------------------------

read -r -d '' PROMPT <<EOF || true
You are the ${PROJECT_SLUG}-orchestrator. Run one tick per your SOUL.md.

Workflow:
  1. Read orchestrator/GOAL.md and orchestrator/STATE.md (under
     ~/.hermes/PROJECTS/${PROJECT_DIR_NAME}/).
  2. Check cooldown (last_heartbeat > ${COOLDOWN_MIN} min ago).
  3. Acquire the lock file (already touched by the heartbeat script —
     verify it exists; if not, create it).
  4. Inspect the board (hermes kanban ls / show / diagnostics).
  5. Decide ONE primary action per the state machine.
  6. Identify any side-state issues per SOUL §4.
  7. Take at most the configured per-tick action budget in priority order.
  8. Update STATE.md (new heartbeat, new state if transitioned, current side
     issues).
  9. Append exactly one entry to HISTORY.md.
 10. Exit — heartbeat.sh owns the .lock file. The trap on its EXIT
     removes the lock — never delete the lock yourself.
     (Doing so races the trap and may also be denied by the
     approvals.cron_mode policy that cron-spawned runs inherit.
     If the lock is ever stale, log it to STATE.md and let the next
     heartbeat.sh cycle handle it.)
 11. Exit.

Stay within your tool surface (SOUL tool-surface section). When in doubt,
escalate via send_message. Never auto-approve human decisions. Never write
code or modify Plan/PRD/TDD/ADR/GOAL files.

If anything is unclear or the state file doesn't parse cleanly, append a
HISTORY entry noting the issue, ping the human (urgency=attention), and exit. (Heartbeat.sh owns the .lock via its EXIT trap — never delete it yourself.)
EOF

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------

if [[ $dry_run -eq 1 ]]; then
    echo "Would run:"
    echo "  hermes -p ${ORCHESTRATOR_PROFILE} chat -q '<prompt>' (timeout=${HARD_TIMEOUT_SECONDS}s)"
    if [[ $verbose -eq 1 ]]; then
        echo
        echo "Prompt:"
        echo "$PROMPT"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Run the tick
# ---------------------------------------------------------------------------

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT
_set_orchestrator_symlinks

tick_started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
echo "$tick_started tick: starting (project=${PROJECT_SLUG})" >> "$LOG_FILE"

set +e
timeout "${HARD_TIMEOUT_SECONDS}" \
    hermes -p "${ORCHESTRATOR_PROFILE}" chat -q "$PROMPT" \
    >> "$LOG_FILE" 2>&1
exit_code=$?
set -e

tick_ended=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

case $exit_code in
    0)   echo "$tick_ended tick: completed cleanly" >> "$LOG_FILE" ;;
    124) echo "$tick_ended tick: TIMED OUT after ${HARD_TIMEOUT_SECONDS}s" >> "$LOG_FILE" ;;
    *)   echo "$tick_ended tick: hermes exited with code $exit_code" >> "$LOG_FILE" ;;
esac

exit $exit_code
