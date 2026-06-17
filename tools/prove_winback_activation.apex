Integer added = AtRiskCampaignBuilder.run();
Integer sent = AtRiskCampaignBuilder.sendWinBack();

List<CampaignMember> members = [
    SELECT Id, Status, Contact.Email, Contact.Account.Name, Contact.Account.Data_Cloud_Churn_Risk__c,
           Contact.Account.Churn_Score__c, Contact.Account.Predicted_LTV__c
    FROM CampaignMember
    WHERE Campaign.Name = :AtRiskCampaignBuilder.CAMPAIGN_NAME
    ORDER BY LastModifiedDate DESC
    LIMIT 10
];

System.debug('KWITKO_WINBACK_PROOF added=' + added + ' sent=' + sent + ' members=' + JSON.serialize(members));
