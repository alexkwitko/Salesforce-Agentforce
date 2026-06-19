/**
 * Agent action: draft a COMPLETE standard Quote from natural language in one shot.
 * Nothing is required. The action creates + links everything itself (Account resolve,
 * Opportunity, Pricebook, line item, expiration, billing/shipping, Draft status) and
 * defaults account/product sensibly when not given — so "create a quote" just works
 * without interrogating the user for nine fields.
 */
public with sharing class DraftQuoteAction {
    public class Request {
        @InvocableVariable(label='Account Name (optional)') public String accountName;
        @InvocableVariable(label='Account Email (optional)') public String email;
        @InvocableVariable(label='Product code or name (optional)') public String product;
        @InvocableVariable(label='Quantity (optional, default 1)') public Decimal quantity;
        @InvocableVariable(label='Discount percent (optional, default 0)') public Decimal discountPercent;
        @InvocableVariable(label='Create a new quote even if the account already has an open one (default false)') public Boolean forceNew;
    }

    @InvocableMethod(label='Draft a Quote' description='Creates a complete, ready-to-review Salesforce Quote in one step: resolves the account, auto-creates/links the Opportunity, uses the standard price book, adds a line item, copies billing/shipping from the account, sets a 30-day expiration and Draft status. All inputs are optional and default sensibly; do NOT ask the user for quote name, opportunity, pricebook, addresses, expiration, or status — this action fills them in.')
    public static List<QuoteDraftService.Result> run(List<Request> reqs) {
        List<QuoteDraftService.Result> out = new List<QuoteDraftService.Result>();
        for (Request r : reqs) {
            QuoteDraftService.Result res = new QuoteDraftService.Result();
            try {
                Account acct = QuoteDraftService.resolveAccountRecord(r.accountName, r.email);
                if (acct == null) {
                    res.success = false;
                    res.summary = 'There are no accounts in this org yet, so I can\'t draft a quote. Create an account first.';
                    out.add(res); continue;
                }
                // Don't silently duplicate: if the account already has an open quote, guide to edit it.
                if (r.forceNew != true) {
                    List<Quote> open = QuoteDraftService.findOpenQuotes(acct.Id);
                    if (!open.isEmpty()) {
                        Quote q0 = open[0];
                        Decimal t = q0.GrandTotal != null ? q0.GrandTotal : q0.TotalPrice;
                        Integer items = q0.QuoteLineItems != null ? q0.QuoteLineItems.size() : 0;
                        res.success = true; res.quoteId = q0.Id;
                        res.summary = 'I did NOT create a new quote — ' + acct.Name + ' already has an open one: Quote '
                            + q0.QuoteNumber + ' (' + q0.Status + ', ' + items + ' item' + (items == 1 ? '' : 's')
                            + ', $' + (t == null ? '0' : t.setScale(2).format()) + '). Want me to edit it (add a product, '
                            + 'change quantity, apply a discount, update status) or create a brand-new quote anyway?';
                        out.add(res); continue;
                    }
                }
                Decimal qty = (r.quantity == null || r.quantity <= 0) ? 1 : r.quantity;
                Decimal disc = (r.discountPercent == null || r.discountPercent < 0) ? 0 : r.discountPercent;
                if (disc > 100) disc = 100;

                Id stdPb = QuoteDraftService.standardPricebookId();
                PricebookEntry pbe = QuoteDraftService.findEntry(r.product, stdPb);
                if (pbe == null) {
                    res.success = false;
                    res.summary = 'There are no active priced products on the standard price book, so I can\'t add a line item. Add a product with a standard price first.';
                    out.add(res); continue;
                }

                Opportunity opp = QuoteDraftService.findOrCreateOpp(acct.Id);
                Id quoteId = QuoteDraftService.createComplete(acct, opp, pbe, stdPb, qty, disc);

                Quote saved = [SELECT QuoteNumber, GrandTotal, TotalPrice, ExpirationDate FROM Quote WHERE Id = :quoteId];
                Decimal total = saved.GrandTotal != null ? saved.GrandTotal : saved.TotalPrice;
                res.success = true;
                res.quoteId = quoteId;
                res.summary = 'Done — drafted Quote ' + saved.QuoteNumber + ' for ' + acct.Name + '.'
                    + ' Linked to Opportunity "' + opp.Name + '", line item: '
                    + qty.intValue() + ' × ' + pbe.Product2.Name + ' @ $' + pbe.UnitPrice.setScale(2).format()
                    + (disc > 0 ? (' (' + disc.intValue() + '% off)') : '')
                    + ', total $' + (total == null ? '0' : total.setScale(2).format())
                    + '. Standard price book, billing/shipping copied from the account, expires '
                    + (saved.ExpirationDate == null ? 'in 30 days' : saved.ExpirationDate.format())
                    + ', status Draft. Tell me a different account, product, quantity, or discount to adjust it.';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t draft the quote: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
