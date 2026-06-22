/**
 * Stamps MessagingSession.Brand__c AND MessagingSession.Customer_Brief__c at session START
 * (before insert), so the Concierge's linked `brand` and `sessionContext` variables resolve for FREE
 * (no Agentforce action / no Flex Credits):
 *   - Brand__c          <- the originating channel (the SITE the chat is on) -> scopes recommendations.
 *   - Customer_Brief__c <- a RICH read-only brief for the signed-in shopper (profile 360 + last order
 *                          + items + open cases + service visits + subscriptions) built by
 *                          CustomerBriefBuilder from CRM, so the agent rarely needs a live action.
 *
 * The brief is stamped only when the session carries the signed-in email at insert
 * (Kwitko_Logged_In_Email__c, from prechat). Guests / OTP-verify-mid-chat get a blank brief
 * (the agent falls back to the live actions only in that case).
 *
 * Defensive by design: any failure is swallowed so it can never block chat session creation.
 */
public without sharing class MessagingSessionBrandStamp {

    // MessagingChannel.DeveloperName -> Brand (must match Product2.Brand__c picklist values)
    @TestVisible
    private static Map<String,String> CHANNEL_BRAND = new Map<String,String>{
        'Kwitko_Web_Chat'    => 'Kwitko Coffee',
        'Kwitko_Web_Chat_V2' => 'Kwitko Coffee',
        'Bean_Brew_Web_Chat' => 'Bean & Brew'
    };

    /** Pure mapping (unit-testable, no DML/SOQL). Returns null for unknown/blank channels. */
    public static String brandFor(String channelDevName) {
        if (String.isBlank(channelDevName)) return null;
        return CHANNEL_BRAND.get(channelDevName);
    }

    // What each brand CARRIES / DOES NOT carry (deterministic, anti-hallucination). 2 brands only.
    private static final Map<String,String> CARRIES = new Map<String,String>{
        'Kwitko Coffee' => 'COFFEE ONLY — whole bean, ground, single-origin, blends, espresso roasts, decaf, cold brew.',
        'Bean & Brew'   => 'EQUIPMENT & ACCESSORIES ONLY — espresso machines, grinders, frothers, descaling/cleaning kits, filters, knock boxes, water filtration, install & maintenance plans.'
    };
    private static final Map<String,String> NOT_CARRIES = new Map<String,String>{
        'Kwitko Coffee' => 'equipment, machines, grinders, frothers, filters, accessories, install/maintenance.',
        'Bean & Brew'   => 'coffee, beans, ground coffee, or any drinkable product.'
    };

    /** Build the deterministic catalog message for a brand from real Product2 data.
     *  The agent uses this as the COMPLETE, AUTHORITATIVE list of what it may offer. */
    public static String catalogFor(String brand) {
        if (String.isBlank(brand)) return null;
        String carries = CARRIES.containsKey(brand) ? CARRIES.get(brand) : 'see product list below.';
        String notCarries = NOT_CARRIES.containsKey(brand) ? NOT_CARRIES.get(brand) : 'anything not in the list below.';
        Map<String,List<String>> byFamily = new Map<String,List<String>>();
        Integer total = 0;
        for (Product2 p : [SELECT Name, Family, Product_Specs__c FROM Product2 WHERE Brand__c = :brand AND IsActive = true ORDER BY Family NULLS LAST, Name]) {
            String fam = String.isBlank(p.Family) ? 'Other' : p.Family;
            if (!byFamily.containsKey(fam)) byFamily.put(fam, new List<String>());
            String spec = String.isBlank(p.Product_Specs__c) ? '' : (' — ' + p.Product_Specs__c.replace('\n',' ').replace('\r',' ').abbreviate(220));
            byFamily.get(fam).add(p.Name + spec);
            total++;
        }
        String msg = 'STORE CATALOG — ' + brand + '. This is the COMPLETE, AUTHORITATIVE list of everything this store sells, WITH each product\'s real specs/details after the dash. '
            + 'You may ONLY mention, recommend, confirm, add to cart, or offer products that appear below. If the shopper asks for ANYTHING not listed here, '
            + 'state plainly that this store does not carry it — NEVER claim it, describe it, invent it, or offer to show/find it. '
            + 'PRODUCT DETAILS: when the shopper asks for details/specs about any product here — including by position like "the first one" or "the first item" — answer DIRECTLY from the specs shown below; you ALREADY have them, so NEVER say you lack details or specs for a product that is listed here, and never route a details question to cart or registration.\n'
            + 'CARRIES: ' + carries + '\n'
            + 'DOES NOT CARRY: ' + notCarries + '\n'
            + 'ALLOWED PRODUCTS (' + total + '), each line is "Name — specs":';
        for (String fam : byFamily.keySet()) {
            msg += '\n[' + fam + ']\n  - ' + String.join(byFamily.get(fam), '\n  - ');
        }
        return msg.length() > 32000 ? msg.substring(0, 32000) : msg;
    }

    /** Before-insert: set Brand__c (from channel) and Customer_Brief__c (from the signed-in Account). */
    public static void stamp(List<MessagingSession> sessions) {
        if (sessions == null || sessions.isEmpty()) return;
        try {
            Set<Id> chIds = new Set<Id>();
            Set<String> emails = new Set<String>();
            for (MessagingSession s : sessions) {
                if (String.isBlank(s.Brand__c) && s.MessagingChannelId != null) chIds.add(s.MessagingChannelId);
                if (String.isBlank(s.Customer_Brief__c) && String.isNotBlank(s.Kwitko_Logged_In_Email__c)) {
                    emails.add(s.Kwitko_Logged_In_Email__c.toLowerCase());
                }
            }

            // Brand: channel -> brand
            Map<Id,String> devByChannel = new Map<Id,String>();
            if (!chIds.isEmpty()) {
                for (MessagingChannel c : [SELECT Id, DeveloperName FROM MessagingChannel WHERE Id IN :chIds]) {
                    devByChannel.put(c.Id, c.DeveloperName);
                }
            }

            // Brief: email -> account -> rich brief
            Map<String,Id> acctByEmail = new Map<String,Id>();
            if (!emails.isEmpty()) {
                for (Account a : [SELECT Id, PersonEmail FROM Account WHERE PersonEmail IN :emails AND IsPersonAccount = true]) {
                    if (String.isNotBlank(a.PersonEmail)) acctByEmail.put(a.PersonEmail.toLowerCase(), a.Id);
                }
            }
            Map<Id,String> briefByAcct = acctByEmail.isEmpty()
                ? new Map<Id,String>()
                : CustomerBriefBuilder.briefsByAccount(new Set<Id>(acctByEmail.values()));

            Map<String,String> catalogByBrand = new Map<String,String>();   // build each brand's catalog once
            for (MessagingSession s : sessions) {
                if (String.isBlank(s.Brand__c) && s.MessagingChannelId != null) {
                    String b = brandFor(devByChannel.get(s.MessagingChannelId));
                    if (b != null) s.Brand__c = b;
                }
                // Deterministic per-brand catalog -> linked brandCatalog var (anti-hallucination)
                if (String.isBlank(s.Brand_Catalog__c) && String.isNotBlank(s.Brand__c)) {
                    if (!catalogByBrand.containsKey(s.Brand__c)) catalogByBrand.put(s.Brand__c, catalogFor(s.Brand__c));
                    s.Brand_Catalog__c = catalogByBrand.get(s.Brand__c);
                }
                if (String.isBlank(s.Customer_Brief__c) && String.isNotBlank(s.Kwitko_Logged_In_Email__c)) {
                    Id aid = acctByEmail.get(s.Kwitko_Logged_In_Email__c.toLowerCase());
                    String brief = (aid != null) ? briefByAcct.get(aid) : null;
                    if (String.isNotBlank(brief)) {
                        s.Customer_Brief__c = brief.length() > 32000 ? brief.substring(0, 32000) : brief;
                    }
                }
            }
        } catch (Exception e) {
            // Never block session creation on a stamp problem.
            System.debug(LoggingLevel.WARN, 'MessagingSessionBrandStamp skipped: ' + e.getMessage());
        }
    }
}
