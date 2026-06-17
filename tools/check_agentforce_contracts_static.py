#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENT_BUNDLES = ROOT / "force-app/main/default/aiAuthoringBundles"
PLANNER_BUNDLES = ROOT / "force-app/main/default/genAiPlannerBundles"

SERVICE_ACTIONS = {
    "process_return",
    "cancel_order",
    "apply_store_credit",
    "resolve_case",
    "get_tracking",
    "update_shipping_address",
    "handle_failed_payment",
    "reship",
    "modify_order",
    "process_exchange",
    "schedule_callback",
    "password_reset_link",
}


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


def latest_web_planner():
    candidates = []
    for path in PLANNER_BUNDLES.glob("Kwitko_Concierge_Web_v*"):
        match = re.search(r"_v(\d+)$", path.name)
        if match:
            candidates.append((int(match.group(1)), path))
    if not candidates:
        return None
    return sorted(candidates)[-1][1]


def json_file(path):
    return json.loads(path.read_text())


def block_between(text, start, end):
    start_idx = text.find(start)
    if start_idx < 0:
        return ""
    end_idx = text.find(end, start_idx)
    if end_idx < 0:
        return text[start_idx:]
    return text[start_idx:end_idx]


def generated_topic_block(text, local_developer_name):
    for match in re.finditer(r"<localTopics>", text):
        end = text.find("</localTopics>", match.start())
        if end < 0:
            continue
        block = text[match.start() : end + len("</localTopics>")]
        if f"<localDeveloperName>{local_developer_name}</localDeveloperName>" in block:
            return block
    return ""


latest = latest_web_planner()
check("latest generated web planner bundle exists", latest is not None)

if latest is not None:
    planner_xml_path = latest / f"{latest.name}.genAiPlannerBundle"
    planner_xml = planner_xml_path.read_text() if planner_xml_path.exists() else ""
    router_block = generated_topic_block(planner_xml, "agent_router")
    service_block = generated_topic_block(planner_xml, "service")
    check(f"{latest.name} generated router topic exists", bool(router_block), str(planner_xml_path))
    check(
        f"{latest.name} generated router cannot call request_verification_code directly",
        "request_verification_code_" not in router_block and "<localDeveloperName>request_verification_code</localDeveloperName>" not in router_block,
    )
    check(
        f"{latest.name} generated router cannot call verify_code directly",
        "verify_code_" not in router_block and "<localDeveloperName>verify_code</localDeveloperName>" not in router_block,
    )
    check(
        f"{latest.name} generated service keeps guest complaint open_case path",
        "open_case_" in service_block and "unlinked guest" in service_block and "protected account/order data" in service_block,
    )

    otp_output_files = sorted(latest.glob("localActions/*/request_verification_code_*/output/schema.json"))
    check("request_verification_code output schemas exist", bool(otp_output_files), str(latest))
    for schema_path in otp_output_files:
        props = set(json_file(schema_path).get("properties", {}).keys())
        check(
            f"{latest.name} {schema_path.parent.parent.name} request_verification_code exposes email",
            {"success", "message", "email"}.issubset(props),
            f"props={sorted(props)}",
        )

    password_reset_outputs = sorted(latest.glob("localActions/*/password_reset_link_*/output/schema.json"))
    check("password_reset_link output schemas exist", bool(password_reset_outputs), str(latest))
    for schema_path in password_reset_outputs:
        props = set(json_file(schema_path).get("properties", {}).keys())
        check(
            f"{latest.name} {schema_path.parent.parent.name} password_reset_link exposes caseNumber",
            {"message", "caseNumber"}.issubset(props),
            f"props={sorted(props)}",
        )

    password_reset_inputs = sorted(latest.glob("localActions/*/password_reset_link_*/input/schema.json"))
    check("password_reset_link input schemas exist", bool(password_reset_inputs), str(latest))
    for schema_path in password_reset_inputs:
        props = set(json_file(schema_path).get("properties", {}).keys())
        check(
            f"{latest.name} {schema_path.parent.parent.name} password_reset_link accepts chatSummary",
            "chatSummary" in props,
            f"props={sorted(props)}",
        )

    bad_required_chat = []
    bad_required_unknown = []
    service_required = {}
    for schema_path in sorted(latest.glob("localActions/*/*/input/schema.json")):
        action = schema_path.parent.parent.name.split("_179", 1)[0]
        data = json_file(schema_path)
        required = data.get("required", [])
        props = set(data.get("properties", {}).keys())
        unknown = [name for name in required if name not in props]
        if unknown:
            bad_required_unknown.append(f"{schema_path}: {unknown}")
        if "chatSummary" in required:
            bad_required_chat.append(str(schema_path))
        if action in SERVICE_ACTIONS:
            service_required[action] = required

    check("generated schemas do not require unknown inputs", not bad_required_unknown, "; ".join(bad_required_unknown[:5]))
    check("generated schemas do not require chatSummary", not bad_required_chat, "; ".join(bad_required_chat[:5]))

    for action in sorted(SERVICE_ACTIONS):
        check(f"generated service action present: {action}", action in service_required)

for agent_path in sorted(AGENT_BUNDLES.glob("*/*.agent")):
    text = agent_path.read_text()
    lines = text.splitlines()
    required_chat_lines = []
    for idx, line in enumerate(lines):
        if line.strip().startswith("chatSummary:"):
            window = "\n".join(lines[idx : idx + 8])
            if "is_required: True" in window:
                required_chat_lines.append(str(idx + 1))
    check(f"{agent_path.parent.name} source keeps chatSummary optional", not required_chat_lines, ",".join(required_chat_lines))

for agent_name in ["Kwitko_Concierge_Web", "Kwitko_Concierge_Web_Live"]:
    agent_path = AGENT_BUNDLES / agent_name / f"{agent_name}.agent"
    text = agent_path.read_text()
    router_block = block_between(text, "start_agent agent_router:", "\nsubagent ")
    if agent_name == "Kwitko_Concierge_Web":
        check(f"{agent_name} source router cannot call request_verification_code directly", "request_verification_code: @actions.request_verification_code" not in router_block and 'target: "apex://RequestVerificationCodeAction"' not in router_block)
        check(f"{agent_name} source router cannot call verify_code directly", "verify_code: @actions.verify_code" not in router_block and 'target: "apex://VerifyCodeAction"' not in router_block)
        check(f"{agent_name} source routes explicit complaint/case to service", "CASE/COMPLAINT HARD STOP" in router_block and "open_case can create" in router_block and "go_to_service" in router_block)
    check(
        f"{agent_name} does not assign OTP email from request_verification_code output",
        "set @variables.otpEmail = @outputs.email" not in text,
    )
    check(
        f"{agent_name} does not tell service to use request_verification_code @outputs.email",
        "use @outputs.email as email" not in text,
    )
    check(
        f"{agent_name} does not promise exchange replacement shipment",
        "and send a replacement" not in text,
    )
    check(
        f"{agent_name} describes reship as operations-gated",
        "replacement operations case" in text,
    )

class_checks = {
    "EmailService.cls": [
        ("transactional email bypasses marketing consent", "if (isTransactional == true) return true;"),
    ],
    "ReshipService.cls": [
        ("reship output says Woo fulfillment still needs operations", "no replacement has shipped yet"),
    ],
    "ExchangeService.cls": [
        ("exchange output says Woo fulfillment still needs operations", "no replacement has shipped yet"),
    ],
    "OrderModifyService.cls": [
        ("modify output says Woo order was not directly changed", "I have not changed the Woo order directly"),
    ],
    "PasswordResetService.cls": [
        ("password reset output returns case number", "public String caseNumber"),
        ("password reset creates solved case", "CaseTranscriptUtil.insertSolvedCase"),
    ],
    "KwitkoServiceUtil.cls": [
        ("customer order number does not fall back to Salesforce OrderNumber", "? o.Woo_Order_Id__c : null"),
    ],
    "FulfillmentTruthService.cls": [
        ("snapshot order number does not fall back to Salesforce OrderNumber", ": 'this order'"),
    ],
}

for class_name, checks in class_checks.items():
    class_path = ROOT / "force-app/main/default/classes" / class_name
    text = class_path.read_text()
    for label, needle in checks:
        check(f"{class_name} {label}", needle in text)

print(f"\nRESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
