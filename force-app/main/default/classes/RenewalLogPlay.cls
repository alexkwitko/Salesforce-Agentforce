/** Agent action: log a retention/upsell follow-up task on an account. */
public with sharing class RenewalLogPlay {
    public class Request {
        @InvocableVariable(label='Account Name' required=true) public String accountName;
        @InvocableVariable(label='Play type (e.g. Retention Save, Upsell)' required=true) public String playType;
        @InvocableVariable(label='Note') public String note;
    }
    @InvocableMethod(label='Log Retention or Upsell Play' description='Logs a follow-up Task on the account for a retention or upsell play.')
    public static List<RenewalBookService.Result> run(List<Request> reqs) {
        List<RenewalBookService.Result> out = new List<RenewalBookService.Result>();
        for (Request r : reqs) {
            RenewalBookService.Result res = new RenewalBookService.Result();
            Account acc = RenewalBookService.resolveAccountByName(r.accountName);
            if (acc == null) { res.success = false; res.summary = 'No account found matching "' + r.accountName + '".'; out.add(res); continue; }
            Task t = new Task(
                Subject = 'Renewal play: ' + r.playType,
                WhatId = acc.Id, Status = 'Open', Priority = 'High',
                ActivityDate = Date.today().addDays(3),
                Description = (r.note == null ? '' : r.note)
            );
            insert t;
            res.success = true;
            res.summary = 'Logged a "' + r.playType + '" follow-up task on ' + acc.Name + ' (due in 3 days).';
            out.add(res);
        }
        return out;
    }
}
