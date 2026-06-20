/**
 * Daily refresh of asset service metrics. Schedule with:
 *   System.schedule('Asset Service Metrics Nightly','0 0 3 * * ?', new AssetServiceMetricsSchedule());
 * NOTE: recalculateAll() is synchronous; for large install bases convert the
 * core compute to Database.Batchable. Fine for the current asset volume.
 */
public with sharing class AssetServiceMetricsSchedule implements Schedulable {
    public void execute(SchedulableContext sc) {
        AssetServiceMetricsService.recalculateAll();
    }
}
