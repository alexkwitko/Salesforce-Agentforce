/**
 * Bean & Brew promotions calculator on the modern Cart Extension framework.
 *
 * Context: this store runs Cart Calculate (WebStore.OptionsCartCalculateEnabled=true) with a custom
 * Tax calculator. Under that setup the standard declarative-promotion engine does NOT auto-apply, so
 * this calculator implements the store's promotions and links each adjustment back to the real
 * Promotion record (so reporting/attribution still points at the declarative Promotion).
 *
 * Implemented:
 *   - "Spend $1,500 Get $150 Off" (automatic, transaction-level) -> Promotion 0c8fj0000004L5tAAE
 *
 * Modeled on Salesforce's official PromotionCalculatorSample (forcedotcom/commerce-extensibility).
 */
public with sharing class BeanBrewPromotionsCalculator extends CartExtension.PromotionsCartCalculator {

    private static final String SPEND_PROMO_ID = '0c8fj0000004L5tAAE';
    private static final Decimal SPEND_THRESHOLD = 1500;
    private static final Decimal SPEND_DISCOUNT = 150;

    public virtual override void calculate(CartExtension.CartCalculateCalculatorRequest request) {
        CartExtension.Cart cart = request.getCart();
        resetPromoAdjustments(cart);

        // Sum the product subtotal and capture the highest-value product line to attach the discount to.
        Decimal subtotal = 0;
        CartExtension.CartItem topItem = null;
        Decimal topAmt = -1;
        Iterator<CartExtension.CartItem> it = cart.getCartItems().iterator();
        while (it.hasNext()) {
            CartExtension.CartItem ci = it.next();
            if (ci.getType() != CartExtension.SalesItemTypeEnum.PRODUCT) {
                continue;
            }
            Double amtD = (ci.getTotalLineAmount() == null) ? ci.getTotalListPrice() : ci.getTotalLineAmount();
            Decimal amt = (amtD == null) ? 0 : Decimal.valueOf(amtD);
            subtotal += amt;
            if (amt > topAmt) { topAmt = amt; topItem = ci; }
        }

        if (subtotal >= SPEND_THRESHOLD && topItem != null) {
            Decimal adj = -SPEND_DISCOUNT;
            CartExtension.CartItemPriceAdjustment cia = new CartExtension.CartItemPriceAdjustment(
                CartExtension.CartAdjustmentTargetTypeEnum.ITEM,
                adj,
                CartExtension.PriceAdjustmentSourceEnum.PROMOTION,
                CartExtension.AdjustmentTypeEnum.ADJUSTMENT_AMOUNT,
                adj,
                SPEND_PROMO_ID);
            cia.setPriority(1);
            cia.setAdjustmentAmountScope(CartExtension.AdjustmentAmountScopeEnum.TOTAL);
            cia.setDescription('Spend $1,500 Get $150 Off');
            topItem.getCartItemPriceAdjustments().add(cia);

            Double lineD = (topItem.getTotalLineAmount() == null) ? topItem.getTotalListPrice() : topItem.getTotalLineAmount();
            Decimal lineAmt = (lineD == null) ? topAmt : Decimal.valueOf(lineD);
            topItem.setTotalPromoAdjustmentAmount(adj);
            topItem.setTotalAdjustmentAmount(adj);
            topItem.setTotalPriceAfterAllAdjustments(lineAmt + adj);
        }
    }

    private static void resetPromoAdjustments(CartExtension.Cart cart) {
        // cart-level adjustment groups
        Iterator<CartExtension.CartAdjustmentGroup> cagIt = cart.getCartAdjustmentGroups().iterator();
        List<CartExtension.CartAdjustmentGroup> cags = new List<CartExtension.CartAdjustmentGroup>();
        while (cagIt.hasNext()) { cags.add(cagIt.next()); }
        for (CartExtension.CartAdjustmentGroup cag : cags) { cart.getCartAdjustmentGroups().remove(cag); }

        // item-level promo adjustments
        Iterator<CartExtension.CartItem> ciIt = cart.getCartItems().iterator();
        while (ciIt.hasNext()) {
            CartExtension.CartItem ci = ciIt.next();
            Iterator<CartExtension.CartItemPriceAdjustment> aIt = ci.getCartItemPriceAdjustments().iterator();
            List<CartExtension.CartItemPriceAdjustment> toRemove = new List<CartExtension.CartItemPriceAdjustment>();
            while (aIt.hasNext()) { toRemove.add(aIt.next()); }
            for (CartExtension.CartItemPriceAdjustment a : toRemove) { ci.getCartItemPriceAdjustments().remove(a); }
        }
    }
}
