#!/usr/bin/env python3
"""
Helm plan helper: compare desired (helm template) vs current (helm get manifest)
and output a JSON list of changes (create/replace/remove) for setup.sh to display.

Usage:
  helm_plan.py <release> <chart_path> <namespace> [helm_args ...]

Example:
  helm_plan.py neural-gate /path/to/chart inference --set models[0].name=qwen3-8b

Output (JSON to stdout):
  {"changes": [{"kind": "ConfigMap", "name": "foo", "action": "replace", "state": "existing", "source_file": "monitoring/grafana-dashboard.yaml"}, ...], "has_changes": true}
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]


def run_helm_template(release: str, chart_path: str, namespace: str, helm_args: list[str]) -> str:
    cmd = ["helm", "template", release, chart_path, "--namespace", namespace] + helm_args
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"helm template failed: {result.stderr or result.stdout}")
    return result.stdout


def run_helm_get_manifest(release: str, namespace: str) -> str:
    result = subprocess.run(
        ["helm", "get", "manifest", release, "-n", namespace],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return ""
    return result.stdout


def extract_source_file(doc_lines: list[str]) -> str:
    for line in doc_lines:
        m = re.match(r"# Source: .*templates/(.+)", line.strip())
        if m:
            return m.group(1).strip()
    return ""


def normalize_doc(doc: str) -> str:
    lines = doc.strip().split("\n")
    out = []
    for line in lines:
        if line.strip().startswith("# Source:"):
            continue
        out.append(line)
    return "\n".join(out) if out else ""


def parse_manifest(manifest: str) -> list[dict[str, Any]]:
    docs = []
    current = []
    for line in manifest.split("\n"):
        if line.strip() == "---":
            if current:
                docs.append("\n".join(current))
            current = []
        else:
            current.append(line)
    if current:
        docs.append("\n".join(current))

    result = []
    for doc in docs:
        doc_stripped = doc.strip()
        if not doc_stripped:
            continue
        lines = doc_stripped.split("\n")
        source_file = extract_source_file(lines)
        norm = normalize_doc(doc_stripped)
        data = yaml.safe_load(norm) or {}
        kind = data.get("kind", "")
        meta = data.get("metadata") or {}
        name = meta.get("name", "")
        ns = meta.get("namespace", "")
        try:
            norm_canonical = yaml.dump(data, default_flow_style=False, sort_keys=True, allow_unicode=True)
        except Exception:
            norm_canonical = norm
        result.append({
            "kind": kind,
            "name": name,
            "namespace": ns,
            "source_file": source_file,
            "normalized": norm_canonical,
        })
    return result


def main() -> int:
    if len(sys.argv) < 4:
        print("Usage: helm_plan.py <release> <chart_path> <namespace> [helm_args ...]", file=sys.stderr)
        return 2
    if yaml is None:
        print(json.dumps({"error": "PyYAML is required. Install with: pip install pyyaml", "changes": [], "has_changes": False}))
        return 1
    release = sys.argv[1]
    chart_path = sys.argv[2]
    namespace = sys.argv[3]
    helm_args = sys.argv[4:]

    try:
        new_raw = run_helm_template(release, chart_path, namespace, helm_args)
    except Exception as e:
        print(json.dumps({"error": str(e), "changes": [], "has_changes": False}))
        return 1

    old_raw = run_helm_get_manifest(release, namespace)
    new_docs = parse_manifest(new_raw)
    old_docs = parse_manifest(old_raw)

    old_by_key: dict[tuple[str, str, str], dict] = {}
    for d in old_docs:
        key = (d["kind"], d["name"], d["namespace"] or namespace)
        old_by_key[key] = d

    changes = []
    seen_keys = set()

    for d in new_docs:
        key = (d["kind"], d["name"], d["namespace"] or namespace)
        seen_keys.add(key)
        old = old_by_key.get(key)
        if old is None:
            changes.append({
                "kind": d["kind"],
                "name": d["name"],
                "action": "create",
                "state": "new",
                "source_file": d["source_file"],
            })
        elif old["normalized"] != d["normalized"]:
            changes.append({
                "kind": d["kind"],
                "name": d["name"],
                "action": "replace",
                "state": "existing",
                "source_file": d["source_file"],
            })

    for d in old_docs:
        key = (d["kind"], d["name"], d["namespace"] or namespace)
        if key not in seen_keys:
            changes.append({
                "kind": d["kind"],
                "name": d["name"],
                "action": "remove",
                "state": "existing",
                "source_file": d.get("source_file", ""),
            })

    out = {"changes": changes, "has_changes": len(changes) > 0}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
