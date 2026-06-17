/**
 * FsMaintenanceService — shared helpers for the Field Service Maintenance Concierge.
 * Customer-facing self-service over WorkOrder / ServiceAppointment / ServiceContract.
 * (Built headless-testable as an employee agent; the production customer-facing version
 * republishes as a Service Agent on MIAW with a loggedInEmail linked var — same actions.)
 */
public with sharing class FsMaintenanceService {

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }

    public static Account resolve(String accountName, String email) {
        if (String.isNotBlank(email)) {
            List<Contact> c = [SELECT AccountId FROM Contact WHERE Email = :email AND AccountId != null LIMIT 1];
            if (!c.isEmpty()) return [SELECT Id, Name FROM Account WHERE Id = :c[0].AccountId LIMIT 1];
        }
        if (String.isNotBlank(accountName)) {
            List<Account> a = [SELECT Id, Name FROM Account WHERE Name = :accountName LIMIT 1];
            if (!a.isEmpty()) return a[0];
            String p = '%' + accountName + '%';
            List<Account> f = [SELECT Id, Name FROM Account WHERE Name LIKE :p LIMIT 1];
            if (!f.isEmpty()) return f[0];
        }
        return null;
    }

    // Accepts YYYY-MM-DD; defaults to 7 days out if blank/unparseable.
    public static Date parseDate(String s) {
        if (String.isBlank(s)) return Date.today().addDays(7);
        try { return Date.valueOf(s.trim()); } catch (Exception e) { return Date.today().addDays(7); }
    }

    // Only PENDING ('None') visits are self-serviceable — never touch already-dispatched/scheduled appointments.
    public static ServiceAppointment soonestUpcoming(Id accountId) {
        List<ServiceAppointment> sa = [
            SELECT Id, Subject, Status, EarliestStartTime, DueDate, SchedStartTime, ArrivalWindowStartTime
            FROM ServiceAppointment
            WHERE AccountId = :accountId AND Status = 'None'
            ORDER BY EarliestStartTime ASC NULLS LAST LIMIT 1
        ];
        return sa.isEmpty() ? null : sa[0];
    }

    public static String fmt(Datetime dt) { return dt == null ? 'TBD' : dt.format('EEE MMM d, yyyy'); }
}
