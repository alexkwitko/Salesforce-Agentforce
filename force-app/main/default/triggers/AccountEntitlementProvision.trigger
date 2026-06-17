trigger AccountEntitlementProvision on Account (after insert) {
    // Give every new customer (Person Account) a Standard Support entitlement so their Cases get SLAs.
    AccountEntitlementProvisioner.provision(Trigger.new);
}
