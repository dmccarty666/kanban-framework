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
#
# Status: DRAFT — non-invasive, intended to be run against test projects.
# DO NOT run against hermes-memory while Phase 6 is in flight.

set -euo pipefail

FRAMEWORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER_SCRIPT="${FRAMEWORK_DIR}/scripts/render-soul.py"
SCHEMA_PATH="${FRAMEWORK_DIR}/schema/project.schema.yaml"
HEARTBEAT_SH="${FRAMEWORK_DIR}/scripts/heartbeat.sh"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

PROJECT_DIR=""
DRY_RUN=0
PARTIAL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --partial) PARTIAL=1; shift ;;
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
    echo "  Usage: $0 <project-dir> [--dry-run] [--partial]" >&2
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

echo "[1/7] Validating $PROJECT_YAML against schema..."
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
echo "[2/7] Checking human-input files..."
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
echo "[3/7] Rendering SOULs from templates..."
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
echo "[4/7] Initializing orchestrator directory..."
ORCH_DIR="$PROJECT_DIR/orchestrator"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would create $ORCH_DIR/{GOAL,STATE,HISTORY}.md"
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
fi

# ---------------------------------------------------------------------------
# Step 5: Install project script shims
# ---------------------------------------------------------------------------

echo
echo "[5/7] Installing project script shims..."
SCRIPTS_DIR="$PROJECT_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

# Project heartbeat.sh is a thin wrapper that invokes the framework version
PROJ_HB="$SCRIPTS_DIR/heartbeat.sh"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  would create $PROJ_HB (shim invoking framework heartbeat)"
else
    cat > "$PROJ_HB" <<'EOF'
#!/usr/bin/env bash
# heartbeat.sh — project-specific shim that delegates to the framework version.
#
# This script just sets PROJECT_DIR and invokes the framework heartbeat.
# Do not put project-specific logic here — modify project.yaml instead.

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec env PROJECT_DIR="$PROJECT_DIR" \
    ~/.hermes/PROJECTS/.framework/scripts/heartbeat.sh "$@"
EOF
    chmod +x "$PROJ_HB"
    echo "  ✓ wrote $PROJ_HB"
fi

# ---------------------------------------------------------------------------
# Step 6: Create profiles + install SOULs
# ---------------------------------------------------------------------------

if [[ "$PARTIAL" -eq 1 ]]; then
    echo
    echo "[6/7] SKIPPED (--partial) — would create 7 Hermes profiles + install SOULs"
    echo "       Run again without --partial when ready."
else
    echo
    echo "[6/7] Creating Hermes profiles + installing SOULs..."
    ROLES=(orchestrator planner architect developer qa docs auditor)
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
    echo
    echo "  NOTE: profile model/provider config is NOT auto-set here. Use:"
    echo "    hermes config set profiles.${PROJECT_SLUG}-<role>.provider <provider>"
    echo "    hermes config set profiles.${PROJECT_SLUG}-<role>.model <model>"
    echo "  per project.yaml > models.<role>."
fi

# ---------------------------------------------------------------------------
# Step 7: Register cron job
# ---------------------------------------------------------------------------

if [[ "$PARTIAL" -eq 1 ]]; then
    echo
    echo "[7/7] SKIPPED (--partial) — would register cron job"
else
    echo
    echo "[7/7] Cron job registration..."
    JOB_NAME="${PROJECT_SLUG}-orchestrator"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  would register cron job: $JOB_NAME"
        echo "    schedule: $CRON_SCHEDULE"
        echo "    script:   $PROJ_HB"
        echo "    workdir:  $PROJECT_DIR"
    else
        echo "  ⚠ Manual step required:"
        echo "    Run from within a Hermes session:"
        echo "      cronjob(action='create', name='$JOB_NAME', script='$PROJ_HB',"
        echo "              schedule='$CRON_SCHEDULE', workdir='$PROJECT_DIR',"
        echo "              no_agent=True, deliver='local')"
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
echo "  3. Set per-role provider/model via 'hermes config set' (see step 6 output)"
echo "  4. Verify orchestrator dry-run:"
echo "       PROJECT_DIR=$PROJECT_DIR $HEARTBEAT_SH --dry-run --verbose"
echo "  5. Register the cron job (see step 7 output)"
echo "  6. Trigger an initial tick to verify everything works"
