Date t = Date.today();
Id wt = [SELECT Id FROM WorkType LIMIT 1].Id;
Account a = new Account(Name='Roastery Wholesale'); insert a;
Asset asset = new Asset(Name='Coffee Club Subscription', AccountId=a.Id,
    Quantity=8, Price=180, Status='Installed', InstallDate=t, UsageEndDate=t.addYears(1));
insert asset;
ServiceContract sc = new ServiceContract(Name='Coffee Club - Care Plan', AccountId=a.Id,
    StartDate=t, EndDate=t.addYears(1)); insert sc;
MaintenancePlan mp = new MaintenancePlan(StartDate=t, EndDate=t.addYears(1),
    ServiceContractId=sc.Id, DoesAutoGenerateWorkOrders=false, WorkTypeId=wt,
    GenerationTimeframe=3, GenerationTimeframeType='Months', GenerationHorizon=30,
    WorkOrderGenerationMethod='WorkOrderLineItemPerAsset', SvcApptGenerationMethod='SvcApptPerWorkOrder');
insert mp;
insert new MaintenanceWorkRule(Title='Quarterly Service', SortOrder=1, Type='WorkOrder',
    RecurrencePattern='FREQ=MONTHLY;INTERVAL=3', ParentMaintenancePlanId=mp.Id, WorkTypeId=wt,
    NextSuggestedMaintenanceDate=t.addMonths(3));
insert new MaintenanceAsset(MaintenancePlanId=mp.Id, AssetId=asset.Id, WorkTypeId=wt,
    NextSuggestedMaintenanceDate=t.addMonths(3));
System.debug('COUPLING_SETUP ASSET='+asset.Id+' SC='+sc.Id+' MP='+mp.Id);
