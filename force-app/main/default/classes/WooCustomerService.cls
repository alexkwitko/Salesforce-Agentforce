/**
 * WooCustomerService — keeps the Salesforce Person Account in sync when a shopper edits their
 * WooCommerce account (name, marketing consent) or address — even WITHOUT placing an order.
 * Without this, Woo and Salesforce drift (a customer changes their name/address/consent in Woo
 * and CRM never hears about it). Upserts by email; honors an explicit consent opt-OUT (the account
 * page is a deliberate user action), but never invents data. Data Cloud's Account_Home stream then
 * refreshes the unified profile downstream automatically.
 */
public without sharing class WooCustomerService {

    public static Id upsertProfile(Map<String, Object> p) {
        String email = str(p.get('email'));
        if (String.isBlank(email)) return null;

        Id paRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        List<Account> existing = [SELECT Id FROM Account WHERE PersonEmail = :email LIMIT 1];
        Account a = existing.isEmpty()
            ? new Account(RecordTypeId = paRt, PersonEmail = email, LastName = 'Customer')
            : existing[0];

        if (String.isNotBlank(str(p.get('first_name')))) a.FirstName = str(p.get('first_name'));
        if (String.isNotBlank(str(p.get('last_name'))))  a.LastName  = str(p.get('last_name'));
        if (String.isNotBlank(str(p.get('phone'))))      a.Phone     = str(p.get('phone'));

        // Consent: the account page is an explicit user action, so honor an opt-OUT too (unlike the
        // checkout path which only ever upgrades to true). Only act when 'consent' is actually present.
        if (p.containsKey('consent') && p.get('consent') != null) {
            Boolean consent = truthy(p.get('consent'));
            a.Email_Consent__c = consent;
            if (consent) a.Email_Consent_Date__c = System.now();
        }

        applyAddress(a, (Map<String, Object>) p.get('billing'), 'Billing');
        applyAddress(a, (Map<String, Object>) p.get('shipping'), 'Shipping');

        upsert a;
        return a.Id;
    }

    private static void applyAddress(Account a, Map<String, Object> addr, String which) {
        if (addr == null) return;
        String street = joinStreet(str(addr.get('address_1')), str(addr.get('address_2')));
        String city = str(addr.get('city'));
        String postcode = str(addr.get('postcode'));
        String state = str(addr.get('state'));     // Woo sends ISO codes (e.g. DC, WA)
        String country = str(addr.get('country'));  // ISO (e.g. US)
        if (which == 'Billing') {
            if (String.isNotBlank(street))   a.BillingStreet = street;
            if (String.isNotBlank(city))     a.BillingCity = city;
            if (String.isNotBlank(postcode)) a.BillingPostalCode = postcode;
            if (String.isNotBlank(country))  a.BillingCountryCode = country;
            if (String.isNotBlank(state))    a.BillingStateCode = state;
        } else {
            if (String.isNotBlank(street))   a.ShippingStreet = street;
            if (String.isNotBlank(city))     a.ShippingCity = city;
            if (String.isNotBlank(postcode)) a.ShippingPostalCode = postcode;
            if (String.isNotBlank(country))  a.ShippingCountryCode = country;
            if (String.isNotBlank(state))    a.ShippingStateCode = state;
        }
    }

    private static String joinStreet(String a1, String a2) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(a1)) parts.add(a1);
        if (String.isNotBlank(a2)) parts.add(a2);
        return parts.isEmpty() ? null : String.join(parts, '\n');
    }

    private static Boolean truthy(Object o) {
        if (o == null) return false;
        if (o instanceof Boolean) return (Boolean) o;
        String s = String.valueOf(o).toLowerCase();
        return s == '1' || s == 'true' || s == 'yes';
    }
    private static String str(Object o) { return o == null ? '' : String.valueOf(o); }
}
