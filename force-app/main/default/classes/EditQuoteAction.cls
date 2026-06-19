/**
 * Agent action: EDIT an existing quote instead of creating a new one. Targets the given
 * quote number, or the account's latest open quote. Supported operations:
 *   add_product | set_quantity | apply_discount | set_status | set_expiration
 */
public with sharing class EditQuoteAction {
    public class Request {
        @InvocableVariable(label='Quote Number (optional; else the account latest open quote)') public String quoteNumber;
        @InvocableVariable(label='Account Name (to find the quote)') public String accountName;
        @InvocableVariable(label='Account Email') public String email;
        @InvocableVariable(label='Operation: add_product | set_quantity | apply_discount | set_status | set_expiration' required=true) public String operation;
        @InvocableVariable(label='Product (for add_product/set_quantity)') public String product;
        @InvocableVariable(label='Quantity') public Decimal quantity;
        @InvocableVariable(label='Discount percent') public Decimal discountPercent;
        @InvocableVariable(label='Status (for set_status, e.g. Presented)') public String status;
        @InvocableVariable(label='Expiration date YYYY-MM-DD (for set_expiration)') public String expirationDate;
    }

    @InvocableMethod(label='Edit a Quote' description='Edits an EXISTING quote (never creates one). operation is add_product (adds or bumps a line), set_quantity, apply_discount, set_status, or set_expiration. Targets the given quote number, otherwise the account most recent open quote.')
    public static List<QuoteDraftService.Result> run(List<Request> reqs) {
        List<QuoteDraftService.Result> out = new List<QuoteDraftService.Result>();
        for (Request r : reqs) {
            QuoteDraftService.Result res = new QuoteDraftService.Result();
            try {
                Account acct = QuoteDraftService.resolveAccountRecord(r.accountName, r.email);
                Id acctId = (acct == null) ? null : acct.Id;
                Quote quote = QuoteDraftService.resolveQuote(r.quoteNumber, acctId);
                if (quote == null) {
                    res.success = false;
                    res.summary = 'I couldn\'t find an open quote to edit. Tell me the quote number or the account.';
                    out.add(res); continue;
                }
                String op = (r.operation == null) ? '' : r.operation.toLowerCase().trim();
                Decimal disc = (r.discountPercent == null || r.discountPercent < 0) ? 0
                    : (r.discountPercent > 100 ? 100 : r.discountPercent);
                String msg;

                if (op == 'add_product') {
                    Id stdPb = (quote.Pricebook2Id != null) ? quote.Pricebook2Id : QuoteDraftService.standardPricebookId();
                    PricebookEntry pbe = QuoteDraftService.findEntry(r.product, stdPb);
                    if (pbe == null) {
                        res.success = false; res.summary = 'No quotable product matched "' + r.product + '".';
                        out.add(res); continue;
                    }
                    Decimal qty = (r.quantity == null || r.quantity <= 0) ? 1 : r.quantity;
                    QuoteDraftService.addOrBumpLine(quote, pbe, qty, disc);
                    msg = 'Added ' + qty.intValue() + ' × ' + pbe.Product2.Name
                        + (disc > 0 ? (' (' + disc.intValue() + '% off)') : '') + ' to Quote ' + quote.QuoteNumber + '.';
                } else if (op == 'set_quantity') {
                    Decimal qty = (r.quantity == null || r.quantity < 0) ? 1 : r.quantity;
                    if (!QuoteDraftService.setQuantity(quote.Id, r.product, qty)) {
                        res.success = false; res.summary = 'No matching line to update on Quote ' + quote.QuoteNumber + '.';
                        out.add(res); continue;
                    }
                    msg = 'Set quantity to ' + qty.intValue() + ' on Quote ' + quote.QuoteNumber + '.';
                } else if (op == 'apply_discount') {
                    Integer n = QuoteDraftService.applyDiscount(quote.Id, r.product, disc);
                    msg = 'Applied ' + disc.intValue() + '% discount to ' + n + ' line' + (n == 1 ? '' : 's')
                        + ' on Quote ' + quote.QuoteNumber + '.';
                } else if (op == 'set_status') {
                    if (String.isBlank(r.status)) { res.success = false; res.summary = 'Tell me the status to set.'; out.add(res); continue; }
                    QuoteDraftService.setStatus(quote.Id, r.status);
                    msg = 'Set Quote ' + quote.QuoteNumber + ' status to ' + r.status + '.';
                } else if (op == 'set_expiration') {
                    Date d = String.isBlank(r.expirationDate) ? Date.today().addDays(30) : Date.valueOf(r.expirationDate);
                    QuoteDraftService.setExpiration(quote.Id, d);
                    msg = 'Set Quote ' + quote.QuoteNumber + ' expiration to ' + d.format() + '.';
                } else {
                    res.success = false;
                    res.summary = 'Unknown edit operation "' + r.operation + '". Use add_product, set_quantity, apply_discount, set_status, or set_expiration.';
                    out.add(res); continue;
                }

                Quote saved = [SELECT GrandTotal, TotalPrice FROM Quote WHERE Id = :quote.Id];
                Decimal total = saved.GrandTotal != null ? saved.GrandTotal : saved.TotalPrice;
                res.success = true;
                res.quoteId = quote.Id;
                res.summary = msg + ' New total $' + (total == null ? '0' : total.setScale(2).format()) + '.';
            } catch (Exception e) {
                res.success = false; res.summary = 'I couldn\'t edit the quote: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
