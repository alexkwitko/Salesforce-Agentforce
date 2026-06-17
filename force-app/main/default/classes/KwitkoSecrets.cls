/**
 * KwitkoSecrets — central read of secrets stored OUTSIDE Apex source (Protected
 * Custom Metadata `Kwitko_Secret__mdt`). Keeps signing keys out of version control.
 */
public with sharing class KwitkoSecrets {
    @TestVisible private static Map<String,String> overrides = new Map<String,String>();
    public static String get(String name) {
        if (overrides.containsKey(name)) return overrides.get(name);
        Kwitko_Secret__mdt m = Kwitko_Secret__mdt.getInstance(name);
        return (m != null) ? m.Value__c : null;
    }
    /** WooCommerce webhook/identify HMAC secret (must match KWITKO_WHK_SECRET in wp-config). */
    public static String whk() {
        String s = get('WHK_Secret');
        return String.isNotBlank(s) ? s : 'test-placeholder-secret-not-for-prod';
    }
}
