#!/usr/bin/env bash
# bootstrap.sh — one-shot scaffolding for a new kanban-orchestrated project.
#
# Reads <project>/project.yaml and creates:
#   - <project>/orchestrator/{GOAL,STATE,HISTORY}.md (rendered from yaml)
#   - <project>/souls/<slug>-<role>.md (rendered from templates)
#   - <project>/scripts/heartbeat.sh    (thin shim)
#   - <project>/scripts/install-souls.sh (thin shim)
#   - ~/.hermes/profiles/<slug>-<role>/   (created via `hermes profile create`)
#   - Cron job for the orchestrator (via cronjob create)
#
# Usage:
#   bootstrap.sh <project-dir>             # use <project-dir>/project.yaml
#   bootstrap.sh <project-dir> --dry-run   # print what would happen, no changes
#   bootstrap.sh <project-dir> --partial   # don't create cron, don't install
#                                          # profiles — useful for staging
#   bootstrap.sh <project-dir> --install-cron
#                                          # also register the cron job in the
#                                          # user's crontab (off by default)
#   bootstrap.sh <project-dir> --no-models # skip auto-setting per-role
#                                          # provider/model in ~/.hermes/config.yaml
#
# Status: DRAFT — non-invasive, intended to be run against test projects.
# DO NOT run against hermes-memory while Phase 6 is in flight.

set -euo pipefail

FRAMEWORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER_SCRIPT="${FRAMEWORK_DIR}/scripts/render-soul.py"
SCHEMA_PATH="${FRAMEWORK_DIR}/schema/project.schema.yaml"
HEARTBEAT_SH="${FRAMEWORK_DIR}/scripts/heartbeat.sh"

# Canonical 7 roles — must match schema/project.schema.yaml:models
ROLES=(orchestrator planner architect developer qa docs auditor)

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

PROJECT_DIR=""
DRY_RUN=0
PARTIAL=0
INSTALL_CRON=0
NO_MODELS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --partial) PARTIAL=1; shift ;;
        --install-cron) INSTALL_CRON=1; shift ;;
        --no-models) NO_MODELS=1; shift ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "Unknown arg: $1" >&2
            exit 2
            ;;
        *)
            if [[ -z "$PROJECT_DIR" ]]; then
                PROJECT_DIR="$1"
            else
                echo "Unexpected arg: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    echo "ERROR: project directory required" >&2
    echo "  Usage: $0 <project-dir> [--dry-run] [--partial] [--install-cron] [--no-models]" >&2
    exit 2
fi

PROJECT_DIR="$(realpath "$PROJECT_DIR")"
PROJECT_YAML="${PROJECT_DIR}/project.yaml"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: project directory does not exist: $PROJECT_DIR" >&2
    exit 2
fi
if [[ ! -f "$PROJECT_YAML" ]]; then
    echo "ERROR: project.yaml missing: $PROJECT_YAML" >&2
    echo "  Copy one of the examples:" >&2
    echo "    cp ${FRAMEWORK_DIR}/examples/financial-app.yaml $PROJECT_YAML" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Step 1: Validate project.yaml against schema
# ---------------------------------------------------------------------------

echo "[1/8] Validating $PROJECT_YAML against schema..."
python3 -c "
import yaml, jsonschema, sys
schema = yaml.safe_load(open('$SCHEMA_PATH'))
data = yaml.safe_load(open('$PROJECT_YAML'))
try:
    jsonschema.validate(data, schema)
    print('  ✓ schema valid')
except jsonschema.ValidationError as e:
    print(f'  ✗ FAILED at {list(e.path)}: {e.message}', file=sys.stderr)
    sys.exit(1)
"

# Extract key values
read_yaml() {
    local default="${2:-}"
    python3 -c "
import yaml
data = yaml.safe_load(open('$PROJECT_YAML'))
keys = '$1'.split('.')
val = data
try:
    for k in keys:
        val = val[k]
    print(val)
except (KeyError, TypeError):
    print('$default')
"
}

PROJECT_SLUG=$(read_yaml "project.slug")
PROJECT_DIR_NAME=$(read_yaml "project.dir_name" "$PROJECT_SLUG")
PROJECT_NAME=$(read_yaml "project.name")
CRON_SCHEDULE=$(read_yaml "orchestrator.cron_schedule" "*/30 * * * *")

echo "  Project: $PROJECT_NAME (slug=$PROJECT_SLUG, dir_name=$PROJECT_DIR_NAME)"
echo "  Cron schedule: $CRON_SCHEDULE"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "=== DRY RUN — would perform the following ==="
fi

# ---------------------------------------------------------------------------
# Step 2: Verify human-input files exist
# ---------------------------------------------------------------------------

echo
echo "[2/8] Checking human-input files..."
missing_inputs=0
for f in PROJECT.md prd.md TDD.md Plan.md EPICS.md; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
        echo "  ✓ $f"
    else
        echo "  ✗ $f (MISSING — author this before running the orchestrator)"
        missing_inputs=$((missing_inputs + 1))
    fi
done
if [[ $missing_inputs -gt 0 ]]; then
    echo "  ⚠ $missing_inputs input file(s) missing — bootstrap will continue but orchestrator won't run cleanly until they exist."
fi

# ---------------------------------------------------------------------------
# Step 3: Render SOULs
# ---------------------------------------------------------------------------

echo
echo "[3/8] Rendering SOULs from templates..."
SOULS_DIR="$PROJECT_DIR/souls"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would render → $SOULS_DIR/"
else
    python3 "$RENDER_SCRIPT" --all "$PROJECT_YAML" --output-dir "$SOULS_DIR"
fi

# ---------------------------------------------------------------------------
# Step 4: Initialize orchestrator dir
# ---------------------------------------------------------------------------

echo
echo "[4/8] Initializing orchestrator directory..."
ORCH_DIR="$PROJECT_DIR/orchestrator"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would create $ORCH_DIR/{GOAL,STATE,HISTORY}.md"
    echo "  would symlink ~/.hermes/PROJECTS/$PROJECT_SLUG -> $PROJECT_DIR"
else
    mkdir -p "$ORCH_DIR"
    # GOAL.md is rendered from yaml goal section (TODO: dedicated GOAL template)
    # For now we leave it for the user to author manually if missing
    if [[ ! -f "$ORCH_DIR/GOAL.md" ]]; then
        cat > "$ORCH_DIR/GOAL.md" <<EOF
# GOAL — $PROJECT_NAME

**Set by:** (your name)
**Date set:** $(date -I)
**Project:** $PROJECT_NAME
**Status:** Active

---

## Headline

$(read_yaml "goal.headline" "")

## Definition of done

(Auto-generated from project.yaml. Edit as needed.)

EOF
        echo "  ✓ wrote GOAL.md (you should review and customize)"
    else
        echo "  • GOAL.md exists, leaving alone"
    fi

    if [[ ! -f "$ORCH_DIR/STATE.md" ]]; then
        cat > "$ORCH_DIR/STATE.md" <<EOF
# $PROJECT_NAME Orchestrator State

**State:** IDLE
**Current phase:** 0
**Phases done:** []
**Phases in flight:** []
**Phases pending:** []

**Last heartbeat:** (never)
**Last action:** "initialized via bootstrap"
**Actions this run:** 0
**Tick count since bootstrap:** 0

**Side issues:**

**Recent escalations sent:**
EOF
        echo "  ✓ wrote STATE.md (IDLE)"
    else
        echo "  • STATE.md exists, leaving alone"
    fi

    if [[ ! -f "$ORCH_DIR/HISTORY.md" ]]; then
        echo "# Orchestrator History — $PROJECT_NAME" > "$ORCH_DIR/HISTORY.md"
        echo "  ✓ wrote HISTORY.md (empty)"
    else
        echo "  • HISTORY.md exists, leaving alone"
    fi

    # Symlink ~/.hermes/PROJECTS/<slug> -> $PROJECT_DIR.
    # Required because the orchestrator + worker SOULs read GOAL/STATE/HISTORY
    # from the canonical path ~/.hermes/PROJECTS/<slug>/orchestrator/. The
    # symlink is force-updated so re-runs of bootstrap are idempotent.
    HERMES_PROJECTS_DIR="$HOME/.hermes/PROJECTS"
    mkdir -p "$HERMES_PROJECTS_DIR"
    ln -sfn "$PROJECT_DIR" "$HERMES_PROJECTS_DIR/$PROJECT_SLUG"
    echo "  ✓ symlinked $HERMES_PROJECTS_DIR/$PROJECT_SLUG -> $PROJECT_DIR"
fi

# ---------------------------------------------------------------------------
# Step 5: Install project script shims
# ---------------------------------------------------------------------------

echo
echo "[5/8] Installing project script shims..."
SCRIPTS_DIR="$PROJECT_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

# Project heartbeat.sh is a thin wrapper that invokes the framework version.
# We use an unquoted heredoc (<<EOF, NOT <<'EOF') so $FRAMEWORK_DIR gets
# expanded at bootstrap time to the absolute framework path. That bakes the
# right path into the shim — no runtime dependency on the framework being at
# any particular location.
PROJ_HB="$SCRIPTS_DIR/heartbeat.sh"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would create $PROJ_HB (shim invoking framework heartbeat)"
    echo "  shim target: ${FRAMEWORK_DIR}/scripts/heartbeat.sh"
else
    cat > "$PROJ_HB" <<EOF
#!/usr/bin/env bash
# heartbeat.sh — project-specific shim that delegates to the framework version.
#
# This script just sets PROJECT_DIR and invokes the framework heartbeat.
# Do not put project-specific logic here — modify project.yaml instead.
# The framework path is baked in at bootstrap time so the shim has no
# runtime dependency on the framework being at any particular location.

set -euo pipefail
PROJECT_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
exec env PROJECT_DIR="\$PROJECT_DIR" \\
    "${FRAMEWORK_DIR}/scripts/heartbeat.sh" "\$@"
EOF
    chmod +x "$PROJ_HB"
    echo "  ✓ wrote $PROJ_HB (delegates to ${FRAMEWORK_DIR}/scripts/heartbeat.sh)"
fi

# ---------------------------------------------------------------------------
# Step 6: Create profiles + install SOULs
# ---------------------------------------------------------------------------

if [[ "$PARTIAL" -eq 1 ]]; then
    echo
    echo "[6/8] SKIPPED (--partial) — would create 7 Hermes profiles + install SOULs"
    echo "       Run again without --partial when ready."
else
    echo
    echo "[6/8] Creating Hermes profiles + installing SOULs..."
    for role in "${ROLES[@]}"; do
        profile="${PROJECT_SLUG}-${role}"
        profile_dir="${HOME}/.hermes/profiles/${profile}"
        soul_src="$SOULS_DIR/${profile}.md"

        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  would create profile $profile (model from yaml) + install $soul_src"
            continue
        fi

        if [[ ! -f "$soul_src" ]]; then
            echo "  ⚠ $role: SOUL not rendered (template missing) — skipping profile"
            continue
        fi
        mkdir -p "$profile_dir"
        cp -f "$soul_src" "$profile_dir/SOUL.md"
        echo "  ✓ $profile  ($(wc -l < "$profile_dir/SOUL.md") line SOUL installed)"
    done
    # Per-role provider/model is auto-set in Step 7 (unless --no-models).
fi

# ---------------------------------------------------------------------------
# Step 7: Auto-set per-role provider/model in ~/.hermes/config.yaml
# ---------------------------------------------------------------------------

if [[ "$PARTIAL" -eq 1 || "$NO_MODELS" -eq 1 ]]; then
    echo
    echo "[7/8] SKIPPED — per-role provider/model not auto-set (--partial or --no-models)"
else
    echo
    echo "[7/8] Setting per-role provider/model in ~/.hermes/config.yaml..."
    set_count=0
    skip_count=0
    for role in "${ROLES[@]}"; do
        provider=$(read_yaml "models.${role}.provider" "")
        model=$(read_yaml "models.${role}.model" "")
        profile="${PROJECT_SLUG}-${role}"
        if [[ -z "$provider" || -z "$model" ]]; then
            echo "  ⚠ $role: missing provider/model in project.yaml — skipping"
            skip_count=$((skip_count + 1))
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  would set profiles.${profile}.provider = $provider"
            echo "  would set profiles.${profile}.model    = $model"
            set_count=$((set_count + 1))
            continue
        fi
        # Prefer `hermes config set` when the CLI is available; otherwise
        # edit ~/.hermes/config.yaml directly via PyYAML.
        if command -v hermes >/dev/null 2>&1; then
            hermes config set "profiles.${profile}.provider" "$provider" >/dev/null
            hermes config set "profiles.${profile}.model"    "$model"    >/dev/null
            # NOTE: `hermes config set` is scalar-only; it cannot emit a YAML
            # list for `enabled_toolsets`. The orchestrator's toolset is set
            # via the PyYAML fallback below. When the CLI gains list support,
            # add an injection here too.
        else
            python3 - "$HOME/.hermes/config.yaml" "$profile" "$provider" "$model" "$role" <<'PYEOF'
import sys, os, yaml
cfg_path, profile, provider, model, role = sys.argv[1:6]
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}
profiles = cfg.setdefault('profiles', {})
p = profiles.setdefault(profile, {})
p['provider'] = provider
p['model']    = model
# F-5: orchestrator profile must declare enabled_toolsets per the SOUL
# section "Tool surface" (souls-template/orchestrator.md.tmpl). Without
# these, send_message is not actually available at runtime and escalations
# silently fall back to HISTORY.md (see SOUL section 8.1). Re-runs
# overwrite the list, so bootstrap stays idempotent. Scope: orchestrator
# role only — other roles' toolset defaults are left unchanged for now.
if role == 'orchestrator':
    p['enabled_toolsets'] = [
        'kanban', 'file', 'terminal', 'send_message', 'hermes_memory',
    ]
# Atomic write: tmp + rename, so a crash mid-write doesn't truncate config.
tmp = cfg_path + '.tmp'
with open(tmp, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
os.replace(tmp, cfg_path)
PYEOF
        fi
        echo "  ✓ $profile  provider=$provider  model=$model"
        set_count=$((set_count + 1))
    done
    echo "  → $set_count role(s) configured, $skip_count skipped"
fi

# ---------------------------------------------------------------------------
# Step 8: Register cron job
# ---------------------------------------------------------------------------

if [[ "$PARTIAL" -eq 1 ]]; then
    echo
    echo "[8/8] SKIPPED (--partial) — would register cron job"
else
    echo
    echo "[8/8] Cron job registration..."
    JOB_NAME="${PROJECT_SLUG}-orchestrator"
    # Marker comment + schedule line. The marker makes re-runs of bootstrap
    # idempotent: a subsequent --install-cron removes the previous entry by
    # its marker and inserts the new one.
    JOB_MARKER="# hermes-kanban:${JOB_NAME}"
    mkdir -p "$HOME/.hermes/logs"
    JOB_LINE="${JOB_MARKER}
${CRON_SCHEDULE} ${PROJ_HB} >> ${HOME}/.hermes/logs/${PROJECT_SLUG}-orchestrator.log 2>&1"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  would register cron job: $JOB_NAME"
        echo "    schedule: $CRON_SCHEDULE"
        echo "    script:   $PROJ_HB"
        echo "    workdir:  $PROJECT_DIR"
        echo "    logfile:  $HOME/.hermes/logs/${PROJECT_SLUG}-orchestrator.log"
        echo "  copy-paste crontab entry:"
        printf '%s\n' "$JOB_LINE" | sed 's/^/    /'
    elif [[ "$INSTALL_CRON" -eq 1 ]]; then
        # Read the existing crontab (empty if none), strip any previous
        # entry for this job by its marker, then append the new one.
        # We use `|| true` + a brace group because `set -e` + `pipefail`
        # would otherwise kill the install when there's no crontab yet.
        EXISTING=$(crontab -l 2>/dev/null || true)
        {
            printf '%s\n' "$EXISTING" | grep -v -F "$JOB_MARKER" || true
            printf '%s\n' "$JOB_LINE"
        } | crontab -
        echo "  ✓ installed cron job: $JOB_NAME (schedule: $CRON_SCHEDULE)"
        echo "    logfile: $HOME/.hermes/logs/${PROJECT_SLUG}-orchestrator.log"
    else
        echo "  Copy-paste to register manually, or re-run with --install-cron:"
        echo
        printf '%s\n' "$JOB_LINE" | sed 's/^/    /'
    fi
fi

echo
echo "=== BOOTSTRAP COMPLETE ==="
echo
echo "Next steps:"
if [[ $missing_inputs -gt 0 ]]; then
    echo "  1. Author the missing input files (PROJECT.md, prd.md, TDD.md, etc.)"
fi
echo "  2. Review $ORCH_DIR/GOAL.md and customize as needed"
if [[ "$PARTIAL" -eq 1 || "$NO_MODELS" -eq 1 ]]; then
    echo "  3. Set per-role provider/model manually (was skipped during bootstrap):"
    echo "       for each role in: ${ROLES[*]}"
    echo "       hermes config set profiles.${PROJECT_SLUG}-<role>.provider <provider>"
    echo "       hermes config set profiles.${PROJECT_SLUG}-<role>.model <model>"
fi
if [[ "$PARTIAL" -eq 0 && "$INSTALL_CRON" -eq 0 ]]; then
    echo "  4. Register the cron job: copy-paste the line from step 8 above,"
    echo "     or re-run bootstrap with --install-cron"
fi
echo "  5. Verify orchestrator dry-run:"
echo "       PROJECT_DIR=$HOME/.hermes/PROJECTS/$PROJECT_SLUG $HEARTBEAT_SH --dry-run --verbose"
echo "  6. Trigger an initial tick to verify everything works"
