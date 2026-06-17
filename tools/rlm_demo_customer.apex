Account a = new Account(Name='Coffee Demo Co');
insert a;
Contact c = new Contact(LastName='Espresso', FirstName='Dana', Email='dana.demo@example.com', AccountId=a.Id);
insert c;
System.debug('DEMO_ACCT=' + a.Id + ' EMAIL=dana.demo@example.com');
