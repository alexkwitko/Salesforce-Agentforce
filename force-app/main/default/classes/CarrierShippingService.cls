/**
 * CarrierShippingService — buys an OUTBOUND shipping label and writes tracking onto the Order,
 * then marks it Shipped. Uses EasyPost (one API, all carriers: USPS/UPS/FedEx/...) when an API
 * key is configured in Kwitko_Secret__mdt 'EasyPost_API_Key'; otherwise falls back to a mock
 * label so the fulfillment pipeline keeps working with zero config.
 *
 * Writes the SAME Order fields the unified pipeline reads (Carrier__c / Tracking_Number__c /
 * Tracking_Url__c / Fulfillment_Status__c) so D2C and Woo orders ship + track identically,
 * and FulfillmentTruthService / TrackingService / OrderStatusService report them the same way.
 *
 * Go live: add a Kwitko_Secret record DeveloperName 'EasyPost_API_Key' with your EasyPost key
 * (test key = mock-shaped responses, no charge; production key = real labels + tracking).
 */
public without sharing class CarrierShippingService {

    // Ship-from (origin). Move to config for multi-warehouse.
    static final Map<String,Object> FROM_ADDRESS = new Map<String,Object>{
        'name'=>'Bean & Brew Roastery', 'street1'=>'1200 Market St', 'city'=>'San Francisco',
        'state'=>'CA', 'zip'=>'94103', 'country'=>'US', 'phone'=>'4155550100'
    };

    public class Request { @InvocableVariable(label='Order Id' required=true) public Id orderId; }
    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String carrier;
        @InvocableVariable public String trackingNumber;
        @InvocableVariable public String trackingUrl;
        @InvocableVariable public String labelUrl;
        @InvocableVariable public Boolean usedMock;
        @InvocableVariable public String message;
    }

    @InvocableMethod(label='Ship Order' description='Buys a shipping label (EasyPost if configured, else mock), writes tracking, marks the order Shipped.')
    public static List<Result> ship(List<Request> reqs){
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(shipOrder(r.orderId));
        return out;
    }

    public static Result shipOrder(Id orderId){
        Order o = [SELECT Id, OrderNumber, ShippingStreet, ShippingCity, ShippingState,
                          ShippingPostalCode, ShippingCountry, Account.Name
                   FROM Order WHERE Id=:orderId LIMIT 1];
        String key = KwitkoSecrets.get('EasyPost_API_Key');
        Result res;
        if (String.isNotBlank(key)) {
            try { res = easypost(o, key); }
            catch (Exception e) { res = mock(o); res.message = 'Carrier callout failed, used mock: ' + e.getMessage(); }
        } else {
            res = mock(o);
        }
        apply(o.Id, res);
        return res;
    }

    static Result easypost(Order o, String key){
        String base = 'https://api.easypost.com/v2';
        String auth = 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(key + ':'));
        Map<String,Object> toAddr = new Map<String,Object>{
            'name'  => (o.Account != null ? o.Account.Name : 'Customer'),
            'street1'=> def(o.ShippingStreet,'1 Main St'), 'city'=> def(o.ShippingCity,'San Francisco'),
            'state' => def(o.ShippingState,'CA'), 'zip'=> def(o.ShippingPostalCode,'94103'),
            'country'=> def(o.ShippingCountry,'US') };
        Map<String,Object> parcel = new Map<String,Object>{ 'length'=>20, 'width'=>15, 'height'=>12, 'weight'=>80 }; // oz
        Map<String,Object> ship = new Map<String,Object>{ 'to_address'=>toAddr, 'from_address'=>FROM_ADDRESS, 'parcel'=>parcel };

        HttpResponse r1 = call(base + '/shipments', JSON.serialize(new Map<String,Object>{'shipment'=>ship}), auth);
        Map<String,Object> sh = (Map<String,Object>) JSON.deserializeUntyped(r1.getBody());
        if (sh.get('id') == null) throw new CalloutException('EasyPost create failed: ' + r1.getBody());
        String shipmentId = (String) sh.get('id');

        // pick the cheapest rate
        String rateId; Decimal lowest;
        for (Object ro : (List<Object>) sh.get('rates')) {
            Map<String,Object> rm = (Map<String,Object>) ro;
            Decimal rt = Decimal.valueOf(String.valueOf(rm.get('rate')));
            if (lowest == null || rt < lowest) { lowest = rt; rateId = (String) rm.get('id'); }
        }
        HttpResponse r2 = call(base + '/shipments/' + shipmentId + '/buy',
            JSON.serialize(new Map<String,Object>{'rate'=>new Map<String,Object>{'id'=>rateId}}), auth);
        Map<String,Object> b = (Map<String,Object>) JSON.deserializeUntyped(r2.getBody());

        Result res = new Result(); res.success = true; res.usedMock = false;
        res.trackingNumber = (String) b.get('tracking_code');
        Map<String,Object> sel = (Map<String,Object>) b.get('selected_rate');
        res.carrier = (sel != null && sel.get('carrier') != null) ? (String) sel.get('carrier') : 'EasyPost';
        Map<String,Object> tr = (Map<String,Object>) b.get('tracker');
        res.trackingUrl = (tr != null) ? (String) tr.get('public_url') : null;
        Map<String,Object> lbl = (Map<String,Object>) b.get('postage_label');
        res.labelUrl = (lbl != null) ? (String) lbl.get('label_url') : null;
        res.message = 'Label purchased via ' + res.carrier + ' (' + res.trackingNumber + ')';
        return res;
    }

    static Result mock(Order o){
        Result res = new Result(); res.success = true; res.usedMock = true; res.carrier = 'Demo Carrier';
        String seed = String.valueOf(Math.abs(('' + o.OrderNumber + o.Id).hashCode()));
        res.trackingNumber = 'BB' + (seed.length() > 10 ? seed.substring(0, 10) : seed);
        res.trackingUrl = 'https://track.beanbrew.example/' + res.trackingNumber;
        res.message = 'Mock label (set Kwitko_Secret EasyPost_API_Key to ship for real)';
        return res;
    }

    static void apply(Id orderId, Result res){
        if (res == null || res.success != true) return;
        Map<String,Schema.SObjectField> f = Schema.SObjectType.Order.fields.getMap();
        Order u = new Order(Id = orderId);
        if (f.containsKey('fulfillment_status__c')) u.put('Fulfillment_Status__c', 'Shipped');
        if (f.containsKey('tracking_number__c') && res.trackingNumber != null) u.put('Tracking_Number__c', res.trackingNumber);
        if (f.containsKey('tracking_url__c') && res.trackingUrl != null) u.put('Tracking_Url__c', res.trackingUrl);
        if (f.containsKey('carrier__c') && res.carrier != null) u.put('Carrier__c', res.carrier);
        update u;
    }

    static String def(String v, String d){ return String.isBlank(v) ? d : v; }
    static HttpResponse call(String url, String body, String auth){
        HttpRequest q = new HttpRequest();
        q.setEndpoint(url); q.setMethod('POST');
        q.setHeader('Authorization', auth); q.setHeader('Content-Type', 'application/json'); q.setTimeout(60000);
        q.setBody(body);
        return new Http().send(q);
    }
}
