trigger MessagingSessionBrandStampTrigger on MessagingSession (before insert) {
    MessagingSessionBrandStamp.stamp(Trigger.new);
}
