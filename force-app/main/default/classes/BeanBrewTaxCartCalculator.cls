/**
 * Bean & Brew tax calculator on the MODERN Cart Extension framework (GA).
 * Flat 8% per product line — parity with the legacy BeanBrewMockTax (sfdc_checkout) class.
 *
 * This is the migration-ready replacement for BeanBrewMockTax. The two frameworks are
 * mutually exclusive per store, so cutting over means:
 *   1. Deploy this class (done by deploying this file).
 *   2. Register it against the Commerce_Domain_Tax_CartCalculator extension point and map
 *      it to the Bean & Brew store (Cart Extensions setup / CartExtension registration).
 *   3. Remove the legacy Tax StoreIntegratedService + RegisteredExternalService (BeanBrew_Mock_Tax).
 *   4. VERIFY with a live storefront checkout before trusting it — tax calc cannot be proven headlessly.
 *
 * Modeled on Salesforce's official TaxCartCalculatorSample (forcedotcom/commerce-extensibility),
 * simplified to a self-contained flat rate (no external callout).
 */
public with sharing class BeanBrewTaxCartCalculator extends CartExtension.TaxCartCalculator {

    private static final Decimal TAX_RATE = 0.08;
    private static final String TAX_NAME = 'Sales Tax (8%)';

    public virtual override void calculate(CartExtension.CartCalculateCalculatorRequest request) {
        CartExtension.Cart cart = request.getCart();
        CartExtension.CartItemList cartItems = cart.getCartItems();
        CartExtension.TaxLocaleTypeEnum taxType = cart.getTaxType();

        Iterator<CartExtension.CartItem> it = cartItems.iterator();
        while (it.hasNext()) {
            CartExtension.CartItem cartItem = it.next();

            // Only tax product lines (shipping/charge lines are handled elsewhere).
            if (cartItem.getType() != CartExtension.SalesItemTypeEnum.PRODUCT) {
                continue;
            }

            Double amountD = (cartItem.getTotalPriceAfterAllAdjustments() == null)
                ? cartItem.getTotalListPrice()
                : cartItem.getTotalPriceAfterAllAdjustments();
            if (amountD == null) {
                continue;
            }

            Decimal amount = Decimal.valueOf(amountD);
            Decimal qty = cartItem.getQuantity();
            if (qty == null || qty == 0) {
                qty = 1;
            }
            Decimal taxAmount = (amount * TAX_RATE).setScale(2);

            // Replace any previously-calculated taxes on this line (idempotent re-runs).
            CartExtension.CartTaxList taxes = cartItem.getCartTaxes();
            while (taxes.size() > 0) {
                taxes.remove(taxes.get(0));
            }

            Decimal grossUnit;
            Decimal netUnit;
            if (taxType == CartExtension.TaxLocaleTypeEnum.GROSS) {
                grossUnit = (amount / qty).setScale(2);
                netUnit = ((amount - taxAmount) / qty).setScale(2);
            } else {
                grossUnit = ((amount + taxAmount) / qty).setScale(2);
                netUnit = (amount / qty).setScale(2);
            }
            cartItem.setNetUnitPrice(netUnit);
            cartItem.setGrossUnitPrice(grossUnit);

            CartExtension.CartTax cartTax = new CartExtension.CartTax(
                CartExtension.TaxTypeEnum.ESTIMATED,
                taxAmount,
                TAX_NAME);
            cartTax.setTaxRate(String.valueOf(TAX_RATE));
            taxes.add(cartTax);
        }
    }
}
