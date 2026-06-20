/**
 * Field Service autopilot:
 *  BEFORE INSERT  — map territory-less SAs to a ServiceTerritory (parent WO inherit / nearest geo)
 *  AFTER  INSERT  — async ES&O auto-schedule (best tech by skills + availability + policy)
 *  AFTER  UPDATE  — roll SA progress up to the Work Order (which drives the Case)
 */
trigger ServiceAppointmentAutopilot on ServiceAppointment (before insert, after insert, after update) {
    if (Trigger.isBefore && Trigger.isInsert) FieldServiceAutopilot.assignTerritories(Trigger.new);
    if (Trigger.isAfter  && Trigger.isInsert) FieldServiceAutopilot.autoSchedule(Trigger.new);
    if (Trigger.isAfter  && Trigger.isUpdate) FieldServiceAutopilot.syncWorkOrders(Trigger.new, Trigger.oldMap);
}
