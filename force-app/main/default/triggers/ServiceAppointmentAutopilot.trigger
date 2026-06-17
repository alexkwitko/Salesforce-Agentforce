/**
 * Field Service autopilot:
 *  BEFORE INSERT  — map territory-less SAs to a ServiceTerritory (parent WO inherit / nearest geo)
 *  AFTER  INSERT  — async ES&O auto-schedule (best tech by skills + availability + policy)
 */
trigger ServiceAppointmentAutopilot on ServiceAppointment (before insert, after insert) {
    if (Trigger.isBefore && Trigger.isInsert) FieldServiceAutopilot.assignTerritories(Trigger.new);
    if (Trigger.isAfter  && Trigger.isInsert) FieldServiceAutopilot.autoSchedule(Trigger.new);
}
