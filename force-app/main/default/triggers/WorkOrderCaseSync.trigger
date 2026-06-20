/** Drive the linked service Case status from the Work Order status. */
trigger WorkOrderCaseSync on WorkOrder (after insert, after update) {
    FieldServiceCaseSync.syncFromWorkOrders(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
