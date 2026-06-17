#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / "force-app/main/default/classes"
WPCODE = ROOT / "tmp/wpcode/wpcode_305_combined_datacloud_routes_20260615_9.wpcode-body.txt"


passed = 0
failed = 0


def read(path):
    return path.read_text() if path.exists() else ""


def cls(name):
    return read(CLASSES / name)


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


wpcode = read(WPCODE)
verify_pipeline = read(ROOT / "tools/verify_pipeline.sh")
cert_runner = read(ROOT / "tools/certify_kwitko_safe_state.sh")

check("combined WPCode body exists", bool(wpcode), str(WPCODE))
check("Data Cloud SDK CDN configured", "cdn.c360a.salesforce.com/beacon/c360a/" in wpcode)
check("Data Cloud SDK initializes SalesforceInteractions", "si.init({" in wpcode and "SalesforceInteractions" in wpcode)
check("Data Cloud SDK sends contactPointEmail identity event", 'eventType: "contactPointEmail"' in wpcode and "email: email" in wpcode)
check("Data Cloud SDK sends identity event", 'eventType: "identity"' in wpcode and 'isAnonymous: "0"' in wpcode)
check("Data Cloud SDK sends partyIdentification with correct IDName", 'IDName: "WooCommerce User ID"' in wpcode)
check("Data Cloud SDK does not use obsolete IDNameWeb", "IDNameWeb" not in wpcode)
check("Data Cloud SDK tracks add-to-cart interaction", "CartInteractionName.AddToCart" in wpcode)
check("Data Cloud SDK resets identity on logout/change", "SalesforceInteractions.reset" in wpcode and "kwitko_dc_reset_requested" in wpcode)

check("verify_pipeline defaults away from legacy Apex endpoint", 'RUN_LEGACY_ENGAGEMENT="${RUN_LEGACY_ENGAGEMENT:-0}"' in verify_pipeline)
check("verify_pipeline legacy endpoint is opt-in", 'if [ "$RUN_LEGACY_ENGAGEMENT" = "1" ]; then' in verify_pipeline)
check("verify_pipeline default path names SDK DMO", "SDK Web_Event DMO populated" in verify_pipeline)
check("cert runner documents SDK-first default", "default web-activity proof path is SDK/Data Cloud" in cert_runner)

reco = cls("RecommendationStrategyService.cls")
reco_test = cls("RecommendationStrategyServiceTest.cls")
check("RecommendationStrategyService merges Data Cloud web engagement", "mergeDataCloudWebEngagement(profileAccount, webScoreByWooId)" in reco)
check("RecommendationStrategyService queries Data Cloud web DMO", "Web_Event_c_Home__dlm" in reco and "ConnectApi.CdpQuery.queryAnsiSqlV2" in reco)
check("RecommendationStrategyService joins through UnifiedLink", "UnifiedLinkssotIndividualCoff__dlm" in reco)
check("RecommendationStrategyService surfaces SDK web signal", "via Data Cloud SDK" in reco)
check("RecommendationStrategyService test proves SDK browsing wins without legacy Web_Event__c", "testDataCloudSdkBrowsingBeatsGenericAffinityWhenLegacyWebEventsAreGone" in reco_test)

churn = cls("ChurnScoreService.cls")
churn_test = cls("ChurnScoreServiceTest.cls")
check("ChurnScoreService reads Account SDK web cache", "Insights_Web_Events__c" in churn and "Insights_Last_Web_Activity__c" in churn)
check("ChurnScoreService keeps legacy Web_Event fallback only as fallback", "legacy Web_Event__c rows as fallback" in churn)
check("ChurnScoreService test proves SDK web activity dampens churn", "Data Cloud SDK web activity must dampen churn even when Web_Event__c is empty" in churn_test)

augment = cls("DataCloudAugmentationService.cls")
check("DataCloudAugmentationService writes unified id cache", "Data_Cloud_Unified_Individual_Id__c" in augment)
check("DataCloudAugmentationService writes web event/device/session cache", has_all(augment, ["Insights_Web_Events__c", "Insights_Device_Count__c", "Insights_Session_Count__c"]))
check("DataCloudAugmentationService writes service/order insight cache", has_all(augment, ["Insights_Order_Count__c", "Insights_LTV__c", "Insights_Total_Cases__c", "Insights_Returns__c"]))

lead = cls("LeadNurtureService.cls")
lead_test = cls("LeadNurtureServiceTest.cls")
check("LeadNurtureService gates on consent before coupon/email", "if (l.Email_Consent__c != true)" in lead)
check("LeadNurtureService creates Woo coupon before recovery email", "WooCouponService.createPercentCoupon" in lead and "EmailService.send" in lead)
check("LeadNurtureService deletes Woo coupon on email failure", "WooCouponService.deleteCoupon(wooId)" in lead)
check("LeadNurtureService stamps carts only after email success", "stampRecoveredCarts(l.Id)" in lead and "Recovery_Sent_At__c = System.now()" in lead)
check("LeadNurtureService logs cross-agent journey context", "JourneyLogger.logInteraction" in lead)
check("LeadNurtureService test prevents false recovered coupon on email failure", "testEmailFailureDoesNotMarkRecoveredOrPersistCoupon" in lead_test)

post = cls("PostPurchaseService.cls")
post_test = cls("PostPurchaseServiceTest.cls")
check("PostPurchaseService consent gate runs before offer generation", "CONSENT GATE (FIRST" in post and "ord.Account.Email_Consent__c != true" in post)
check("PostPurchaseService blocks ineligible/refunded/cancelled orders", "isEligibleForOffer" in post and "'refunded'" in post and "'cancelled'" in post)
check("PostPurchaseService blocks sales offers during return/service recovery", "requiresServiceRecoveryBeforeCoupon" in post)
check("PostPurchaseService creates Woo coupon before email", "WooCouponService.createPercentCoupon" in post and "sendEmail(ord" in post)
check("PostPurchaseService deletes Woo coupon on email failure", "WooCouponService.deleteCoupon(wooCouponId)" in post)
check("PostPurchaseService persists Salesforce coupon only after email success", "insert new Coupon__c" in post and "if (emailOutcome.success != true)" in post)
check("PostPurchaseService test prevents false sent offer on email failure", "testEmailFailureDoesNotClaimSent" in post_test)
check("PostPurchaseService test blocks return-risk growth coupon", "testReturnRiskSkipsNormalPostPurchaseCoupon" in post_test)

risk = cls("AtRiskCampaignBuilder.cls")
risk_test = cls("AtRiskCampaignBuilderTest.cls")
check("AtRiskCampaignBuilder prefers Data Cloud model score/tier", "effectiveChurn" in risk and "Data_Cloud_Churn_Risk__c" in risk)
check("AtRiskCampaignBuilder maps textual High risk", "if (tier == 'high') return 0.90" in risk)
check("AtRiskCampaignBuilder sends through EmailService", "EmailService.send(reqs)" in risk)
check("AtRiskCampaignBuilder test proves model score override", "testModelScoreOverridesHeuristic" in risk_test)
check("AtRiskCampaignBuilder test proves textual high-risk override", "testTextualDataCloudHighRiskOverridesHeuristic" in risk_test)

prediction_runbook = read(ROOT / "tools/PREDICTION_RUNBOOK.md")
check("Prediction runbook does not overclaim API-visible model definition", "MLPredictionDefinition` rows: `0`" in prediction_runbook)
check("Prediction runbook states ChurnScoreService is heuristic", "ChurnScoreService` is heuristic Apex" in prediction_runbook)

print(f"\nRESULT: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
