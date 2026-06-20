/**
 * Agent action: book a maintenance visit — Case-first.
 * Creates Case -> WorkOrder(CaseId, AssetId, ServiceContract, Entitlement) -> WorkOrderLineItem -> ServiceAppointment.
 * The SA insert fires ServiceAppointmentAutopilot (territory + ES&O auto-schedule).
 */
public with sharing class FsBookVisit {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Preferred date (YYYY-MM-DD)') public String preferredDate;
        @InvocableVariable(label='Chosen slot start (ISO, optional)') public String slotStart;
        @InvocableVariable(label='Problem description (optional)') public String problem;
    }

    @InvocableMethod(label='Book Maintenance Visit'
        description='Opens a service Case and books a visit (Case -> Work Order -> Line Item -> Service Appointment, pending dispatch).')
    public static List<FsMaintenanceService.Result> run(List<Request> reqs) {
        List<FsMaintenanceService.Result> out = new List<FsMaintenanceService.Result>();
        for (Request r : reqs) {
            FsMaintenanceService.Result res = new FsMaintenanceService.Result();
            if (!IdentityService.isVerified(r.email, r.verifiedEmail)) {
                res.success = false; res.summary = IdentityService.signInMessage(); out.add(res); continue;
            }
            Account acc = FsMaintenanceService.resolve(r.accountName, r.email);
            if (acc == null) { res.success = false; res.summary = 'I couldn\'t find that account.'; out.add(res); continue; }

            // Resolve optional context: asset, contract, entitlement (SLA), contact, work type
            List<Asset> assets = [SELECT Id, Name FROM Asset WHERE AccountId = :acc.Id AND Status = 'Installed' LIMIT 1];
            Id assetId = assets.isEmpty() ? null : assets[0].Id;
            List<ServiceContract> scs = [SELECT Id FROM ServiceContract WHERE AccountId = :acc.Id AND EndDate >= :Date.today() ORDER BY EndDate DESC LIMIT 1];
            List<Entitlement> ents = [SELECT Id FROM Entitlement WHERE AccountId = :acc.Id AND (EndDate = null OR EndDate >= :Date.today()) ORDER BY EndDate DESC NULLS LAST LIMIT 1];
            List<Contact> cons = String.isBlank(r.email) ? new List<Contact>()
                : [SELECT Id FROM Contact WHERE Email = :r.email AND AccountId = :acc.Id LIMIT 1];
            List<WorkType> wts = [SELECT Id, EstimatedDuration, DurationType FROM WorkType WHERE Name = 'Annual Maintenance Visit' LIMIT 1];
            Id wtId = wts.isEmpty() ? null : wts[0].Id;

            String problem = String.isBlank(r.problem) ? 'Routine maintenance visit' : r.problem;

            // 1) Case — system of record for the request
            Case kase = new Case(
                AccountId = acc.Id,
                ContactId = cons.isEmpty() ? null : cons[0].Id,
                AssetId = assetId,
                EntitlementId = ents.isEmpty() ? null : ents[0].Id,
                Subject = 'Maintenance visit — ' + acc.Name,
                Description = problem,
                Origin = 'Web',
                Status = 'New',
                Priority = 'Medium'
            );
            insert kase;

            // 2) Work Order on the Case (with a schedulable territory so the candidate engine can book it)
            WorkOrder wo = new WorkOrder(
                CaseId = kase.Id, AccountId = acc.Id, ContactId = cons.isEmpty() ? null : cons[0].Id,
                Subject = 'Maintenance visit', Status = 'New', WorkTypeId = wtId,
                AssetId = assetId,
                ServiceTerritoryId = resolveTerritory(acc.Id),
                ServiceContractId = scs.isEmpty() ? null : scs[0].Id,
                EntitlementId = ents.isEmpty() ? null : ents[0].Id
            );
            insert wo;

            // 3) Work Order Line Item — the task to perform
            insert new WorkOrderLineItem(
                WorkOrderId = wo.Id, WorkTypeId = wtId,
                Description = problem,
                Duration = wts.isEmpty() ? 1 : wts[0].EstimatedDuration,
                DurationType = wts.isEmpty() ? 'Hours' : wts[0].DurationType,
                Status = 'New'
            );

            // 4) Service Appointment (the visit) — pending dispatch.
            // A WorkType with ShouldAutoCreateSvcAppt=true already spawned one on WO/WOLI insert;
            // tailor that SA (window + reason) and drop any duplicates. Fallback: create one.
            Datetime earliest = resolveStart(r.slotStart, r.preferredDate);
            List<ServiceAppointment> autoSas = [
                SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :wo.Id ORDER BY CreatedDate ASC
            ];
            if (autoSas.isEmpty()) {
                insert new ServiceAppointment(
                    ParentRecordId = wo.Id, Subject = 'Maintenance visit',
                    EarliestStartTime = earliest, DueDate = earliest.addDays(7),
                    ArrivalWindowStartTime = earliest, ArrivalWindowEndTime = earliest.addHours(4),
                    Visit_Reason__c = 'Initial Visit', Status = 'None'
                );
            } else {
                ServiceAppointment keep = autoSas[0];
                keep.Subject = 'Maintenance visit';
                keep.EarliestStartTime = earliest; keep.DueDate = earliest.addDays(7);
                keep.ArrivalWindowStartTime = earliest; keep.ArrivalWindowEndTime = earliest.addHours(4);
                keep.Visit_Reason__c = 'Initial Visit';
                update keep;
                if (autoSas.size() > 1) {
                    List<ServiceAppointment> extra = new List<ServiceAppointment>();
                    for (Integer i = 1; i < autoSas.size(); i++) extra.add(autoSas[i]);
                    delete extra;
                }
            }

            res.success = true;
            res.summary = 'Booked! I opened service case ' + kase.Subject + ' and requested a visit for '
                + acc.Name + ' around ' + FsMaintenanceService.fmt(earliest)
                + ' (morning window). Our dispatch team will confirm the exact time.';
            out.add(res);
        }
        return out;
    }

    // Resolve a schedulable ServiceTerritory for the account: reuse prior service territory,
    // else a territory that has an active resource (so it can actually be booked), else any active one.
    private static Id resolveTerritory(Id accountId) {
        for (WorkOrder w : [SELECT ServiceTerritoryId FROM WorkOrder
                            WHERE AccountId = :accountId AND ServiceTerritoryId != null
                            ORDER BY CreatedDate DESC LIMIT 1]) {
            return w.ServiceTerritoryId;
        }
        for (ServiceTerritoryMember m : [SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                            WHERE ServiceResource.IsActive = true AND ServiceTerritory.IsActive = true
                            ORDER BY CreatedDate ASC LIMIT 1]) {
            return m.ServiceTerritoryId;
        }
        for (ServiceTerritory t : [SELECT Id FROM ServiceTerritory WHERE IsActive = true ORDER BY CreatedDate ASC LIMIT 1]) {
            return t.Id;
        }
        return null;
    }

    // Prefer an explicit ISO slot; else 9am on the preferred date.
    private static Datetime resolveStart(String slotIso, String preferredDate) {
        if (String.isNotBlank(slotIso)) {
            try { return (Datetime) JSON.deserialize('"' + slotIso.trim() + '"', Datetime.class); }
            catch (Exception e) { /* fall through */ }
        }
        Date d = FsMaintenanceService.parseDate(preferredDate);
        return Datetime.newInstance(d, Time.newInstance(9, 0, 0, 0));
    }
}
