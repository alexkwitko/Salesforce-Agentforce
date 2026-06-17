#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLANNER_BUNDLES = ROOT / "force-app/main/default/genAiPlannerBundles"


passed = 0
failed = 0


def check(label, ok, details=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label}{': ' + details if details else ''}")


def read_json(path):
    return json.loads(path.read_text())


def latest_planner_bundles():
    latest = {}
    for path in PLANNER_BUNDLES.iterdir():
        if not path.is_dir():
            continue
        match = re.match(r"(.+)_v(\d+)$", path.name)
        if not match:
            continue
        family = match.group(1)
        version = int(match.group(2))
        if family not in latest or version > latest[family][0]:
            latest[family] = (version, path)
    return dict(sorted((family, item[1]) for family, item in latest.items()))


bundles = latest_planner_bundles()
check("latest planner families exist", bool(bundles), str(PLANNER_BUNDLES))

for family, bundle in bundles.items():
    input_schemas = sorted(bundle.glob("localActions/*/*/input/schema.json"))
    output_schemas = sorted(bundle.glob("localActions/*/*/output/schema.json"))
    check(f"{bundle.name} has local action input schemas", bool(input_schemas))
    check(f"{bundle.name} has local action output schemas", bool(output_schemas))

    bad_unknown_required = []
    bad_required_chat_summary = []
    for schema_path in input_schemas:
        data = read_json(schema_path)
        required = data.get("required") or []
        properties = set((data.get("properties") or {}).keys())
        unknown = [name for name in required if name not in properties]
        if unknown:
            bad_unknown_required.append(f"{schema_path.relative_to(ROOT)} -> {unknown}")
        if "chatSummary" in required:
            bad_required_chat_summary.append(str(schema_path.relative_to(ROOT)))

    check(
        f"{bundle.name} has no required input missing from properties",
        not bad_unknown_required,
        "; ".join(bad_unknown_required[:5]),
    )
    check(
        f"{bundle.name} keeps chatSummary optional",
        not bad_required_chat_summary,
        "; ".join(bad_required_chat_summary[:5]),
    )

    otp_outputs = sorted(bundle.glob("localActions/*/request_verification_code_*/output/schema.json"))
    for schema_path in otp_outputs:
        props = set((read_json(schema_path).get("properties") or {}).keys())
        check(
            f"{bundle.name} {schema_path.parent.parent.name} request_verification_code output contract",
            {"success", "message", "email"}.issubset(props),
            f"props={sorted(props)}",
        )

    password_outputs = sorted(bundle.glob("localActions/*/password_reset_link_*/output/schema.json"))
    for schema_path in password_outputs:
        props = set((read_json(schema_path).get("properties") or {}).keys())
        check(
            f"{bundle.name} {schema_path.parent.parent.name} password_reset_link output contract",
            {"message", "caseNumber"}.issubset(props),
            f"props={sorted(props)}",
        )

    password_inputs = sorted(bundle.glob("localActions/*/password_reset_link_*/input/schema.json"))
    for schema_path in password_inputs:
        props = set((read_json(schema_path).get("properties") or {}).keys())
        check(
            f"{bundle.name} {schema_path.parent.parent.name} password_reset_link accepts chatSummary",
            "chatSummary" in props,
            f"props={sorted(props)}",
        )


print(f"\nRESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
