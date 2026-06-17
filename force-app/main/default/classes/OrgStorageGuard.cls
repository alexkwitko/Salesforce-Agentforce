/**
 * OrgStorageGuard
 * Scheduled housekeeping: when org Data Storage crosses a threshold, purge
 * records that are regenerable or already replicated to Data Cloud, then empty
 * the recycle bin so the space is actually reclaimed.
 *
 * IMPORTANT — what this CANNOT do: AI-Evaluation test records (the usual
 * storage hog) are NOT Apex-deletable ("sObject type ... is not supported").
 * Those must be cleared in Setup > Einstein > Agentforce > Testing Center.
 * Real business data (Order, Contact, Account) is intentionally never touched.
 *
 * Schedule with OrgStorageGuard.scheduleDefault();
 */
public without sharing class OrgStorageGuard {

    // --- tunables -----------------------------------------------------------
    // Act when used/limit >= this fraction. OrgLimits reports whole MB, so on a
    // 5MB org this effectively means "4MB or more used".
    public static Double TRIGGER_FRACTION = 0.80;
    // Keep behavioral events this many days (they live in Data Cloud already).
    public static Integer WEB_EVENT_RETAIN_DAYS = 30;
    // Safety cap per object per run.
    private static final Integer BATCH_CAP = 5000;
    private static final Set<String> SAFE_RECYCLE_BIN_OBJECTS = new Set<String>{
        'Agent_Interaction__c',
        'Cart__c',
        'Cart_Item__c',
        'Case',
        'Chat_Verification__c',
        'Coupon__c',
        'Customer_Journey__c',
        'EmailMessage',
        'Lead',
        'MessagingSession',
        'Order',
        'OrderItem',
        'ReturnOrder',
        'ReturnOrderLineItem',
        'Task',
        'Web_Event__c'
    };

    public class Schedule implements Schedulable {
        public void execute(SchedulableContext sc) { run(); }
    }

    /** Entry point — returns a human-readable summary (also debug-logged). */
    public static String run() {
        System.OrgLimit dl = OrgLimits.getMap().get('DataStorageMB');
        Decimal used = (Decimal) dl.getValue();
        Decimal lim  = (Decimal) dl.getLimit();
        Decimal frac = lim > 0 ? (used / lim) : 0;

        String head = 'OrgStorageGuard: DataStorage ' + used + '/' + lim + 'MB (' +
                      frac.setScale(2) + ')';

        Integer purged = purgeExpiredVerificationRows();

        if (frac < TRIGGER_FRACTION) {
            String msg = head + ' — below threshold ' + TRIGGER_FRACTION
                + ', purged ' + purged + ' expired verification record(s).';
            System.debug(LoggingLevel.INFO, msg);
            return msg;
        }

        // 1) Regenerable analytics/training snapshots (rebuildable from Data Cloud / Woo).
        purged += purge([SELECT Id FROM Order_Analytics__c LIMIT :BATCH_CAP]);
        purged += purge([SELECT Id FROM Churn_Training__c LIMIT :BATCH_CAP]);
        // 2) Synthetic endpoint probes.
        purged += purge([
            SELECT Id
            FROM Web_Event__c
            WHERE Device_Id__c = 'STORAGE-PROBE'
            LIMIT :BATCH_CAP
        ]);
        // 3) Aged behavioral events (already federated to the Web_Event DMO).
        DateTime cut = System.now().addDays(-WEB_EVENT_RETAIN_DAYS);
        purged += purge([SELECT Id FROM Web_Event__c WHERE CreatedDate < :cut LIMIT :BATCH_CAP]);
        // 4) Rows already deleted by safe jobs or the user. This does not delete
        // any active data; it only asks Salesforce to reclaim recycle-bin space.
        purged += purgeDeletedRows(new List<String>(SAFE_RECYCLE_BIN_OBJECTS));

        String msg = head + ' — over threshold, purged ' + purged + ' record(s).';
        System.debug(LoggingLevel.INFO, msg);
        return msg;
    }

    private static Integer purgeExpiredVerificationRows() {
        DateTime nowTs = System.now();
        return purge([
            SELECT Id
            FROM Chat_Verification__c
            WHERE Expires_At__c != null
              AND Expires_At__c < :nowTs
            LIMIT :BATCH_CAP
        ]);
    }

    /** Delete + hard-delete (empty recycle bin) in chunks of 200. */
    @TestVisible
    private static Integer purge(List<SObject> recs) {
        if (recs == null || recs.isEmpty()) {
            return 0;
        }
        Integer total = 0;
        for (Integer i = 0; i < recs.size(); i += 200) {
            Integer stop = Math.min(i + 200, recs.size());
            List<SObject> chunk = new List<SObject>();
            for (Integer j = i; j < stop; j++) {
                chunk.add(recs[j]);
            }
            Database.DeleteResult[] deletes = Database.delete(chunk, false);
            List<SObject> deletedRows = new List<SObject>();
            for (Integer j = 0; j < deletes.size(); j++) {
                if (deletes[j].isSuccess()) {
                    deletedRows.add(chunk[j]);
                } else if (!deletes[j].getErrors().isEmpty()) {
                    System.debug(
                        LoggingLevel.WARN,
                        'OrgStorageGuard delete skipped: ' + deletes[j].getErrors()[0].getMessage()
                    );
                }
            }
            total += emptyRecycleBin(deletedRows);
        }
        return total;
    }

    /** Hard-purge rows that are already in the recycle bin for safe objects. */
    @TestVisible
    private static Integer purgeDeletedRows(List<String> objectNames) {
        Integer total = 0;
        for (String objectName : objectNames) {
            if (!SAFE_RECYCLE_BIN_OBJECTS.contains(objectName)) {
                System.debug(LoggingLevel.WARN, 'OrgStorageGuard skipped non-allowlisted object: ' + objectName);
                continue;
            }
            try {
                switch on objectName {
                    when 'Agent_Interaction__c' {
                        total += emptyRecycleBin([SELECT Id FROM Agent_Interaction__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Cart__c' {
                        total += emptyRecycleBin([SELECT Id FROM Cart__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Cart_Item__c' {
                        total += emptyRecycleBin([SELECT Id FROM Cart_Item__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Case' {
                        total += emptyRecycleBin([SELECT Id FROM Case WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Chat_Verification__c' {
                        total += emptyRecycleBin([SELECT Id FROM Chat_Verification__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Coupon__c' {
                        total += emptyRecycleBin([SELECT Id FROM Coupon__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Customer_Journey__c' {
                        total += emptyRecycleBin([SELECT Id FROM Customer_Journey__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'EmailMessage' {
                        total += emptyRecycleBin([SELECT Id FROM EmailMessage WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Lead' {
                        total += emptyRecycleBin([SELECT Id FROM Lead WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'MessagingSession' {
                        total += emptyRecycleBin([SELECT Id FROM MessagingSession WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Order' {
                        total += emptyRecycleBin([SELECT Id FROM Order WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'OrderItem' {
                        total += emptyRecycleBin([SELECT Id FROM OrderItem WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'ReturnOrder' {
                        total += emptyRecycleBin([SELECT Id FROM ReturnOrder WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'ReturnOrderLineItem' {
                        total += emptyRecycleBin([SELECT Id FROM ReturnOrderLineItem WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Task' {
                        total += emptyRecycleBin([SELECT Id FROM Task WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                    when 'Web_Event__c' {
                        total += emptyRecycleBin([SELECT Id FROM Web_Event__c WHERE IsDeleted = true LIMIT 200 ALL ROWS]);
                    }
                }
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    'OrgStorageGuard recycle-bin purge skipped for ' + objectName + ': ' + e.getMessage()
                );
            }
        }
        return total;
    }

    private static Integer emptyRecycleBin(List<SObject> rows) {
        if (rows == null || rows.isEmpty()) {
            return 0;
        }

        Integer total = 0;
        for (Integer i = 0; i < rows.size(); i += 200) {
            Integer stop = Math.min(i + 200, rows.size());
            List<SObject> chunk = new List<SObject>();
            for (Integer j = i; j < stop; j++) {
                chunk.add(rows[j]);
            }

            Database.EmptyRecycleBinResult[] purges = Database.emptyRecycleBin(chunk);
            for (Database.EmptyRecycleBinResult purge : purges) {
                if (purge.isSuccess()) {
                    total++;
                } else if (!purge.getErrors().isEmpty()) {
                    System.debug(
                        LoggingLevel.WARN,
                        'OrgStorageGuard purge skipped: ' + purge.getErrors()[0].getMessage()
                    );
                }
            }
        }
        return total;
    }

    /**
     * Run every 15 minutes. Apex cron requires a single integer for the
     * minute field, so we register four hourly jobs offset by 15 min each
     * (:00, :15, :30, :45). Safe to call repeatedly — it aborts and re-creates.
     * Returns a comma-separated list of the scheduled job ids.
     */
    public static String scheduleDefault() {
        // Clear any previously-registered guard jobs (incl. legacy 6h job).
        for (CronTrigger ct : [SELECT Id FROM CronTrigger
                               WHERE CronJobDetail.Name LIKE 'OrgStorageGuard%']) {
            System.abortJob(ct.Id);
        }
        List<Integer> mins = new List<Integer>{ 0, 15, 30, 45 };
        List<String> ids = new List<String>();
        for (Integer m : mins) {
            String name = 'OrgStorageGuard-' + (m < 10 ? '0' + m : '' + m);
            String cron = '0 ' + m + ' * * * ?';
            ids.add(System.schedule(name, cron, new OrgStorageGuard.Schedule()));
        }
        return String.join(ids, ',');
    }
}
