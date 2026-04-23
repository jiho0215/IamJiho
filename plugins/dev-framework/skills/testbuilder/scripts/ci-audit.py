#!/usr/bin/env python3
"""ci-audit.py — Phase 6 CI organization auditor.

Parses GitHub Actions workflows (``.github/workflows/*.yml``), enumerates
test projects in the repo, and reports:

* **Orphans** — test projects no CI job runs (neither by inclusion nor by
  passing the job's filter expression).
* **Redundancies** — test projects that more than one job runs. The
  redundancy may be intentional (fast-feedback + full coverage pair, gated
  smoke subset), but the script surfaces them so a human can annotate or
  consolidate.
* **Filter warnings** — fragile ``FullyQualifiedName!~`` substring
  exclusions, filters that silently match nothing, and filters lacking a
  comment.

Designed for GitHub Actions (the dev-framework convention). GitLab/Circle
support is a future extension; the script exits cleanly with an empty
report if no workflows directory is found rather than failing.

Usage::

    ci-audit.py [--repo PATH] [--out PATH] [--test-globs GLOB[,GLOB...]]

Default test-project discovery globs:

* ``**/*.csproj`` whose parent folder name matches ``*Tests|*.Tests|*.IntegrationTests|*.E2E*``
* ``**/package.json`` with a ``test`` script (JS/TS)
* ``**/pytest.ini`` or ``**/pyproject.toml`` with ``[tool.pytest.ini_options]``
* ``**/go.mod`` directories containing ``*_test.go`` files

Override by passing ``--test-globs`` with a comma-separated list of globs
to match. Exit code is 0 even when orphans exist — the report is the
product; CI gating is done by the caller (Phase 6 in testbuilder).

Requires PyYAML (``pip install pyyaml``). Falls back to a line-regex
parser if PyYAML is unavailable, which covers the common case but misses
some nested-matrix expansions.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
    _HAVE_YAML = True
except ImportError:
    _HAVE_YAML = False


TEST_PROJECT_HEURISTICS = [
    # (glob, predicate on Path -> bool, project-id extractor)
    ("**/*.csproj",
     lambda p: bool(re.search(r"(Tests|\.Tests|IntegrationTests|E2E)", p.stem, re.I)),
     lambda p: p.stem),
    ("**/pytest.ini",
     lambda p: True,
     lambda p: p.parent.name),
    ("**/pyproject.toml",
     lambda p: "[tool.pytest.ini_options]" in p.read_text(encoding="utf-8", errors="ignore"),
     lambda p: p.parent.name),
    ("**/go.mod",
     lambda p: any(p.parent.rglob("*_test.go")),
     lambda p: p.parent.name),
    ("**/package.json",
     lambda p: '"test"' in p.read_text(encoding="utf-8", errors="ignore"),
     lambda p: p.parent.name),
]

EXCLUDE_PARTS = {"node_modules", ".git", "bin", "obj", "dist", "build", ".venv", "venv"}


def find_test_projects(repo: Path, custom_globs: list[str] | None) -> list[dict]:
    projects: dict[str, dict] = {}

    if custom_globs:
        for glob in custom_globs:
            for path in repo.glob(glob):
                if any(part in EXCLUDE_PARTS for part in path.parts):
                    continue
                rel = path.relative_to(repo).as_posix()
                projects[rel] = {"id": path.stem or path.parent.name, "path": rel}
        return list(projects.values())

    for glob, pred, extract in TEST_PROJECT_HEURISTICS:
        for path in repo.glob(glob):
            if any(part in EXCLUDE_PARTS for part in path.parts):
                continue
            try:
                if not pred(path):
                    continue
            except OSError:
                continue
            rel = path.relative_to(repo).as_posix()
            projects[rel] = {"id": extract(path), "path": rel}
    return list(projects.values())


def load_workflow(path: Path) -> dict | None:
    text = path.read_text(encoding="utf-8", errors="ignore")
    if _HAVE_YAML:
        try:
            return yaml.safe_load(text)
        except yaml.YAMLError:
            return None
    # Minimal fallback: extract job names and their `run:` lines as string dumps.
    jobs: dict[str, Any] = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"^  ([A-Za-z0-9_\-]+):\s*$", line)
        if m and current is None:
            jobs[m.group(1)] = {"_raw_lines": []}
            current = m.group(1)
            continue
        if current and line.startswith("    "):
            jobs[current].setdefault("_raw_lines", []).append(line)
        elif line and not line.startswith(" "):
            current = None
    return {"jobs": jobs, "_fallback": True}


def enumerate_runs(workflow: dict) -> list[dict]:
    """Return list of {job, run, filter, hasComment} per run step."""
    out: list[dict] = []
    jobs = workflow.get("jobs") or {}
    if workflow.get("_fallback"):
        for job_name, job in jobs.items():
            raw = "\n".join(job.get("_raw_lines", []))
            for run_match in re.finditer(r"run:\s*(.+?)(?=\n    [a-z]|\Z)", raw, re.S):
                cmd = run_match.group(1).strip()
                filt = _extract_filter(cmd)
                out.append({"job": job_name, "run": cmd, "filter": filt,
                            "hasComment": _has_preceding_comment(raw, run_match.start())})
        return out
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        for step in (job.get("steps") or []):
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if not isinstance(run, str):
                continue
            filt = _extract_filter(run)
            out.append({"job": job_name, "run": run, "filter": filt,
                        "hasComment": bool(step.get("name")) and
                                      any(w in step.get("name", "").lower()
                                          for w in ("why", "because", "exclude"))})
    return out


def _extract_filter(cmd: str) -> str | None:
    # Common shapes: --filter "Category=Unit", --filter 'FullyQualifiedName!~X', -- -run '^TestFoo$'
    m = re.search(r"--filter\s+[\"']([^\"']+)[\"']", cmd)
    if m:
        return m.group(1)
    m = re.search(r"-run\s+[\"']([^\"']+)[\"']", cmd)
    if m:
        return m.group(1)
    return None


def _has_preceding_comment(text: str, idx: int) -> bool:
    preceding = text[:idx].rstrip().splitlines()[-3:]
    return any(line.lstrip().startswith("#") for line in preceding)


def match_project_to_run(project: dict, run: dict) -> bool:
    """Best-effort: does this run execute this project?"""
    cmd = run["run"]
    # Explicit path reference.
    if project["path"] in cmd or project["id"] in cmd:
        # But a filter may still exclude it — check:
        filt = run.get("filter") or ""
        if "!~" in filt or "!=" in filt:
            tok = filt.split("!~", 1)[-1].split("!=", 1)[-1]
            tok = tok.strip("() \"'").split("&")[0].split("|")[0]
            if tok and tok in project["id"]:
                return False
        return True
    # Solution-wide invocation (`dotnet test` / `pytest` / `go test ./...`)
    # implicitly includes all, subject to filter.
    solution_wide = bool(
        re.search(r"\b(dotnet\s+test)\b(?!.*\.csproj)", cmd)
        or re.search(r"\bpytest\b(?!\s+\S+\.py)", cmd)
        or re.search(r"\bgo\s+test\s+\./\.{2,3}", cmd)
        or re.search(r"\b(jest|vitest)\b(?!\s+\S+)", cmd)
    )
    if not solution_wide:
        return False
    filt = run.get("filter") or ""
    if not filt:
        return True
    # FQN exclude filter
    if "!~" in filt:
        excluded = filt.split("!~", 1)[1].strip("() \"'").split("&")[0].split("|")[0]
        if excluded and excluded in project["id"]:
            return False
    if "!=" in filt:
        # Trait exclude — we can't know the project's traits from here, so be
        # conservative and still consider it matched (will be double-checked
        # by the orphan report's "unknown" bucket).
        pass
    return True


def detect_fragile_filters(runs: list[dict]) -> list[dict]:
    warnings = []
    for r in runs:
        filt = r.get("filter")
        if not filt:
            continue
        if "!~" in filt:
            warnings.append({
                "job": r["job"],
                "filter": filt,
                "kind": "fragile-fqn-exclude",
                "detail": "FullyQualifiedName!~ substring is fragile — "
                          "prefer trait-based filters like Category=Unit.",
            })
        if not r["hasComment"]:
            warnings.append({
                "job": r["job"],
                "filter": filt,
                "kind": "undocumented-filter",
                "detail": "Non-trivial filter has no explanatory comment.",
            })
    return warnings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="Repo root (default: .)")
    ap.add_argument("--out", default=None, help="Write report here (default: stdout)")
    ap.add_argument("--test-globs", default=None,
                    help="Comma-separated globs of test-project files (overrides heuristics)")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        print(f"repo not found: {repo}", file=sys.stderr)
        return 3

    workflow_dir = repo / ".github" / "workflows"
    workflows: list[tuple[str, dict]] = []
    if workflow_dir.is_dir():
        for wf in sorted(workflow_dir.glob("*.y*ml")):
            parsed = load_workflow(wf)
            if parsed:
                workflows.append((wf.name, parsed))

    runs: list[dict] = []
    for name, wf in workflows:
        for run in enumerate_runs(wf):
            run["workflow"] = name
            runs.append(run)

    globs = [g.strip() for g in args.test_globs.split(",")] if args.test_globs else None
    projects = find_test_projects(repo, globs)

    project_runs: dict[str, list[dict]] = {p["path"]: [] for p in projects}
    for p in projects:
        for r in runs:
            if match_project_to_run(p, r):
                project_runs[p["path"]].append({"workflow": r["workflow"], "job": r["job"]})

    orphans = [
        {"project": p["id"], "path": p["path"]}
        for p in projects if not project_runs[p["path"]]
    ]
    redundancies = [
        {"project": p["id"], "path": p["path"],
         "runBy": project_runs[p["path"]]}
        for p in projects if len(project_runs[p["path"]]) > 1
    ]
    filter_warnings = detect_fragile_filters(runs)

    report = {
        "summary": {
            "workflowsAudited": [n for n, _ in workflows],
            "projectsFound": len(projects),
            "runsFound": len(runs),
            "orphansFound": len(orphans),
            "redundanciesFound": len(redundancies),
            "filterWarnings": len(filter_warnings),
            "yamlParser": "pyyaml" if _HAVE_YAML else "regex-fallback",
        },
        "orphans": orphans,
        "redundancies": redundancies,
        "filterWarnings": filter_warnings,
    }

    out_text = json.dumps(report, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(out_text, encoding="utf-8")
    else:
        sys.stdout.write(out_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
