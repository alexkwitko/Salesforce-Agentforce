/** Agent action: draft a standard Quote (+ line item) from natural language. */
public with sharing class DraftQuoteAction {
    public class Request {
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Product (code or name)' required=true) public String product;
        @InvocableVariable(label='Quantity') public Decimal quantity;
        @InvocableVariable(label='Discount percent') public Decimal discountPercent;
    }
    @InvocableMethod(label='Draft a Quote' description='Creates a standard Salesforce Quote with a line item for the product at the catalog price, with an optional discount percent.')
    public static List<QuoteDraftService.Result> run(List<Request> reqs) {
        List<QuoteDraftService.Result> out = new List<QuoteDraftService.Result>();
        for (Request r : reqs) {
            QuoteDraftService.Result res = new QuoteDraftService.Result();
            try {
                Id acct = QuoteDraftService.resolveAccount(r.accountName, r.email);
                if (acct == null) { res.success = false; res.summary = 'No matching account found.'; out.add(res); continue; }
                Decimal qty = (r.quantity == null || r.quantity <= 0) ? 1 : r.quantity;
                Decimal disc = (r.discountPercent == null || r.discountPercent < 0) ? 0 : r.discountPercent;
                if (disc > 100) disc = 100;

                Id stdPb = QuoteDraftService.standardPricebookId();
                PricebookEntry pbe = QuoteDraftService.findEntry(r.product, stdPb);
                if (pbe == null) { res.success = false; res.summary = 'I couldn\'t find an active price for "' + r.product + '" on the standard price book.'; out.add(res); continue; }

                Opportunity opp = QuoteDraftService.findOrCreateOpp(acct);
                Quote q = new Quote(Name = pbe.Product2.Name + ' Quote', OpportunityId = opp.Id,
                    Pricebook2Id = stdPb, Status = 'Draft');
                insert q;
                insert new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = pbe.Product2Id,
                    Quantity = qty, UnitPrice = pbe.UnitPrice, Discount = disc);

                Quote saved = [SELECT QuoteNumber, GrandTotal, TotalPrice FROM Quote WHERE Id = :q.Id];
                Decimal total = saved.GrandTotal != null ? saved.GrandTotal : saved.TotalPrice;
                res.success = true; res.quoteId = q.Id;
                res.summary = 'Drafted Quote ' + saved.QuoteNumber + ' for ' + pbe.Product2.Name + ' — '
                    + qty.intValue() + ' @ $' + pbe.UnitPrice.setScale(2).format()
                    + (disc > 0 ? (' (' + disc.intValue() + '% off)') : '')
                    + ', total $' + (total == null ? '0' : total.setScale(2).format()) + '. It\'s in Draft for your review.';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t draft the quote: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
