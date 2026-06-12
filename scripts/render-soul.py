#!/usr/bin/env python3
"""
render-soul.py — render a single SOUL template against a project.yaml.

Usage:
    render-soul.py <template> <project.yaml> [--output <path>]
    render-soul.py --all <project.yaml> [--output-dir <dir>]
    render-soul.py --check <project.yaml> --against <souls-dir>

Modes:
    Single render:   --template <name> rendered against yaml, to stdout or --output
    Render-all:      all 7 SOUL templates rendered into a target directory
    Check / diff:    render-all to memory and compare against an existing souls/
                     directory. Useful for verifying hand-written SOULs match
                     what templates would render. Exit 0 = match, 1 = differ.

Requires: jinja2, pyyaml, jsonschema (for validation).
"""
from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
    from jinja2 import Environment, FileSystemLoader, StrictUndefined  # type: ignore
    import jsonschema  # type: ignore
except ImportError as e:
    print(f"ERROR: missing dependency: {e}", file=sys.stderr)
    print("  Install with: pip install jinja2 pyyaml jsonschema", file=sys.stderr)
    sys.exit(2)


FRAMEWORK_DIR = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = FRAMEWORK_DIR / "souls-template"
SCHEMA_PATH = FRAMEWORK_DIR / "schema" / "project.schema.yaml"

# Map role → template filename
ROLES = ["orchestrator", "planner", "architect", "developer", "qa", "docs", "auditor"]


def normalize_paths(data):
    # Strip trailing slashes from the standard path keys in the
    # "paths" mapping, in place.
    #
    # Why: rendered SOULs are read by humans and by tools that build
    # site URLs by concatenating paths (e.g. source_root + "/build/...").
    # A trailing slash on source_root / test_root / docs_root would
    # produce a double-slash like "site//build/..." in the output.
    # Doing it at load time means every downstream render path sees
    # clean paths. We intentionally leave the root "/" alone (rstrip
    # is a no-op on a single slash) and we leave empty strings alone.
    paths = data.get("paths")
    if not isinstance(paths, dict):
        return
    for key in ("source_root", "test_root", "docs_root",
                "adr_root", "data_root", "repo_root"):
        v = paths.get(key)
        if isinstance(v, str) and v != "/" and v.endswith("/"):
            paths[key] = v.rstrip("/")

def load_project_yaml(path: Path) -> dict:
    """Load and validate a project.yaml against the schema."""
    if not path.exists():
        raise SystemExit(f"ERROR: project.yaml not found: {path}")
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: project.yaml is not a mapping: {path}")
    # Normalize path strings (strip trailing slashes) BEFORE schema validation
    # so the validated values match what gets rendered.
    normalize_paths(data)
    if SCHEMA_PATH.exists():
        schema = yaml.safe_load(SCHEMA_PATH.read_text())
        try:
            jsonschema.validate(data, schema)
        except jsonschema.ValidationError as e:
            raise SystemExit(
                f"ERROR: project.yaml failed schema validation\n"
                f"  path: {list(e.path)}\n"
                f"  message: {e.message}"
            )
    return data


def make_env() -> Environment:
    """Create a Jinja2 environment configured for SOUL templates."""
    return Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        undefined=StrictUndefined,    # fail loudly on missing keys
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )


def render_role(role: str, data: dict, env: Environment | None = None) -> str | None:
    """Render the SOUL for a single role. Returns None if template is missing
    (not all 7 templates exist yet — see souls-template/PROGRESS.md)."""
    if env is None:
        env = make_env()
    tmpl_path = TEMPLATE_DIR / f"{role}.md.tmpl"
    if not tmpl_path.exists():
        return None
    tmpl = env.get_template(f"{role}.md.tmpl")
    return tmpl.render(**data)


def cmd_render_one(args) -> int:
    data = load_project_yaml(Path(args.yaml))
    text = render_role(args.template, data)
    if text is None:
        print(f"ERROR: template not found: {args.template}.md.tmpl", file=sys.stderr)
        return 2
    if args.output:
        Path(args.output).write_text(text)
        print(f"Rendered → {args.output} ({len(text)} bytes)")
    else:
        sys.stdout.write(text)
    return 0


def cmd_render_all(args) -> int:
    data = load_project_yaml(Path(args.yaml))
    slug = data["project"]["slug"]
    out_dir = Path(args.output_dir) if args.output_dir else (
        Path.home() / ".hermes" / "PROJECTS" /
        data["project"].get("dir_name", slug) / "souls"
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    env = make_env()
    rendered = 0
    skipped = 0
    for role in ROLES:
        text = render_role(role, data, env)
        if text is None:
            print(f"  [skip] {role}: template not yet written")
            skipped += 1
            continue
        target = out_dir / f"{slug}-{role}.md"
        target.write_text(text)
        try:
            display = str(target.relative_to(Path.home()))
            display = f"~/{display}"
        except ValueError:
            display = str(target)
        print(f"  [ok]   {display} ({len(text)} bytes)")
        rendered += 1
    print(f"\nRendered {rendered}/{len(ROLES)} SOULs ({skipped} skipped — template missing).")
    return 0 if rendered > 0 else 1


def cmd_check(args) -> int:
    """Render in memory and diff each rendered SOUL against an existing one."""
    data = load_project_yaml(Path(args.yaml))
    slug = data["project"]["slug"]
    against = Path(args.against)
    if not against.is_dir():
        print(f"ERROR: --against must be a directory: {against}", file=sys.stderr)
        return 2
    env = make_env()
    diffs = 0
    missing = 0
    for role in ROLES:
        existing = against / f"{slug}-{role}.md"
        rendered = render_role(role, data, env)
        if rendered is None:
            print(f"  [skip]    {role}: template not yet written")
            continue
        if not existing.exists():
            print(f"  [missing] {existing} (would be created)")
            missing += 1
            continue
        existing_text = existing.read_text()
        if existing_text == rendered:
            print(f"  [match]   {existing.name}")
        else:
            print(f"  [DIFFER]  {existing.name}")
            diffs += 1
            if args.show_diff:
                d = difflib.unified_diff(
                    existing_text.splitlines(keepends=True),
                    rendered.splitlines(keepends=True),
                    fromfile=f"hand-written/{existing.name}",
                    tofile=f"rendered/{existing.name}",
                    n=2,
                )
                sys.stdout.writelines(d)
                print()
    print(f"\n{diffs} differ, {missing} missing.")
    return 0 if (diffs == 0 and missing == 0) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--all", action="store_true",
        help="Render all 7 SOULs into <project>/souls/ (or --output-dir)",
    )
    parser.add_argument(
        "--check", action="store_true",
        help="Diff rendered SOULs against existing files (regression test mode)",
    )
    parser.add_argument(
        "--template",
        help="Single template name (without .md.tmpl)",
    )
    parser.add_argument(
        "yaml",
        help="Path to project.yaml",
    )
    parser.add_argument(
        "--output", help="Write rendered SOUL to this path (single-render mode)",
    )
    parser.add_argument(
        "--output-dir", help="Write all SOULs into this directory (--all mode)",
    )
    parser.add_argument(
        "--against",
        help="Directory containing existing SOULs to compare against (--check mode)",
    )
    parser.add_argument(
        "--show-diff", action="store_true",
        help="Print unified diff for any mismatches (--check mode)",
    )
    args = parser.parse_args()

    if args.check:
        if not args.against:
            parser.error("--check requires --against <souls-dir>")
        return cmd_check(args)
    if args.all:
        return cmd_render_all(args)
    if args.template:
        return cmd_render_one(args)
    parser.error("must specify one of: --all, --check, --template")


if __name__ == "__main__":
    sys.exit(main())
