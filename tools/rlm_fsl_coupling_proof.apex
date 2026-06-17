Id ASSET='02ifj000002Ook5AAC', MP='1MPfj000002VZWbGAO', SC='810fj0000DSIE7NAQX';
Savepoint sp = Database.setSavepoint();
try {
  MaintenancePlan b4mp=[SELECT EndDate FROM MaintenancePlan WHERE Id=:MP];
  ServiceContract b4sc=[SELECT EndDate FROM ServiceContract WHERE Id=:SC];
  System.debug('BEFORE        MP.EndDate='+b4mp.EndDate+'  SC.EndDate='+b4sc.EndDate);

  // RENEW: extend the subscription asset 
  Asset a=[SELECT Id,Status,UsageEndDate FROM Asset WHERE Id=:ASSET];
  a.UsageEndDate=Date.newInstance(2029,12,31); update a;          // fires coupling trigger
  MaintenancePlan r1=[SELECT EndDate FROM MaintenancePlan WHERE Id=:MP];
  ServiceContract r2=[SELECT EndDate FROM ServiceContract WHERE Id=:SC];
  System.debug('AFTER RENEW   MP.EndDate='+r1.EndDate+'  SC.EndDate='+r2.EndDate);

  // CANCEL: obsolete the subscription asset
  a.Status='Obsolete'; update a;                                  // fires coupling trigger
  MaintenancePlan c1=[SELECT EndDate,DoesAutoGenerateWorkOrders FROM MaintenancePlan WHERE Id=:MP];
  ServiceContract c2=[SELECT EndDate FROM ServiceContract WHERE Id=:SC];
  System.debug('AFTER CANCEL  MP.EndDate='+c1.EndDate+'  autoGen='+c1.DoesAutoGenerateWorkOrders+'  SC.EndDate='+c2.EndDate);
} finally {
  Database.rollback(sp);   // undo EVERYTHING — real FSL chain left untouched
  System.debug('ROLLED_BACK (no changes persisted)');
}
