/**
 * QuoteDraftService — helpers for the AI Quote-Drafting Copilot.
 * Builds STANDARD Salesforce Quotes (Quote + QuoteLineItem) from natural language —
 * gives an "Agentforce quoting" experience without the gated RLM Place Quote engine.
 *
 * Design rule: the agent should CREATE AND LINK everything itself. The only things it
 * can't invent are which account and which product — and even those fall back to a
 * sensible default so "create a quote" works in one shot. Everything else (Opportunity,
 * Pricebook, expiration date, status, billing/shipping address, description, line item)
 * is auto-created and linked here, never asked of the user.
 */
public with sharing class QuoteDraftService {

    public class Result {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Summary (narrate to user)') public String summary;
        @InvocableVariable(label='Quote Id') public String quoteId;
    }

    // Resolve an Account record (with address fields) by email, then name, then fall back
    // to the most recently created account so a bare "create a quote" still works.
    public static Account resolveAccountRecord(String accountName, String email) {
        if (String.isNotBlank(email)) {
            List<Contact> c = [SELECT AccountId FROM Contact WHERE Email = :email AND AccountId != null LIMIT 1];
            if (!c.isEmpty()) {
                List<Account> a = acctsById(new Set<Id>{ c[0].AccountId });
                if (!a.isEmpty()) return a[0];
            }
        }
        if (String.isNotBlank(accountName)) {
            List<Account> exact = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode,
                BillingCountry, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
                FROM Account WHERE Name = :accountName LIMIT 1];
            if (!exact.isEmpty()) return exact[0];
            String p = '%' + accountName + '%';
            List<Account> fuzzy = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode,
                BillingCountry, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
                FROM Account WHERE Name LIKE :p LIMIT 1];
            if (!fuzzy.isEmpty()) return fuzzy[0];
        }
        // Last resort: most recently created account (keeps one-shot quoting working).
        List<Account> recent = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode,
            BillingCountry, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
            FROM Account ORDER BY CreatedDate DESC LIMIT 1];
        return recent.isEmpty() ? null : recent[0];
    }

    private static List<Account> acctsById(Set<Id> ids) {
        return [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
            ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
            FROM Account WHERE Id IN :ids];
    }

    // Back-compat: id-only resolver used elsewhere.
    public static Id resolveAccount(String accountName, String email) {
        Account a = resolveAccountRecord(accountName, email);
        return a == null ? null : a.Id;
    }

    public static Id standardPricebookId() {
        return [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
    }

    // Quote requires an Opportunity — reuse an open one or create a lightweight one.
    public static Opportunity findOrCreateOpp(Id acctId) {
        List<Opportunity> o = [SELECT Id, Name FROM Opportunity WHERE AccountId = :acctId AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 1];
        if (!o.isEmpty()) return o[0];
        Opportunity opp = new Opportunity(Name = 'New Business', AccountId = acctId,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert opp;
        return opp;
    }

    // Match a product by exact code OR fuzzy name, on the standard price book.
    // Only consider products that are QUOTABLE in this org — i.e. related to a
    // ProductSellingModel (Revenue Cloud / RLM requires this to add a quote line).
    public static PricebookEntry findEntry(String product, Id stdPb) {
        if (String.isBlank(product)) return findDefaultEntry(stdPb);
        String pattern = '%' + product + '%';
        List<PricebookEntry> pbes = [
            SELECT Id, Product2Id, Product2.Name, UnitPrice
            FROM PricebookEntry
            WHERE (Product2.ProductCode = :product OR Product2.Name LIKE :pattern)
                  AND IsActive = true AND Pricebook2Id = :stdPb
                  AND Product2Id IN (SELECT Product2Id FROM ProductSellingModelOption)
            ORDER BY Product2.ProductCode NULLS LAST LIMIT 1
        ];
        return pbes.isEmpty() ? findDefaultEntry(stdPb) : pbes[0];
    }

    // No product given (or not found) → pick a sensible quotable default so quoting still works.
    public static PricebookEntry findDefaultEntry(Id stdPb) {
        List<PricebookEntry> pbes = [
            SELECT Id, Product2Id, Product2.Name, UnitPrice
            FROM PricebookEntry
            WHERE IsActive = true AND Pricebook2Id = :stdPb AND UnitPrice > 0
                  AND Product2Id IN (SELECT Product2Id FROM ProductSellingModelOption)
            ORDER BY LastModifiedDate DESC LIMIT 1
        ];
        return pbes.isEmpty() ? null : pbes[0];
    }

    // Build a FULLY-populated Quote (everything linked + defaulted) and its line item.
    // Returns the inserted Quote id. Copies billing/shipping from the account, sets a
    // 30-day expiration, Draft status, a name, and a description — no user input needed.
    public static Id createComplete(Account acct, Opportunity opp, PricebookEntry pbe, Id stdPb,
                                    Decimal qty, Decimal disc) {
        System.Savepoint sp = Database.setSavepoint();
        try {
            Quote q = new Quote(
                Name = acct.Name + ' – ' + pbe.Product2.Name + ' Quote',
                OpportunityId = opp.Id,
                Pricebook2Id = stdPb,
                Status = 'Draft',
                ExpirationDate = Date.today().addDays(30),
                Description = 'Drafted by the Quote Copilot for ' + acct.Name + '. Review and send.',
                BillingName = acct.Name,
                BillingStreet = acct.BillingStreet,
                BillingCity = acct.BillingCity,
                BillingState = acct.BillingState,
                BillingPostalCode = acct.BillingPostalCode,
                BillingCountry = acct.BillingCountry,
                ShippingName = acct.Name,
                ShippingStreet = acct.ShippingStreet != null ? acct.ShippingStreet : acct.BillingStreet,
                ShippingCity = acct.ShippingCity != null ? acct.ShippingCity : acct.BillingCity,
                ShippingState = acct.ShippingState != null ? acct.ShippingState : acct.BillingState,
                ShippingPostalCode = acct.ShippingPostalCode != null ? acct.ShippingPostalCode : acct.BillingPostalCode,
                ShippingCountry = acct.ShippingCountry != null ? acct.ShippingCountry : acct.BillingCountry
            );
            insert q;
            insert buildLine(q.Id, pbe, qty, disc);
            return q.Id;
        } catch (Exception e) {
            Database.rollback(sp);  // no orphan Quote header if the line item fails
            throw e;
        }
    }

    // Build a QuoteLineItem with the RLM subscription fields set dynamically (so the class
    // still compiles on orgs without Revenue Cloud fields). Shared by create + edit.
    public static QuoteLineItem buildLine(Id quoteId, PricebookEntry pbe, Decimal qty, Decimal disc) {
        QuoteLineItem qli = new QuoteLineItem(QuoteId = quoteId, PricebookEntryId = pbe.Id,
            Product2Id = pbe.Product2Id, Quantity = qty, UnitPrice = pbe.UnitPrice, Discount = disc);
        Map<String, Schema.SObjectField> f = QuoteLineItem.SObjectType.getDescribe().fields.getMap();
        if (f.containsKey('BillingFrequency')) { qli.put('BillingFrequency', 'Monthly'); }
        if (f.containsKey('StartDate')) { qli.put('StartDate', Date.today()); }
        if (f.containsKey('SubscriptionTerm')) { qli.put('SubscriptionTerm', 12); }
        else if (f.containsKey('EndDate')) { qli.put('EndDate', Date.today().addMonths(12)); }
        return qli;
    }

    // ---- Editing existing quotes (so the agent guides "edit" instead of duplicating) ----

    // Open/editable quotes for an account, most-recent first, with their line items.
    public static List<Quote> findOpenQuotes(Id acctId) {
        return [SELECT Id, QuoteNumber, Name, Status, GrandTotal, TotalPrice, ExpirationDate, Pricebook2Id,
                       (SELECT Id, Quantity, UnitPrice, Discount, Product2Id, Product2.Name FROM QuoteLineItems)
                FROM Quote
                WHERE AccountId = :acctId AND Status NOT IN ('Accepted','Denied','Rejected')
                ORDER BY LastModifiedDate DESC LIMIT 10];
    }

    // Resolve a specific quote to edit: by quote number if given, else the latest open one
    // for the account. Accepts a bare number ("10") or the full "00000010".
    public static Quote resolveQuote(String quoteNumber, Id acctId) {
        if (String.isNotBlank(quoteNumber)) {
            String qn = quoteNumber.trim().replaceAll('[^0-9]', '');
            String padded = qn.length() < 8 ? qn.leftPad(8, '0') : qn;
            List<Quote> q = [SELECT Id, QuoteNumber, AccountId, Status, Pricebook2Id
                FROM Quote WHERE QuoteNumber = :padded OR QuoteNumber = :quoteNumber LIMIT 1];
            if (!q.isEmpty()) return q[0];
        }
        if (acctId != null) {
            List<Quote> q = [SELECT Id, QuoteNumber, AccountId, Status, Pricebook2Id
                FROM Quote WHERE AccountId = :acctId AND Status NOT IN ('Accepted','Denied','Rejected')
                ORDER BY LastModifiedDate DESC LIMIT 1];
            if (!q.isEmpty()) return q[0];
        }
        return null;
    }

    // Add or bump a product line on an existing quote (if the product is already on the
    // quote, increase its quantity instead of duplicating the line).
    public static void addOrBumpLine(Quote quote, PricebookEntry pbe, Decimal qty, Decimal disc) {
        List<QuoteLineItem> existing = [SELECT Id, Quantity, Discount FROM QuoteLineItem
            WHERE QuoteId = :quote.Id AND Product2Id = :pbe.Product2Id LIMIT 1];
        if (!existing.isEmpty()) {
            existing[0].Quantity = (existing[0].Quantity == null ? 0 : existing[0].Quantity) + qty;
            if (disc != null && disc > 0) existing[0].Discount = disc;
            update existing[0];
        } else {
            insert buildLine(quote.Id, pbe, qty, disc);
        }
    }

    // Set the quantity of a line (matched by product, else the only/most-recent line).
    public static Boolean setQuantity(Id quoteId, String product, Decimal qty) {
        List<QuoteLineItem> lines = lineFor(quoteId, product);
        if (lines.isEmpty()) return false;
        lines[0].Quantity = qty;
        update lines[0];
        return true;
    }

    // Apply a discount percent to a line (matched by product) or to ALL lines if no product.
    public static Integer applyDiscount(Id quoteId, String product, Decimal disc) {
        List<QuoteLineItem> lines = String.isBlank(product)
            ? [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId]
            : lineFor(quoteId, product);
        for (QuoteLineItem l : lines) l.Discount = disc;
        if (!lines.isEmpty()) update lines;
        return lines.size();
    }

    private static List<QuoteLineItem> lineFor(Id quoteId, String product) {
        if (String.isNotBlank(product)) {
            String p = '%' + product + '%';
            List<QuoteLineItem> m = [SELECT Id, Quantity, Discount FROM QuoteLineItem
                WHERE QuoteId = :quoteId AND Product2.Name LIKE :p ORDER BY CreatedDate DESC LIMIT 1];
            if (!m.isEmpty()) return m;
        }
        return [SELECT Id, Quantity, Discount FROM QuoteLineItem WHERE QuoteId = :quoteId ORDER BY CreatedDate DESC LIMIT 1];
    }

    public static void setStatus(Id quoteId, String status) {
        update new Quote(Id = quoteId, Status = status);
    }

    public static void setExpiration(Id quoteId, Date d) {
        update new Quote(Id = quoteId, ExpirationDate = d);
    }

    // ---- Recommendation-driven product selection (reuse the Product Advisor's brain) ----

    public class RecoPick {
        public PricebookEntry pbe;
        public Decimal qty = 1;
        public Decimal disc = 0;
        public String rationale;
    }

    /**
     * Define the quote's product/quantity/discount via RecommendationStrategyService — the
     * SAME engine the Product Advisor agent uses — when the rep didn't name a product.
     * buildStrategy does CALLOUTS (Data Cloud signals) but no DML with skipJourneyWrite=true,
     * so callers MUST invoke this BEFORE any quote DML. Falls back to a quotable default if the
     * recommended product isn't quotable in this org, or if the engine is unavailable.
     */
    public static RecoPick recommendForQuote(Account acct, Id stdPb) {
        RecoPick pick = new RecoPick();
        try {
            if (!Test.isRunningTest()) {
                RecommendationStrategyService.Request rr = new RecommendationStrategyService.Request();
                rr.channel = 'chat';
                rr.email = primaryContactEmail(acct.Id);   // personalize from the account's contact
                rr.skipJourneyWrite = true;                 // no DML → safe before our inserts
                RecommendationStrategyService.Result rec = RecommendationStrategyService.buildStrategy(
                    new List<RecommendationStrategyService.Request>{ rr })[0];
                // Prefer the recommended primary, then the complementary — but only if quotable here.
                PricebookEntry pbe = quotableEntryForProduct(rec.primaryProductId, stdPb);
                String picked = rec.primaryProductName;
                if (pbe == null) { pbe = quotableEntryForProduct(rec.complementaryProductId, stdPb); picked = rec.complementaryProductName; }
                if (pbe != null) {
                    pick.pbe = pbe;
                    pick.qty = (rec.primaryQuantity != null && rec.primaryQuantity > 0) ? rec.primaryQuantity : 1;
                    pick.disc = (rec.discountPercent != null && rec.discountPercent > 0) ? rec.discountPercent : 0;
                    pick.rationale = 'recommended for the ' + (String.isNotBlank(rec.buyerType) ? rec.buyerType : 'profiled')
                        + ' buyer' + (String.isNotBlank(rec.discountRationale) ? (' — ' + rec.discountRationale) : '');
                    return pick;
                }
                // Recommended product exists but isn't quotable in this org → note it, use a quotable default.
                pick.disc = (rec.discountPercent != null && rec.discountPercent > 0) ? rec.discountPercent : 0;
                pick.pbe = findDefaultEntry(stdPb);
                pick.rationale = (String.isNotBlank(picked) ? ('recommended "' + picked + '" isn\'t quotable here, so ') : '')
                    + 'used a quotable product; kept the ' + (String.isNotBlank(rec.buyerType) ? rec.buyerType : 'profiled') + '-buyer discount';
                return pick;
            }
        } catch (Exception e) {
            // reco engine unavailable → fall through to a quotable default
        }
        pick.pbe = findDefaultEntry(stdPb);
        pick.rationale = 'default quotable product';
        return pick;
    }

    public static PricebookEntry quotableEntryForProduct(String product2Id, Id stdPb) {
        if (String.isBlank(product2Id)) return null;
        List<PricebookEntry> pbes = [
            SELECT Id, Product2Id, Product2.Name, UnitPrice FROM PricebookEntry
            WHERE Product2Id = :product2Id AND IsActive = true AND Pricebook2Id = :stdPb
                  AND Product2Id IN (SELECT Product2Id FROM ProductSellingModelOption) LIMIT 1
        ];
        return pbes.isEmpty() ? null : pbes[0];
    }

    public static String primaryContactEmail(Id acctId) {
        List<Contact> cs = [SELECT Email FROM Contact WHERE AccountId = :acctId AND Email != null ORDER BY CreatedDate LIMIT 1];
        return cs.isEmpty() ? null : cs[0].Email;
    }
}
