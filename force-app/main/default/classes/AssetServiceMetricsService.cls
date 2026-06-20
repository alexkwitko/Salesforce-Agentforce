/**
 * AssetServiceMetricsService
 * ---------------------------------------------------------------------------
 * The "right model" for tracking service per Asset:
 *   Asset (install base) <-- WorkOrder.AssetId (the service call)
 *                        <-- ServiceAppointment.ParentRecordId (the visit)
 *
 * Rolls up reliability KPIs onto the Asset so they are LDS-readable (and thus
 * offline-friendly) on the Field Service mobile app:
 *   - Call Rate (per yr)        = completed service calls in the trailing 12 months
 *   - Fix Right First Time %    = % of 12mo calls with NO repeat within 30 days
 *   - Repeat Visits (12mo)      = calls that recurred within 30 days of a prior call
 *   - Mean Time To Repair (days)= avg(Service_Date - Reported_Date)
 *   - Total Service Calls / Last Service Date / Open Work Orders
 */
public with sharing class AssetServiceMetricsService {

    // A finished service call (counts toward analytics)
    @TestVisible private static final Set<String> DONE =
        new Set<String>{ 'Completed', 'Closed', 'Cannot Complete' };
    // Anything in this set is no longer "open"
    @TestVisible private static final Set<String> CLOSED_ALL =
        new Set<String>{ 'Completed', 'Closed', 'Cannot Complete', 'Canceled' };
    @TestVisible private static final Integer REPEAT_WINDOW_DAYS = 30;

    // ------------------------------------------------------------------ DTO
    public class AssetMetrics {
        @AuraEnabled public Boolean hasAsset = false;
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String accountName;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal callRate;
        @AuraEnabled public Decimal fixRightFirstTime;
        @AuraEnabled public Integer totalCalls = 0;
        @AuraEnabled public Integer calls12mo = 0;
        @AuraEnabled public Integer repeatVisits = 0;
        @AuraEnabled public Decimal mttrDays;
        @AuraEnabled public Date lastServiceDate;
        @AuraEnabled public Integer openWorkOrders = 0;
        @AuraEnabled public Datetime updatedAt;
    }

    // ------------------------------------------------ resolve the Asset id
    // Works from an Asset, WorkOrder, or ServiceAppointment record.
    public static Id resolveAssetId(Id recordId) {
        if (recordId == null) return null;
        String objType = String.valueOf(recordId.getSObjectType());
        if (objType == 'Asset') {
            return recordId;
        }
        if (objType == 'WorkOrder') {
            for (WorkOrder w : [SELECT AssetId FROM WorkOrder WHERE Id = :recordId LIMIT 1]) {
                return w.AssetId;
            }
            return null;
        }
        if (objType == 'ServiceAppointment') {
            for (ServiceAppointment sa : [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId LIMIT 1]) {
                Id parent = sa.ParentRecordId;
                if (parent == null) return null;
                String pType = String.valueOf(parent.getSObjectType());
                if (pType == 'Asset') return parent;
                if (pType == 'WorkOrder') {
                    for (WorkOrder w : [SELECT AssetId FROM WorkOrder WHERE Id = :parent LIMIT 1]) {
                        return w.AssetId;
                    }
                }
            }
            return null;
        }
        return null;
    }

    // -------------------------------------------------- LWC read entry point
    @AuraEnabled(cacheable=true)
    public static AssetMetrics getMetrics(Id recordId) {
        return buildDto(resolveAssetId(recordId));
    }

    // --------------------------------------- LWC "Refresh" button (recompute)
    @AuraEnabled
    public static AssetMetrics refreshMetrics(Id recordId) {
        Id assetId = resolveAssetId(recordId);
        if (assetId != null) {
            recalculate(new Set<Id>{ assetId });
        }
        return buildDto(assetId);
    }

    private static AssetMetrics buildDto(Id assetId) {
        AssetMetrics m = new AssetMetrics();
        if (assetId == null) return m;
        List<Asset> assets = [
            SELECT Id, Name, Account.Name, SerialNumber, Status,
                   Call_Rate_Annual__c, Fix_Right_First_Time__c, Total_Service_Calls__c,
                   Service_Calls_12mo__c, Repeat_Visits_12mo__c, Mean_Time_To_Repair_Days__c,
                   Last_Service_Date__c, Open_Work_Orders__c, Service_Metrics_Updated__c
            FROM Asset WHERE Id = :assetId LIMIT 1
        ];
        if (assets.isEmpty()) return m;
        Asset a = assets[0];
        m.hasAsset = true;
        m.assetId = a.Id;
        m.assetName = a.Name;
        m.accountName = (a.Account != null) ? a.Account.Name : null;
        m.serialNumber = a.SerialNumber;
        m.status = a.Status;
        m.callRate = a.Call_Rate_Annual__c;
        m.fixRightFirstTime = a.Fix_Right_First_Time__c;
        m.totalCalls = toInt(a.Total_Service_Calls__c);
        m.calls12mo = toInt(a.Service_Calls_12mo__c);
        m.repeatVisits = toInt(a.Repeat_Visits_12mo__c);
        m.mttrDays = a.Mean_Time_To_Repair_Days__c;
        m.lastServiceDate = a.Last_Service_Date__c;
        m.openWorkOrders = toInt(a.Open_Work_Orders__c);
        m.updatedAt = a.Service_Metrics_Updated__c;
        return m;
    }

    private static Integer toInt(Decimal d) { return (d == null) ? 0 : d.intValue(); }

    // ------------------------------------------------- invocable (Flow) + all
    @InvocableMethod(label='Recalculate Asset Service Metrics'
        description='Recompute call rate, fix-right-first-time and reliability metrics for the given assets.')
    public static void recalcInvocable(List<Id> assetIds) {
        if (assetIds != null && !assetIds.isEmpty()) {
            recalculate(new Set<Id>(assetIds));
        }
    }

    public static void recalculateAll() {
        recalculate(null);
    }

    // --------------------------------------------------------- core compute
    public static void recalculate(Set<Id> assetIds) {
        List<Asset> assets = (assetIds == null)
            ? [SELECT Id FROM Asset]
            : [SELECT Id FROM Asset WHERE Id IN :assetIds];
        if (assets.isEmpty()) return;
        Set<Id> ids = new Map<Id, Asset>(assets).keySet();

        List<WorkOrder> wos = [
            SELECT Id, AssetId, Status, Service_Date__c, Reported_Date__c, Is_Repeat_Visit__c
            FROM WorkOrder
            WHERE AssetId IN :ids
            ORDER BY AssetId, Service_Date__c ASC NULLS LAST
        ];

        Map<Id, List<WorkOrder>> byAsset = new Map<Id, List<WorkOrder>>();
        for (Id aId : ids) byAsset.put(aId, new List<WorkOrder>());
        for (WorkOrder w : wos) byAsset.get(w.AssetId).add(w);

        Date today = Date.today();
        Date cutoff12mo = today.addDays(-365);

        List<Asset> assetUpdates = new List<Asset>();
        List<WorkOrder> woUpdates = new List<WorkOrder>();

        for (Id aId : ids) {
            Integer total = 0, calls12 = 0, repeats12 = 0, openWo = 0;
            Decimal mttrSum = 0; Integer mttrCount = 0;
            Date lastService = null;
            Date prevDone = null;

            for (WorkOrder w : byAsset.get(aId)) {
                if (!CLOSED_ALL.contains(w.Status)) openWo++;
                if (!DONE.contains(w.Status)) continue;
                Date sd = w.Service_Date__c;
                if (sd == null) continue; // need a date for analytics

                total++;
                if (sd >= cutoff12mo) calls12++;
                if (lastService == null || sd > lastService) lastService = sd;

                if (w.Reported_Date__c != null) {
                    mttrSum += w.Reported_Date__c.daysBetween(sd); // sd - reported (>= 0)
                    mttrCount++;
                }

                Boolean repeat = (prevDone != null && prevDone.daysBetween(sd) <= REPEAT_WINDOW_DAYS);
                if (w.Is_Repeat_Visit__c != repeat) {
                    woUpdates.add(new WorkOrder(Id = w.Id, Is_Repeat_Visit__c = repeat));
                }
                if (repeat && sd >= cutoff12mo) repeats12++;
                prevDone = sd;
            }

            Decimal ftft = (calls12 > 0)
                ? (((Decimal) (calls12 - repeats12)) / calls12 * 100).setScale(1)
                : null;
            Decimal mttr = (mttrCount > 0) ? (mttrSum / mttrCount).setScale(1) : null;

            assetUpdates.add(new Asset(
                Id = aId,
                Total_Service_Calls__c     = total,
                Service_Calls_12mo__c      = calls12,
                Call_Rate_Annual__c        = Decimal.valueOf(calls12).setScale(2),
                Fix_Right_First_Time__c    = ftft,
                Repeat_Visits_12mo__c      = repeats12,
                Mean_Time_To_Repair_Days__c= mttr,
                Last_Service_Date__c       = lastService,
                Open_Work_Orders__c        = openWo,
                Service_Metrics_Updated__c = Datetime.now()
            ));
        }

        if (!woUpdates.isEmpty()) update woUpdates;
        if (!assetUpdates.isEmpty()) update assetUpdates;
    }
}
