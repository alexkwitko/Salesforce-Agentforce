trigger OrderBrandStampTrigger on OrderItem (after insert) {
    Set<Id> orderIds = new Set<Id>();
    for (OrderItem oi : Trigger.new) if (oi.OrderId != null) orderIds.add(oi.OrderId);
    OrderBrandStamp.stamp(orderIds);
}
