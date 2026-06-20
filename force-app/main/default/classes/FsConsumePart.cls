/** Agent/tech action: consume a part on the visit (decrements van stock; requests + return visit if short). */
public with sharing class FsConsumePart {
    public class Request {
        @InvocableVariable(label='Work Order Id' required=true) public Id workOrderId;
        @InvocableVariable(label='Part code or name' required=true) public String productCode;
        @InvocableVariable(label='Quantity') public Decimal quantity;
    }
    @InvocableMethod(label='Consume Part'
        description='Uses a part on the visit; if it is not on the van, raises a parts request and schedules a return visit.')
    public static List<FieldPartsService.Result> run(List<Request> reqs) {
        List<FieldPartsService.Result> out = new List<FieldPartsService.Result>();
        for (Request r : reqs) out.add(FieldPartsService.consumePart(r.workOrderId, r.productCode, r.quantity));
        return out;
    }
}
