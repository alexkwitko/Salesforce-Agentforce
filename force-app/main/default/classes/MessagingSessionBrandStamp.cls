/**
 * Stamps MessagingSession.Brand__c from the originating channel (the SITE the chat is on),
 * so the Concierge's linked `brand` var scopes recommendations to the right catalog
 * (Kwitko Coffee -> coffee; Bean & Brew -> equipment) WITHOUT depending on an embedded-deployment
 * publish of a prechat parameter. Runs before insert so the value is present at session START,
 * which is when the agent's linked variable resolves.
 *
 * To brand-scope a new storefront's chat: add its MessagingChannel DeveloperName -> brand below.
 * Defensive by design: any failure is swallowed so it can never block chat session creation.
 */
public without sharing class MessagingSessionBrandStamp {

    // MessagingChannel.DeveloperName -> Brand (must match Product2.Brand__c picklist values)
    @TestVisible
    private static Map<String,String> CHANNEL_BRAND = new Map<String,String>{
        'Kwitko_Web_Chat'    => 'Kwitko Coffee',
        'Kwitko_Web_Chat_V2' => 'Kwitko Coffee'
        // When Bean & Brew's LWR chat is surfaced, add its channel here, e.g.:
        // , 'Bean_Brew_Web_Chat' => 'Bean & Brew'
    };

    /** Pure mapping (unit-testable, no DML/SOQL). Returns null for unknown/blank channels. */
    public static String brandFor(String channelDevName) {
        if (String.isBlank(channelDevName)) return null;
        return CHANNEL_BRAND.get(channelDevName);
    }

    /** Before-insert: set Brand__c from the session's channel when not already provided. */
    public static void stamp(List<MessagingSession> sessions) {
        if (sessions == null || sessions.isEmpty()) return;
        try {
            Set<Id> chIds = new Set<Id>();
            for (MessagingSession s : sessions) {
                if (String.isBlank(s.Brand__c) && s.MessagingChannelId != null) chIds.add(s.MessagingChannelId);
            }
            if (chIds.isEmpty()) return;
            Map<Id,String> devByChannel = new Map<Id,String>();
            for (MessagingChannel c : [SELECT Id, DeveloperName FROM MessagingChannel WHERE Id IN :chIds]) {
                devByChannel.put(c.Id, c.DeveloperName);
            }
            for (MessagingSession s : sessions) {
                if (!String.isBlank(s.Brand__c) || s.MessagingChannelId == null) continue;
                String b = brandFor(devByChannel.get(s.MessagingChannelId));
                if (b != null) s.Brand__c = b;
            }
        } catch (Exception e) {
            // Never block session creation on a brand-stamp problem.
            System.debug(LoggingLevel.WARN, 'MessagingSessionBrandStamp skipped: ' + e.getMessage());
        }
    }
}
