// Repairs the live OTP proof session link after the pre-fix linker attached
// Case 00001080 to an older signed-in shopping MessagingSession.

Id otpCaseId = '500fj00001Z0i1CAAR';
Id wrongShoppingSessionId = '0Mwfj00000AtVyHCAV';
Id otpGuestSessionId = '0Mwfj00000AtW7xCAF';

List<MessagingSession> updates = new List<MessagingSession>{
    new MessagingSession(Id = wrongShoppingSessionId, CaseId = null),
    new MessagingSession(Id = otpGuestSessionId, CaseId = otpCaseId)
};

Database.SaveResult[] results = Database.update(updates, false);
Integer successes = 0;
List<String> failures = new List<String>();
for (Integer i = 0; i < results.size(); i++) {
    if (results[i].isSuccess()) {
        successes++;
    } else {
        for (Database.Error err : results[i].getErrors()) {
            failures.add(String.valueOf(updates[i].Id) + ': ' + err.getStatusCode() + ' ' + err.getMessage());
        }
    }
}

System.debug(
    'KWITKO_OTP_SESSION_LINK_REPAIR successes=' + successes
    + ' failures=' + JSON.serialize(failures)
);
