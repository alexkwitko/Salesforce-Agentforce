/**
 * Mock tax calculator for the Bean & Brew D2C store — flat 8% on each cart line.
 * Implements the standard checkout tax integration so the LWR checkout shows a tax line.
 * Demo only (no real tax service). Register via StoreIntegratedService(ServiceProviderType='Tax').
 */
global without sharing class BeanBrewMockTax implements sfdc_checkout.CartTaxCalculations {
    global sfdc_checkout.IntegrationStatus startCartProcessAsync(
            sfdc_checkout.IntegrationInfo jobInfo, Id cartId) {
        sfdc_checkout.IntegrationStatus status = new sfdc_checkout.IntegrationStatus();
        try {
            final Double RATE = 0.08;
            List<CartItem> items = [
                SELECT Id, TotalAmount, TotalLineAmount, Sku, Type, CartId
                FROM CartItem
                WHERE CartId = :cartId AND Type = 'Product'
            ];
            List<CartTax> taxes = new List<CartTax>();
            // clear any prior tax for these items
            delete [SELECT Id FROM CartTax WHERE CartItemId IN (SELECT Id FROM CartItem WHERE CartId = :cartId)];
            for (CartItem ci : items) {
                Decimal base = (ci.TotalLineAmount != null) ? ci.TotalLineAmount
                              : (ci.TotalAmount != null ? ci.TotalAmount : 0);
                taxes.add(new CartTax(
                    CartItemId = ci.Id,
                    Name = 'Sales Tax (8%)',
                    Amount = (base * RATE).setScale(2),
                    TaxType = 'Estimated'
                ));
            }
            if (!taxes.isEmpty()) insert taxes;
            status.status = sfdc_checkout.IntegrationStatus.Status.SUCCESS;
        } catch (Exception e) {
            status.status = sfdc_checkout.IntegrationStatus.Status.FAILED;
            System.debug(LoggingLevel.ERROR, 'Mock tax failed: ' + e.getMessage());
        }
        return status;
    }
}
