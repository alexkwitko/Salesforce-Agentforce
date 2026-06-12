/**
 * EngagementRest — public REST sink the website JS posts engagement to (the DX, no-screen path
 * that mirrors the Web SDK / Ingestion API). Accepts a batch of anonymous events keyed by a
 * self-managed deviceId cookie, plus an optional identify block (email) that triggers the stitch.
 */
@RestResource(urlMapping='/engagement/*')
global without sharing class EngagementRest {

    global class Evt {
        public String type; public String pageUrl; public String productId; public String productName;
        public String category; public String searchQuery; public Decimal cartValue; public Integer quantity;
        public Integer timeOnPage; public Integer scrollPct;
    }
    global class Identify { public String email; public String firstName; public String lastName; }
    global class Payload { public String deviceId; public String sessionId; public List<Evt> events; public Identify identify; }

    @HttpPost
    global static String post() {
        Payload p = (Payload) JSON.deserialize(RestContext.request.requestBody.toString(), Payload.class);
        List<Web_Event__c> rows = new List<Web_Event__c>();
        if (p.events != null) {
            for (Evt e : p.events) {
                rows.add(new Web_Event__c(
                    Device_Id__c = p.deviceId, Session_Id__c = p.sessionId,
                    Event_Type__c = e.type, Page_Url__c = e.pageUrl,
                    Product_Id__c = e.productId, Product_Name__c = e.productName,
                    Category__c = e.category, Search_Query__c = e.searchQuery,
                    Cart_Value__c = e.cartValue, Quantity__c = e.quantity,
                    Time_On_Page__c = e.timeOnPage, Scroll_Pct__c = e.scrollPct));
            }
        }
        Integer inserted = EngagementIngestService.ingest(rows);
        Id acct;
        if (p.identify != null && String.isNotBlank(p.identify.email)) {
            acct = IdentityStitchService.stitch(p.deviceId, p.identify.email, p.identify.firstName, p.identify.lastName);
        }
        return JSON.serialize(new Map<String, Object>{ 'ok' => true, 'inserted' => inserted, 'accountId' => acct });
    }
}
