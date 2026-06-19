/**
 * Agent action: list an account's OPEN/editable quotes so the agent can offer to EDIT
 * one instead of blindly creating a duplicate. Call this before drafting a new quote.
 */
public with sharing class FindAccountQuotesAction {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
    }
    public class Result {
        @InvocableVariable(label='Has an open quote') public Boolean hasOpenQuote;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
    }

    @InvocableMethod(label='Find Open Quotes for Account' description='Lists the account open/editable quotes (anything not Accepted/Denied/Rejected) with line-item counts and totals. Call this BEFORE drafting a new quote so you can offer to edit an existing one instead of creating a duplicate.')
    public static List<Result> run(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) {
            Result res = new Result();
            Account acct = QuoteDraftService.resolveAccountRecord(r.accountName, r.email);
            if (acct == null) {
                res.hasOpenQuote = false;
                res.summary = 'No matching account found.';
                out.add(res); continue;
            }
            List<Quote> qs = QuoteDraftService.findOpenQuotes(acct.Id);
            if (qs.isEmpty()) {
                res.hasOpenQuote = false;
                res.summary = acct.Name + ' has no open quotes — safe to create a new one.';
            } else {
                res.hasOpenQuote = true;
                List<String> lines = new List<String>();
                for (Quote q : qs) {
                    Decimal total = q.GrandTotal != null ? q.GrandTotal : q.TotalPrice;
                    Integer items = q.QuoteLineItems != null ? q.QuoteLineItems.size() : 0;
                    lines.add('Quote ' + q.QuoteNumber + ' (' + q.Status + ', ' + items + ' item' + (items == 1 ? '' : 's')
                        + ', $' + (total == null ? '0' : total.setScale(2).format()) + ')');
                }
                res.summary = acct.Name + ' already has ' + qs.size() + ' open quote' + (qs.size() == 1 ? '' : 's') + ': '
                    + String.join(lines, '; ') + '. Offer to EDIT one (add a product, change quantity, apply a discount, '
                    + 'update status/expiration) rather than create a duplicate — only make a new quote if the rep asks.';
            }
            out.add(res);
        }
        return out;
    }
}
