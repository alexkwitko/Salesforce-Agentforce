// Cleans stale Codex-generated proof artifacts from the tiny Developer Edition
// org while keeping the newest June 15 certification evidence.

DateTime keepAfter = DateTime.newInstanceGmt(2026, 6, 15, 8, 0, 0);
Map<String, Integer> deletedByObject = new Map<String, Integer>();
Map<String, Integer> purgedByObject = new Map<String, Integer>();
Map<String, Integer> failuresByObject = new Map<String, Integer>();

List<Case> duplicateCases = [
    SELECT Id
    FROM Case
    WHERE CaseNumber IN ('00001075', '00001076')
];
Set<Id> duplicateCaseIds = new Set<Id>();
for (Case duplicateCase : duplicateCases) {
    duplicateCaseIds.add(duplicateCase.Id);
}

List<Task> duplicateTranscriptTasks = duplicateCaseIds.isEmpty()
    ? new List<Task>()
    : [SELECT Id FROM Task WHERE WhatId IN :duplicateCaseIds];
Database.DeleteResult[] taskDeletes = Database.delete(duplicateTranscriptTasks, false);
List<Task> deletedTasks = new List<Task>();
Integer taskFailures = 0;
for (Integer i = 0; i < taskDeletes.size(); i++) {
    if (taskDeletes[i].isSuccess()) {
        deletedTasks.add(duplicateTranscriptTasks[i]);
    } else {
        taskFailures++;
    }
}
Integer taskPurgeFailures = 0;
if (!deletedTasks.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedTasks)) {
        if (!r.isSuccess()) {
            taskPurgeFailures++;
        }
    }
}
deletedByObject.put('Task_duplicate_service_proofs', deletedTasks.size());
purgedByObject.put('Task_duplicate_service_proofs', deletedTasks.size() - taskPurgeFailures);
failuresByObject.put('Task_duplicate_service_proofs', taskFailures + taskPurgeFailures);

List<Agent_Interaction__c> staleInteractions = [
    SELECT Id
    FROM Agent_Interaction__c
    WHERE Name IN ('AI-00105', 'AI-00106')
];
Database.DeleteResult[] interactionDeletes = Database.delete(staleInteractions, false);
List<Agent_Interaction__c> deletedInteractions = new List<Agent_Interaction__c>();
Integer interactionFailures = 0;
for (Integer i = 0; i < interactionDeletes.size(); i++) {
    if (interactionDeletes[i].isSuccess()) {
        deletedInteractions.add(staleInteractions[i]);
    } else {
        interactionFailures++;
    }
}
Integer interactionPurgeFailures = 0;
if (!deletedInteractions.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedInteractions)) {
        if (!r.isSuccess()) {
            interactionPurgeFailures++;
        }
    }
}
deletedByObject.put('Agent_Interaction_duplicate_service_proofs', deletedInteractions.size());
purgedByObject.put('Agent_Interaction_duplicate_service_proofs', deletedInteractions.size() - interactionPurgeFailures);
failuresByObject.put('Agent_Interaction_duplicate_service_proofs', interactionFailures + interactionPurgeFailures);

List<MessagingSession> staleSessions = [
    SELECT Id
    FROM MessagingSession
    WHERE CaseId IN :duplicateCaseIds
       OR (CaseId = null AND CreatedDate < :keepAfter)
       OR (Status = 'Ended' AND CreatedDate < :keepAfter)
    LIMIT 200
];
Database.DeleteResult[] sessionDeletes = Database.delete(staleSessions, false);
List<MessagingSession> deletedSessions = new List<MessagingSession>();
Integer sessionFailures = 0;
for (Integer i = 0; i < sessionDeletes.size(); i++) {
    if (sessionDeletes[i].isSuccess()) {
        deletedSessions.add(staleSessions[i]);
    } else {
        sessionFailures++;
    }
}
Integer sessionPurgeFailures = 0;
if (!deletedSessions.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedSessions)) {
        if (!r.isSuccess()) {
            sessionPurgeFailures++;
        }
    }
}
deletedByObject.put('MessagingSession_stale_proofs', deletedSessions.size());
purgedByObject.put('MessagingSession_stale_proofs', deletedSessions.size() - sessionPurgeFailures);
failuresByObject.put('MessagingSession_stale_proofs', sessionFailures + sessionPurgeFailures);

Database.DeleteResult[] caseDeletes = Database.delete(duplicateCases, false);
List<Case> deletedCases = new List<Case>();
Integer caseFailures = 0;
for (Integer i = 0; i < caseDeletes.size(); i++) {
    if (caseDeletes[i].isSuccess()) {
        deletedCases.add(duplicateCases[i]);
    } else {
        caseFailures++;
    }
}
Integer casePurgeFailures = 0;
if (!deletedCases.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedCases)) {
        if (!r.isSuccess()) {
            casePurgeFailures++;
        }
    }
}
deletedByObject.put('Case_duplicate_service_proofs', deletedCases.size());
purgedByObject.put('Case_duplicate_service_proofs', deletedCases.size() - casePurgeFailures);
failuresByObject.put('Case_duplicate_service_proofs', caseFailures + casePurgeFailures);

List<Cart_Item__c> staleCartItems = [
    SELECT Id
    FROM Cart_Item__c
    WHERE Cart__r.CreatedDate < :keepAfter
];
Database.DeleteResult[] cartItemDeletes = Database.delete(staleCartItems, false);
List<Cart_Item__c> deletedCartItems = new List<Cart_Item__c>();
Integer cartItemFailures = 0;
for (Integer i = 0; i < cartItemDeletes.size(); i++) {
    if (cartItemDeletes[i].isSuccess()) {
        deletedCartItems.add(staleCartItems[i]);
    } else {
        cartItemFailures++;
    }
}
Integer cartItemPurgeFailures = 0;
if (!deletedCartItems.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedCartItems)) {
        if (!r.isSuccess()) {
            cartItemPurgeFailures++;
        }
    }
}
deletedByObject.put('Cart_Item_stale_proofs', deletedCartItems.size());
purgedByObject.put('Cart_Item_stale_proofs', deletedCartItems.size() - cartItemPurgeFailures);
failuresByObject.put('Cart_Item_stale_proofs', cartItemFailures + cartItemPurgeFailures);

List<Cart__c> staleCarts = [
    SELECT Id
    FROM Cart__c
    WHERE CreatedDate < :keepAfter
];
Database.DeleteResult[] cartDeletes = Database.delete(staleCarts, false);
List<Cart__c> deletedCarts = new List<Cart__c>();
Integer cartFailures = 0;
for (Integer i = 0; i < cartDeletes.size(); i++) {
    if (cartDeletes[i].isSuccess()) {
        deletedCarts.add(staleCarts[i]);
    } else {
        cartFailures++;
    }
}
Integer cartPurgeFailures = 0;
if (!deletedCarts.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedCarts)) {
        if (!r.isSuccess()) {
            cartPurgeFailures++;
        }
    }
}
deletedByObject.put('Cart_stale_proofs', deletedCarts.size());
purgedByObject.put('Cart_stale_proofs', deletedCarts.size() - cartPurgeFailures);
failuresByObject.put('Cart_stale_proofs', cartFailures + cartPurgeFailures);

List<Lead> staleProofLeads = [
    SELECT Id
    FROM Lead
    WHERE Email LIKE 'alexkwitko+codex%'
];
Database.DeleteResult[] leadDeletes = Database.delete(staleProofLeads, false);
List<Lead> deletedLeads = new List<Lead>();
Integer leadFailures = 0;
for (Integer i = 0; i < leadDeletes.size(); i++) {
    if (leadDeletes[i].isSuccess()) {
        deletedLeads.add(staleProofLeads[i]);
    } else {
        leadFailures++;
    }
}
Integer leadPurgeFailures = 0;
if (!deletedLeads.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedLeads)) {
        if (!r.isSuccess()) {
            leadPurgeFailures++;
        }
    }
}
deletedByObject.put('Lead_stale_codex_proofs', deletedLeads.size());
purgedByObject.put('Lead_stale_codex_proofs', deletedLeads.size() - leadPurgeFailures);
failuresByObject.put('Lead_stale_codex_proofs', leadFailures + leadPurgeFailures);

List<Coupon__c> staleCoupons = [
    SELECT Id
    FROM Coupon__c
    WHERE Code__c LIKE 'KW-FRIEND-%'
       OR Code__c LIKE 'KW-CODEX-%'
       OR Code__c IN ('COMEBACK5013', 'COMEBACK2259', 'BREWSIN0735', 'BREWSIN0736')
       OR Account__r.PersonEmail LIKE 'alexkwitko+codex%'
       OR Order__r.Account.PersonEmail LIKE 'alexkwitko+codex%'
];
Database.DeleteResult[] couponDeletes = Database.delete(staleCoupons, false);
List<Coupon__c> deletedCoupons = new List<Coupon__c>();
Integer couponFailures = 0;
for (Integer i = 0; i < couponDeletes.size(); i++) {
    if (couponDeletes[i].isSuccess()) {
        deletedCoupons.add(staleCoupons[i]);
    } else {
        couponFailures++;
    }
}
Integer couponPurgeFailures = 0;
if (!deletedCoupons.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedCoupons)) {
        if (!r.isSuccess()) {
            couponPurgeFailures++;
        }
    }
}
deletedByObject.put('Coupon_stale_codex_proofs', deletedCoupons.size());
purgedByObject.put('Coupon_stale_codex_proofs', deletedCoupons.size() - couponPurgeFailures);
failuresByObject.put('Coupon_stale_codex_proofs', couponFailures + couponPurgeFailures);

List<OrderItem> staleOrderItems = [
    SELECT Id
    FROM OrderItem
    WHERE Order.Account.PersonEmail LIKE 'alexkwitko+codex%'
];
Database.DeleteResult[] orderItemDeletes = Database.delete(staleOrderItems, false);
List<OrderItem> deletedOrderItems = new List<OrderItem>();
Integer orderItemFailures = 0;
for (Integer i = 0; i < orderItemDeletes.size(); i++) {
    if (orderItemDeletes[i].isSuccess()) {
        deletedOrderItems.add(staleOrderItems[i]);
    } else {
        orderItemFailures++;
    }
}
Integer orderItemPurgeFailures = 0;
if (!deletedOrderItems.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedOrderItems)) {
        if (!r.isSuccess()) {
            orderItemPurgeFailures++;
        }
    }
}
deletedByObject.put('OrderItem_stale_codex_proofs', deletedOrderItems.size());
purgedByObject.put('OrderItem_stale_codex_proofs', deletedOrderItems.size() - orderItemPurgeFailures);
failuresByObject.put('OrderItem_stale_codex_proofs', orderItemFailures + orderItemPurgeFailures);

List<Order> staleOrders = [
    SELECT Id, Status
    FROM Order
    WHERE Account.PersonEmail LIKE 'alexkwitko+codex%'
];
for (Order staleOrder : staleOrders) {
    staleOrder.Status = 'Draft';
}
if (!staleOrders.isEmpty()) {
    Database.update(staleOrders, false);
}
Database.DeleteResult[] orderDeletes = Database.delete(staleOrders, false);
List<Order> deletedOrders = new List<Order>();
Integer orderFailures = 0;
for (Integer i = 0; i < orderDeletes.size(); i++) {
    if (orderDeletes[i].isSuccess()) {
        deletedOrders.add(staleOrders[i]);
    } else {
        orderFailures++;
    }
}
Integer orderPurgeFailures = 0;
if (!deletedOrders.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedOrders)) {
        if (!r.isSuccess()) {
            orderPurgeFailures++;
        }
    }
}
deletedByObject.put('Order_stale_codex_proofs', deletedOrders.size());
purgedByObject.put('Order_stale_codex_proofs', deletedOrders.size() - orderPurgeFailures);
failuresByObject.put('Order_stale_codex_proofs', orderFailures + orderPurgeFailures);

List<Account> staleAccounts = [
    SELECT Id
    FROM Account
    WHERE PersonEmail LIKE 'alexkwitko+codex%'
      AND Woo_Customer_Id__c = null
];
Database.DeleteResult[] accountDeletes = Database.delete(staleAccounts, false);
List<Account> deletedAccounts = new List<Account>();
Integer accountFailures = 0;
for (Integer i = 0; i < accountDeletes.size(); i++) {
    if (accountDeletes[i].isSuccess()) {
        deletedAccounts.add(staleAccounts[i]);
    } else {
        accountFailures++;
    }
}
Integer accountPurgeFailures = 0;
if (!deletedAccounts.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(deletedAccounts)) {
        if (!r.isSuccess()) {
            accountPurgeFailures++;
        }
    }
}
deletedByObject.put('Account_stale_codex_proofs', deletedAccounts.size());
purgedByObject.put('Account_stale_codex_proofs', deletedAccounts.size() - accountPurgeFailures);
failuresByObject.put('Account_stale_codex_proofs', accountFailures + accountPurgeFailures);

List<Contact> staleDeletedContacts = [
    SELECT Id
    FROM Contact
    WHERE IsDeleted = true
      AND Email LIKE 'alexkwitko+codex%'
    ALL ROWS
];
Integer contactPurgeFailures = 0;
Integer purgedContacts = 0;
if (!staleDeletedContacts.isEmpty()) {
    for (Database.EmptyRecycleBinResult r : Database.emptyRecycleBin(staleDeletedContacts)) {
        if (r.isSuccess()) {
            purgedContacts++;
        } else {
            contactPurgeFailures++;
        }
    }
}
purgedByObject.put('Contact_stale_codex_deleted', purgedContacts);
failuresByObject.put('Contact_stale_codex_deleted', contactPurgeFailures);

System.debug('KWITKO_STALE_CODEX_PROOF_CLEANUP deleted=' + JSON.serialize(deletedByObject));
System.debug('KWITKO_STALE_CODEX_PROOF_CLEANUP purged=' + JSON.serialize(purgedByObject));
System.debug('KWITKO_STALE_CODEX_PROOF_CLEANUP failures=' + JSON.serialize(failuresByObject));
