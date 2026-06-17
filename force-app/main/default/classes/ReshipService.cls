/** ReshipService (reship) — creates a zero-charge replacement order (same items) for a lost/damaged delivery
 *  and opens a case. Identity-gated, journey-logged. */
public without sharing class ReshipService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Items to Replace' description='Comma-separated product names the shopper chose to replace, or "all"/blank for the whole order.') public String itemsToReplace;
        @InvocableVariable(label='Reason') public String reason;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms the free replacement/reship.') public Boolean confirmed;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the reship conversation so the Case carries the chat trail.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String replacementOrderNumber; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Reship Order' description='Creates a free replacement order (same items) for a lost or damaged delivery and opens a case. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        String displayNo=KwitkoServiceUtil.displayOrderNumber(o);
        if(r.confirmed!=true){ res.message='Please confirm you want a free replacement/reship for order '+displayNo+' before I create it.'; return res; }
        String reason=String.isBlank(r.reason)?'Lost/damaged delivery':r.reason.trim();
        Order src=[SELECT Id, OrderNumber, AccountId, Pricebook2Id, ShippingStreet, ShippingCity, ShippingStateCode, ShippingPostalCode, ShippingCountryCode FROM Order WHERE Id=:o.Id LIMIT 1];
        // Select which items to replace (blank/"all" = whole order).
        List<OrderItem> allItems=[SELECT PricebookEntryId, Product2Id, Product2.Name, Quantity FROM OrderItem WHERE OrderId=:src.Id];
        List<OrderItem> chosen=pickItems(allItems, r.itemsToReplace);
        if(chosen.isEmpty()){ res.message='I couldn\'t match "'+r.itemsToReplace+'" to an item on order '+displayNo+'. It has: '+itemList(allItems)+'. Which would you like replaced — or say "all"?'; return res; }
        Boolean partial=chosen.size()<allItems.size();
        Order rep=new Order(AccountId=src.AccountId, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=src.Pricebook2Id, Source__c='Manual',
            Fulfillment_Status__c='Processing', ShippingStreet=src.ShippingStreet, ShippingCity=src.ShippingCity, ShippingStateCode=src.ShippingStateCode,
            ShippingPostalCode=src.ShippingPostalCode, ShippingCountryCode=src.ShippingCountryCode,
            Status_Note__c='Free replacement (reship, '+(partial?itemList(chosen):'all items')+') for order '+displayNo+' by Chat Agent. Reason: '+reason);
        insert rep;
        List<OrderItem> cloneItems=new List<OrderItem>();
        for(OrderItem oi:chosen){
            cloneItems.add(new OrderItem(OrderId=rep.Id, PricebookEntryId=oi.PricebookEntryId, Product2Id=oi.Product2Id, Quantity=oi.Quantity, UnitPrice=0));
        }
        if(!cloneItems.isEmpty()) insert cloneItems;
        update new Order(Id=rep.Id, Status='Activated');
        res.replacementOrderNumber=[SELECT OrderNumber FROM Order WHERE Id=:rep.Id].OrderNumber;
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Order__c=src.Id, Origin='Chat', Status='New', Priority='High', Category__c='Shipping',
            Subject='Reship — order '+displayNo, Summary__c='Replacement request '+res.replacementOrderNumber+' recorded for '+displayNo+'. Woo fulfillment still needs operations review. Reason: '+reason,
            Description=appendChatTranscript(reason, r.chatSummary));
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        insertChatTranscript(c.Id, acc.PersonContactId, r.chatSummary);
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='reship'; lr.stage='Service'; lr.orderId=String.valueOf(src.Id);
            lr.result='Reship '+res.replacementOrderNumber+' for '+displayNo+'; case '+res.caseNumber; JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
        res.success=true; res.message='I recorded the free replacement request for '+displayNo+' ('+(partial?itemList(chosen):'all items')+'). Case '+res.caseNumber+' is open for operations to create/fulfill it in WooCommerce; no replacement has shipped yet.';
        return res;
    }
    private static List<OrderItem> pickItems(List<OrderItem> all, String sel){
        String s=(sel==null)?'':sel.trim().toLowerCase();
        if(String.isBlank(s)||s=='all'||s=='everything'||s=='all items'||s.contains('whole order')||s.contains('entire order')) return all;
        List<String> frags=new List<String>(); for(String f:s.split(',')){ if(String.isNotBlank(f)) frags.add(f.trim()); }
        List<OrderItem> picked=new List<OrderItem>(); Set<Id> seen=new Set<Id>();
        for(OrderItem oi:all){ String nm=(oi.Product2!=null&&oi.Product2.Name!=null)?oi.Product2.Name.toLowerCase():'';
            for(String fr:frags){ if(nm.contains(fr)||fr.contains(nm)){ if(!seen.contains(oi.Id)){ picked.add(oi); seen.add(oi.Id);} break; } } }
        return picked;
    }
	    private static String itemList(List<OrderItem> items){
	        List<String> parts=new List<String>();
	        for(OrderItem oi:items){ Integer q=(oi.Quantity==null)?1:oi.Quantity.intValue(); String nm=(oi.Product2!=null&&oi.Product2.Name!=null)?oi.Product2.Name:'item'; parts.add(q+'× '+nm); }
	        return String.join(parts, ', ');
	    }
    private static String appendChatTranscript(String existing, String chatSummary){
        return CaseTranscriptUtil.append(existing, chatSummary);
    }
    private static void insertChatTranscript(Id caseId, Id contactId, String chatSummary){
        CaseTranscriptUtil.insertTask(caseId, contactId, chatSummary);
    }
}
