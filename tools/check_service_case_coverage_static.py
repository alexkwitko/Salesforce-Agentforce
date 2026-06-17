#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / "force-app/main/default/classes"


passed = 0
failed = 0


def text(name):
    path = CLASSES / name
    if not path.exists():
        return ""
    return path.read_text()


def check(label, ok, details=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label}{': ' + details if details else ''}")


def has_all(body, needles):
    return all(needle in body for needle in needles)


def service_case_specs():
    return {
        "OrderStatusService.cls": [
            ("creates solved order-status Case", ["Case c = new Case", "Status = 'Closed'", "Category__c = 'Order'"]),
            ("stores resolution fields", ["Resolution__c = resolution", "Resolved_By__c = 'Chat Agent"]),
            ("stores transcript task", ["CaseTranscriptUtil.insertTaskWithResolution"]),
        ],
        "TrackingService.cls": [
            ("creates solved tracking Case", ["CaseTranscriptUtil.insertSolvedCase", "'Chat service: Tracking answered'"]),
            ("returns case number", ["@InvocableVariable public String caseNumber"]),
            ("logs service interaction", ["lr.action='get_tracking'", "lr.stage='Resolved'"]),
        ],
        "ReturnService.cls": [
            ("starts return with open Returns Case", ["new Case(", "Status = 'New'", "Category__c = 'Returns'", "Subject = 'Return started"]),
            ("does not issue Woo refund at return start", ["res.refundIssued = false", "refund will be processed after the returned merchandise is received"]),
            ("sends return label via Woo", ["WooOrderActionService.sendReturnLabelEmail", "WooOrderActionService.addCustomerNote"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
            ("existing return follow-up creates closed solved Case", ["createExistingReturnStatusCase", "Status = 'Closed'", "'Chat service: Return status answered'"]),
        ],
        "ReturnReceiptService.cls": [
            ("requires merchandise receipt confirmation before refund", ["Confirm the returned merchandise was received", "confirmed"]),
            ("issues Woo refund only on receipt path", ["WooOrderActionService.refundOrder", "refundLines"]),
            ("closes ReturnOrder and source Order after refund", ["Status = 'Closed'", "Fulfillment_Status__c = 'Refunded'", "Payment_Status__c = 'Refunded'"]),
            ("closes/creates Returns Case with resolution", ["Resolution__c = resolution", "Resolved_By__c", "Return received and refund processed"]),
        ],
        "CancellationService.cls": [
            ("opens failure Case without refund when Woo cancel fails", ["Subject = 'Cancellation failed", "no refund was attempted", "Status = 'New'"]),
            ("creates Case for cancellation result", ["Subject = 'Cancellation", "Status = caseStatus", "Resolution__c = note"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "StoreCreditService.cls": [
            ("creates solved Case when credit issued", ["CaseTranscriptUtil.insertSolvedCase", "'Chat service: Store credit issued'"]),
            ("opens follow-up Case when Woo coupon creation fails", ["Subject = 'Store credit failed'", "Status = 'New'", "No credit was issued"]),
            ("stores transcript", ["CaseTranscriptUtil.sanitizePreActionCaseClaims", "CaseTranscriptUtil.insertTask"]),
        ],
        "AddressUpdateService.cls": [
            ("creates shipping-address Case", ["createCase", "Subject='Chat service: Shipping address updated'", "Category__c='Shipping'"]),
            ("closes only when Woo sync succeeds", ["Status=wooOk?'Closed':'New'"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "FailedPaymentService.cls": [
            ("opens Billing Case for pay-link path", ["Subject='Failed/pending payment", "Status='New'", "Category__c='Billing'"]),
            ("creates solved Case for already-paid answer", ["CaseTranscriptUtil.insertSolvedCase", "'Chat service: Payment question answered'"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "ReshipService.cls": [
            ("opens operations Case for reship", ["Subject='Reship", "Status='New'", "Category__c='Shipping'"]),
            ("does not claim shipped replacement", ["no replacement has shipped yet", "Woo fulfillment still needs operations review"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "OrderModifyService.cls": [
            ("opens operations Case for order modification", ["Subject='Modify order", "Status='New'", "Category__c='Order'"]),
            ("does not claim direct Woo mutation", ["I have not changed the Woo order directly", "Operations still needs to apply"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "ExchangeService.cls": [
            ("creates return leg and operations Case", ["ReturnService.Request", "Subject='Exchange", "Status='New'", "Category__c='Returns'"]),
            ("does not claim shipped replacement", ["no replacement has shipped yet", "Woo replacement fulfillment still needs operations review"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "CallbackService.cls": [
            ("opens escalated callback Case", ["Subject='Callback request'", "Status='Escalated'", "Category__c='Escalation'"]),
            ("creates callback task", ["Subject='Call back"]),
            ("stores transcript", ["CaseTranscriptUtil.append", "CaseTranscriptUtil.insertTask"]),
        ],
        "CaseService.cls": [
            ("opens explicit support Case", ["Case c = new Case", "Origin = 'Chat'", "Status = (r.escalate == true) ? 'Escalated' : 'New'"]),
            ("keeps unverified cases unlinked", ["Boolean verified", "Account acc = verified ?"]),
            ("stores transcript task", ["insert new Task", "Subject = 'Chat transcript'"]),
        ],
        "CaseResolutionService.cls": [
            ("requires explicit confirmation before close", ["if (r.confirmed != true)", "Confirm the issue is actually fixed"]),
            ("closes Case with resolution", ["c.Status = 'Closed'", "c.Resolution__c", "c.Resolved_By__c"]),
            ("stores transcript timeline", ["CaseTranscriptUtil.insertTaskWithResolution"]),
        ],
        "PasswordResetService.cls": [
            ("creates solved Account Case", ["CaseTranscriptUtil.insertSolvedCase", "'Account'", "'Chat service: Password reset link provided'"]),
            ("returns case number", ["@InvocableVariable public String caseNumber"]),
        ],
    }


for filename, checks in service_case_specs().items():
    body = text(filename)
    check(f"{filename} exists", bool(body), str(CLASSES / filename))
    if not body:
        continue
    for label, needles in checks:
        missing = [needle for needle in needles if needle not in body]
        check(f"{filename} {label}", not missing, "missing " + ", ".join(missing[:4]))

print(f"\nRESULT: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
