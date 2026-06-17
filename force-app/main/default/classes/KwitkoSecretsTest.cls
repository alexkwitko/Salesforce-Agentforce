@isTest
private class KwitkoSecretsTest {
    @isTest static void overrideAndFallback() {
        KwitkoSecrets.overrides.put('WHK_Secret','unit-secret');
        System.assertEquals('unit-secret', KwitkoSecrets.whk());
        System.assertEquals('unit-secret', KwitkoSecrets.get('WHK_Secret'));
        KwitkoSecrets.overrides.clear();
        System.assertNotEquals(null, KwitkoSecrets.whk()); // CMT record or fallback
    }
}
