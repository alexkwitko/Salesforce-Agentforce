/**
 * EngagementIngestService — receives device-keyed web events (anonymous) and stores them.
 * If an event carries an email (identify), it triggers the stitch so prior anonymous history
 * for that device (and any sibling device with the same email) crosses to the Account.
 */
public with sharing class EngagementIngestService {

    public static Integer ingest(List<Web_Event__c> events) {
        if (events == null || events.isEmpty()) { return 0; }
        for (Web_Event__c e : events) {
            if (e.Occurred_At__c == null) { e.Occurred_At__c = System.now(); }
        }
        insert events;
        return events.size();
    }
}
