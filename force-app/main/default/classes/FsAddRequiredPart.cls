/** Agent/tech action: add a required part to a work order. */
public with sharing class FsAddRequiredPart {
    public class Request {
        @InvocableVariable(label='Work Order Id' required=true) public Id workOrderId;
        @InvocableVariable(label='Part code or name' required=true) public String productCode;
        @InvocableVariable(label='Quantity') public Decimal quantity;
    }
    @InvocableMethod(label='Add Required Part'
        description='Records a part the work order needs (ProductRequired).')
    public static List<FieldPartsService.Result> run(List<Request> reqs) {
        List<FieldPartsService.Result> out = new List<FieldPartsService.Result>();
        for (Request r : reqs) out.add(FieldPartsService.requirePart(r.workOrderId, r.productCode, r.quantity));
        return out;
    }
}
