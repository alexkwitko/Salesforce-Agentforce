@isTest
private class MessagingSessionBrandStampTest {

    @isTest static void brandFor_mapsKnownChannels() {
        System.assertEquals('Kwitko Coffee', MessagingSessionBrandStamp.brandFor('Kwitko_Web_Chat_V2'));
        System.assertEquals('Kwitko Coffee', MessagingSessionBrandStamp.brandFor('Kwitko_Web_Chat'));
        System.assertEquals(null, MessagingSessionBrandStamp.brandFor('Some_Unknown_Channel'));
        System.assertEquals(null, MessagingSessionBrandStamp.brandFor(null));
        System.assertEquals(null, MessagingSessionBrandStamp.brandFor(''));
    }

    @isTest static void stamp_handlesNullAndEmpty() {
        // Must never throw on empty/null input.
        MessagingSessionBrandStamp.stamp(null);
        MessagingSessionBrandStamp.stamp(new List<MessagingSession>());
        // A session with no channel is left untouched.
        MessagingSession s = new MessagingSession();
        MessagingSessionBrandStamp.stamp(new List<MessagingSession>{ s });
        System.assertEquals(null, s.Brand__c);
    }

    @isTest static void stamp_respectsExistingBrand() {
        // Injected mapping so we don't depend on a real channel for this path.
        MessagingSessionBrandStamp.CHANNEL_BRAND = new Map<String,String>{ 'X' => 'Bean & Brew' };
        MessagingSession s = new MessagingSession(Brand__c = 'Kwitko Coffee');
        MessagingSessionBrandStamp.stamp(new List<MessagingSession>{ s });
        System.assertEquals('Kwitko Coffee', s.Brand__c, 'Existing brand must not be overwritten');
    }

    @isTest(SeeAllData=true) static void stamp_setsBrandFromRealChannel() {
        List<MessagingChannel> chs = [SELECT Id, DeveloperName FROM MessagingChannel
                                      WHERE DeveloperName = 'Kwitko_Web_Chat_V2' LIMIT 1];
        if (chs.isEmpty()) return; // channel not present in this org — skip gracefully
        MessagingSession s = new MessagingSession(MessagingChannelId = chs[0].Id);
        Test.startTest();
        MessagingSessionBrandStamp.stamp(new List<MessagingSession>{ s });
        Test.stopTest();
        System.assertEquals('Kwitko Coffee', s.Brand__c, 'Brand should be stamped from the channel');
    }
}
