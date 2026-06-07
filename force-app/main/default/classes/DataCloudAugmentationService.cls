/**
 * DataCloudAugmentationService caches unified-profile and calculated-insight context on Account.
 * Agent actions read these fields only through verified identity gates.
 */
public without sharing class DataCloudAugmentationService {
    @TestVisible private static Map<String, List<Object>> testRowsBySqlToken;

    public class Request {
        @InvocableVariable(label='Email') public String email;
        @InvocableVariable(label='Verified Email') public String verifiedEmail;
        @InvocableVariable(label='Account Id') public String accountId;
        @InvocableVariable(label='Refresh From Data Cloud') public Boolean refreshFromDataCloud;
        @InvocableVariable(label='Update Account') public Boolean updateAccount;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public Boolean identityVerified;
        @InvocableVariable public String accountId;
        @InvocableVariable public String unifiedIndividualId;
        @InvocableVariable public String segment;
        @InvocableVariable public String churnRisk;
        @InvocableVariable public String nextBestAction;
        @InvocableVariable public Integer orderCount;
        @InvocableVariable public Decimal lifetimeValue;
        @InvocableVariable public Decimal averageOrderValue;
        @InvocableVariable public String lastOrderDate;
        @InvocableVariable public String favoriteCategory;
        @InvocableVariable public Integer returnCount;
        @InvocableVariable public String insightSource;
        @InvocableVariable public String profileSummary;
        @InvocableVariable public String message;
    }

    private class Metrics {
        Integer orderCount = 0;
        Integer orders12Mo = 0;
        Decimal lifetimeValue = 0;
        Decimal averageOrderValue = 0;
        Date lastOrderDate;
        String favoriteCategory;
        Integer returnCount = 0;
        Integer openCaseCount = 0;
        String segment = 'New';
        String churnRisk = 'Low';
        String nextBestAction;
        String source = 'CRM fallback';
    }

    private class DataCloudProfile {
        Boolean found = false;
        String individualId;
        String firstName;
        String coffeePreferences;
    }

    @InvocableMethod(label='Refresh Data Cloud Account Augmentation'
        description='Refreshes Account fields used by Agentforce from Data Cloud calculated insights and CRM fallback context. Requires verified email unless Account Id is supplied by a trusted internal automation.')
    public static List<Result> refresh(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(refreshOne(r));
        return out;
    }

    public static void refreshAccount(Id accountId) {
        if (accountId == null) return;
        Request r = new Request();
        r.accountId = String.valueOf(accountId);
        r.refreshFromDataCloud = false;
        r.updateAccount = true;
        refreshOne(r);
    }

    @TestVisible
    private static Result refreshOne(Request r) {
        Result res = new Result();
        res.success = false;
        if (r == null) {
            res.message = 'No request provided.';
            return res;
        }

        Boolean trustedAccountId = String.isNotBlank(r.accountId);
        Boolean verified = trustedAccountId || IdentityService.isVerified(r.email, r.verifiedEmail);
        res.identityVerified = verified;
        if (!verified) {
            res.message = 'Identity not verified. Data Cloud augmentation was not returned or updated.';
            return res;
        }

        Account a = findAccount(r);
        if (a == null) {
            res.message = 'No Account found for the supplied identity.';
            return res;
        }
        res.accountId = String.valueOf(a.Id);

        Metrics m = crmMetrics(a);
        DataCloudProfile profile = new DataCloudProfile();
        Boolean useDataCloud = (r.refreshFromDataCloud == true)
            && (!Test.isRunningTest() || testRowsBySqlToken != null);
        if (useDataCloud) {
            profile = dcUnifiedProfile(String.isBlank(r.email) ? a.PersonEmail : r.email);
            applyDataCloudCalculatedInsights(m, a.Id);
        }

        finalizeRules(m, a);
        String summary = buildProfileSummary(m, profile);
        Boolean shouldUpdate = r.updateAccount != false;
        if (shouldUpdate) updateAccount(a.Id, m, profile, summary);

        res.success = true;
        res.unifiedIndividualId = profile.individualId;
        res.segment = m.segment;
        res.churnRisk = m.churnRisk;
        res.nextBestAction = m.nextBestAction;
        res.orderCount = m.orderCount;
        res.lifetimeValue = m.lifetimeValue;
        res.averageOrderValue = m.averageOrderValue;
        res.lastOrderDate = m.lastOrderDate == null ? null : String.valueOf(m.lastOrderDate);
        res.favoriteCategory = m.favoriteCategory;
        res.returnCount = m.returnCount;
        res.insightSource = m.source;
        res.profileSummary = summary;
        res.message = 'Account augmentation refreshed from ' + m.source + '.';
        return res;
    }

    private static Account findAccount(Request r) {
        if (String.isNotBlank(r.accountId)) {
            try {
                Id accountId = (Id) r.accountId;
                List<Account> rows = [
                    SELECT Id, Name, PersonEmail, Return_Count__c, Winback_Needed__c
                    FROM Account WHERE Id = :accountId LIMIT 1
                ];
                return rows.isEmpty() ? null : rows[0];
            } catch (Exception e) {
                return null;
            }
        }
        if (String.isBlank(r.email)) return null;
        List<Account> rows = [
            SELECT Id, Name, PersonEmail, Return_Count__c, Winback_Needed__c
            FROM Account WHERE PersonEmail = :r.email LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Metrics crmMetrics(Account a) {
        Metrics m = new Metrics();
        Id accountId = a.Id;
        m.orderCount = [SELECT count() FROM Order WHERE AccountId = :accountId];
        m.orders12Mo = [SELECT count() FROM Order WHERE AccountId = :accountId AND CreatedDate = LAST_N_DAYS:365];
        for (AggregateResult ar : [SELECT SUM(TotalAmount) total, AVG(TotalAmount) avgAmount, MAX(EffectiveDate) lastDate
                                   FROM Order WHERE AccountId = :accountId]) {
            m.lifetimeValue = dec(ar.get('total'));
            m.averageOrderValue = dec(ar.get('avgAmount'));
            m.lastOrderDate = dateVal(ar.get('lastDate'));
        }

        Map<String, Decimal> qty = new Map<String, Decimal>();
        for (OrderItem oi : [SELECT Product2.Family, Quantity FROM OrderItem WHERE Order.AccountId = :accountId]) {
            String fam = (oi.Product2 == null || String.isBlank(oi.Product2.Family)) ? 'Coffee' : oi.Product2.Family;
            qty.put(fam, (qty.get(fam) == null ? 0 : qty.get(fam)) + (oi.Quantity == null ? 0 : oi.Quantity));
        }
        Decimal best = -1;
        for (String fam : qty.keySet()) {
            if (qty.get(fam) > best) {
                best = qty.get(fam);
                m.favoriteCategory = fam;
            }
        }

        try {
            m.returnCount = [SELECT count() FROM ReturnOrder WHERE AccountId = :accountId];
        } catch (Exception e) {
            m.returnCount = 0;
        }
        if (a.Return_Count__c != null && a.Return_Count__c.intValue() > m.returnCount) {
            m.returnCount = a.Return_Count__c.intValue();
        }
        try {
            m.openCaseCount = [SELECT count() FROM Case WHERE AccountId = :accountId AND IsClosed = false];
        } catch (Exception e) {
            m.openCaseCount = 0;
        }
        return m;
    }

    private static void applyDataCloudCalculatedInsights(Metrics m, Id accountId) {
        try {
            List<Object> row = firstRow('SELECT AccountId__c, OrderCount__c, LifetimeValue__c, AvgOrderValue__c, LastOrderDate__c '
                + 'FROM Customer_Agent_Profile__cio WHERE AccountId__c = \'' + String.escapeSingleQuotes(String.valueOf(accountId)) + '\' LIMIT 1');
            if (row != null) {
                m.orderCount = intVal(cell(row, 1));
                m.lifetimeValue = dec(cell(row, 2));
                m.averageOrderValue = dec(cell(row, 3));
                m.lastOrderDate = dateVal(cell(row, 4));
                m.source = 'Data Cloud CI + CRM fallback';
            }
        } catch (Exception e) {
            // Calculated insights are best-effort; CRM fallback remains authoritative.
        }

        try {
            List<Object> row = firstRow('SELECT ProductCategory__c, CategoryOrderCount__c '
                + 'FROM Customer_Category_Affinity__cio WHERE AccountId__c = \'' + String.escapeSingleQuotes(String.valueOf(accountId))
                + '\' ORDER BY CategoryOrderCount__c DESC LIMIT 1');
            if (row != null && cell(row, 0) != null) {
                m.favoriteCategory = String.valueOf(cell(row, 0));
                m.source = 'Data Cloud CI + CRM fallback';
            }
        } catch (Exception e) {}

        try {
            List<Object> row = firstRow('SELECT ReturnCount__c, LastReturnDate__c '
                + 'FROM Customer_Return_Risk__cio WHERE AccountId__c = \'' + String.escapeSingleQuotes(String.valueOf(accountId)) + '\' LIMIT 1');
            if (row != null && cell(row, 0) != null) {
                m.returnCount = intVal(cell(row, 0));
                m.source = 'Data Cloud CI + CRM fallback';
            }
        } catch (Exception e) {}
    }

    private static void finalizeRules(Metrics m, Account a) {
        m.segment = RecommendationStrategyService.classifyBuyer(m.orderCount, m.lifetimeValue, m.orders12Mo);
        if (m.returnCount >= 2 || m.openCaseCount >= 2 || a.Winback_Needed__c == true) {
            m.churnRisk = 'High';
        } else if (m.returnCount == 1 || m.openCaseCount == 1 || m.segment == 'Lapsed') {
            m.churnRisk = 'Medium';
        } else {
            m.churnRisk = 'Low';
        }

        if (m.churnRisk == 'High') {
            m.nextBestAction = 'Resolve the service or return issue before making a new sales offer.';
        } else if (m.segment == 'VIP') {
            m.nextBestAction = 'Offer a VIP perk or complementary gear recommendation without over-discounting.';
        } else if (m.segment == 'Lapsed') {
            m.nextBestAction = 'Use a winback offer and bias recommendations toward the last favorite category.';
        } else if (m.segment == 'New') {
            m.nextBestAction = 'Ask preference questions and recommend a first-purchase starter option.';
        } else {
            m.nextBestAction = 'Recommend a replenishment or complementary product based on category affinity.';
        }
    }

    private static String buildProfileSummary(Metrics m, DataCloudProfile profile) {
        List<String> parts = new List<String>();
        parts.add('Segment ' + m.segment);
        parts.add('risk ' + m.churnRisk);
        parts.add(String.valueOf(m.orderCount) + ' order(s)');
        Decimal ltv = m.lifetimeValue == null ? 0 : m.lifetimeValue.setScale(2);
        parts.add('LTV ' + String.valueOf(ltv));
        if (String.isNotBlank(m.favoriteCategory)) parts.add('favorite category ' + m.favoriteCategory);
        if (m.returnCount > 0) parts.add(String.valueOf(m.returnCount) + ' return(s)');
        if (profile != null && profile.found) parts.add('unified profile matched');
        parts.add('next action: ' + m.nextBestAction);
        return String.join(parts, '; ');
    }

    private static void updateAccount(Id accountId, Metrics m, DataCloudProfile profile, String summary) {
        Account upd = new Account(Id = accountId);
        if (profile != null && String.isNotBlank(profile.individualId)) {
            upd.Data_Cloud_Unified_Individual_Id__c = trunc(profile.individualId, 80);
        }
        upd.Data_Cloud_Profile_Summary__c = trunc(summary, 32768);
        upd.Data_Cloud_Order_Count__c = m.orderCount == null ? null : Decimal.valueOf(m.orderCount);
        upd.Data_Cloud_Lifetime_Value__c = m.lifetimeValue;
        upd.Data_Cloud_Avg_Order_Value__c = m.averageOrderValue;
        upd.Data_Cloud_Last_Order_Date__c = m.lastOrderDate;
        upd.Data_Cloud_Favorite_Category__c = trunc(m.favoriteCategory, 80);
        upd.Data_Cloud_Return_Count__c = m.returnCount == null ? null : Decimal.valueOf(m.returnCount);
        upd.Data_Cloud_Churn_Risk__c = trunc(m.churnRisk, 40);
        upd.Data_Cloud_Segment__c = trunc(m.segment, 80);
        upd.Data_Cloud_Next_Best_Action__c = trunc(m.nextBestAction, 32768);
        upd.Data_Cloud_Last_Augmented_At__c = System.now();
        upd.Data_Cloud_Insight_Source__c = trunc(m.source, 120);
        update upd;
    }

    private static DataCloudProfile dcUnifiedProfile(String email) {
        DataCloudProfile profile = new DataCloudProfile();
        if (String.isBlank(email)) return profile;
        try {
            String sql = 'SELECT cpe.ssot__EmailAddress__c em, ind.ssot__Id__c individualId, '
                + 'ind.ssot__FirstName__c firstName, ind.Coffee_Preferences__c coffeePreferences '
                + 'FROM ssot__ContactPointEmail__dlm cpe '
                + 'JOIN ssot__Individual__dlm ind ON ind.ssot__Id__c = cpe.ssot__PartyId__c '
                + 'WHERE cpe.ssot__EmailAddress__c = \'' + String.escapeSingleQuotes(email) + '\' LIMIT 1';
            List<Object> row = firstRow(sql);
            if (row == null) return profile;
            profile.found = true;
            if (cell(row, 1) != null) profile.individualId = String.valueOf(cell(row, 1));
            if (cell(row, 2) != null) profile.firstName = String.valueOf(cell(row, 2));
            if (cell(row, 3) != null) profile.coffeePreferences = String.valueOf(cell(row, 3));
        } catch (Exception e) {}
        return profile;
    }

    private static List<Object> firstRow(String sql) {
        if (Test.isRunningTest() && testRowsBySqlToken != null) {
            for (String token : testRowsBySqlToken.keySet()) {
                if (sql != null && sql.contains(token)) return testRowsBySqlToken.get(token);
            }
            return null;
        }
        ConnectApi.CdpQueryInput inp = new ConnectApi.CdpQueryInput();
        inp.sql = sql;
        ConnectApi.CdpQueryOutputV2 out = ConnectApi.CdpQuery.queryAnsiSqlV2(inp);
        if (out == null || out.data == null || out.data.isEmpty()) return null;
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(JSON.serialize(out.data));
        if (rows.isEmpty()) return null;
        return (List<Object>) rows[0];
    }

    private static Object cell(List<Object> row, Integer idx) {
        return row == null || idx == null || row.size() <= idx ? null : row[idx];
    }

    private static Decimal dec(Object v) {
        if (v == null) return 0;
        try { return Decimal.valueOf(String.valueOf(v)); }
        catch (Exception e) { return 0; }
    }

    private static Integer intVal(Object v) {
        return dec(v).intValue();
    }

    private static Date dateVal(Object v) {
        if (v == null) return null;
        try {
            String s = String.valueOf(v);
            return Date.valueOf(s.length() > 10 ? s.substring(0, 10) : s);
        } catch (Exception e) {
            return null;
        }
    }

    private static String trunc(String s, Integer maxLen) {
        if (String.isBlank(s) || maxLen == null || s.length() <= maxLen) return s;
        return s.substring(0, maxLen);
    }
}
