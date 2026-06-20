/**
 * FieldPartsService — van/warehouse parts inventory for field service.
 *   ProductItem    = stock of a Product2 at an inventory Location (the van / warehouse)
 *   ProductRequired= parts a Work Order needs
 *   ProductConsumed= parts used on a visit -> decrements ProductItem.QuantityOnHand
 *   ProductRequest = replenishment when the part isn't on the van (+ a return visit)
 *
 * Invocable wrappers live in FsAddRequiredPart / FsConsumePart (one @InvocableMethod each).
 */
public with sharing class FieldPartsService {

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String summary;
    }

    /** Declare a part the work order needs (ProductRequired on the WO). */
    public static Result requirePart(Id workOrderId, String productCode, Decimal qty) {
        Result res = new Result(); res.success = false;
        if (workOrderId == null || String.isBlank(productCode)) { res.summary = 'Work order and part code are required.'; return res; }
        Decimal q = (qty == null || qty <= 0) ? 1 : qty;
        Product2 p = findPart(productCode);
        if (p == null) { res.summary = 'I couldn\'t find part ' + productCode + '.'; return res; }

        insert new ProductRequired(
            ParentRecordId = workOrderId, Product2Id = p.Id,
            QuantityRequired = q, QuantityUnitOfMeasure = 'Each'
        );
        res.success = true;
        res.summary = 'Added ' + q + ' x ' + p.Name + ' to the work order\'s required parts.';
        return res;
    }

    /**
     * Consume a part on the visit. If van stock covers it -> ProductConsumed + decrement.
     * If short -> ProductRequest (replenish) + a "Return - Parts Needed" follow-up visit.
     */
    public static Result consumePart(Id workOrderId, String productCode, Decimal qty) {
        Result res = new Result(); res.success = false;
        if (workOrderId == null || String.isBlank(productCode)) { res.summary = 'Work order and part code are required.'; return res; }
        Decimal q = (qty == null || qty <= 0) ? 1 : qty;
        Product2 p = findPart(productCode);
        if (p == null) { res.summary = 'I couldn\'t find part ' + productCode + '.'; return res; }

        // Best-stocked inventory location holding this part
        List<ProductItem> items = [
            SELECT Id, QuantityOnHand, Location.Name FROM ProductItem
            WHERE Product2Id = :p.Id AND QuantityOnHand > 0
            ORDER BY QuantityOnHand DESC LIMIT 1
        ];

        if (!items.isEmpty() && items[0].QuantityOnHand >= q) {
            ProductItem pi = items[0];
            insert new ProductConsumed(
                WorkOrderId = workOrderId, ProductItemId = pi.Id, QuantityConsumed = q
            );
            update new ProductItem(Id = pi.Id, QuantityOnHand = pi.QuantityOnHand - q);
            res.success = true;
            res.summary = 'Used ' + q + ' x ' + p.Name + ' from ' + pi.Location.Name
                + ' (stock now ' + (pi.QuantityOnHand - q) + ').';
            return res;
        }

        // Short on stock -> request the part + schedule a return visit
        ProductRequest pr = new ProductRequest(WorkOrderId = workOrderId, Status = 'Draft', ShipmentType = 'Ship');
        insert pr;
        insert new ProductRequestLineItem(
            ParentId = pr.Id, Product2Id = p.Id, QuantityRequested = q, QuantityUnitOfMeasure = 'Each'
        );
        FieldServiceFollowUp.Result fu = FieldServiceFollowUp.create(
            workOrderId, 'Return - Parts Needed', null, 'Awaiting part: ' + p.Name);

        String prNum = [SELECT ProductRequestNumber FROM ProductRequest WHERE Id = :pr.Id].ProductRequestNumber;
        res.success = true;
        res.summary = p.Name + ' isn\'t on the van. I raised a parts request (' + prNum
            + ') and ' + (fu.success ? 'scheduled a return visit once it arrives.' : 'flagged a return visit.');
        return res;
    }

    private static Product2 findPart(String code) {
        List<Product2> ps = [SELECT Id, Name FROM Product2 WHERE (ProductCode = :code OR Name = :code) AND IsActive = true LIMIT 1];
        if (!ps.isEmpty()) return ps[0];
        String pat = '%' + code + '%';
        ps = [SELECT Id, Name FROM Product2 WHERE Name LIKE :pat AND IsActive = true LIMIT 1];
        return ps.isEmpty() ? null : ps[0];
    }
}
