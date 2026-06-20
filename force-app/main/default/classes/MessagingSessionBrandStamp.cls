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

            for (MessagingSession s : sessions) {
                if (String.isBlank(s.Brand__c) && s.MessagingChannelId != null) {
                    String b = brandFor(devByChannel.get(s.MessagingChannelId));
                    if (b != null) s.Brand__c = b;
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
