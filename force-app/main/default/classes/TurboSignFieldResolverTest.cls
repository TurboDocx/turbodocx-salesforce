@IsTest
private class TurboSignFieldResolverTest {
    @IsTest
    static void resolvesLocalAndCrossObjectPaths() {
        Account a = new Account(Name='Acme Senior Living');
        insert a;
        Opportunity o = new Opportunity(Name='Lease - Acme', StageName='Prospecting',
            CloseDate=Date.today().addDays(30), Amount=1234, AccountId=a.Id);
        insert o;

        TurboSignFieldResolver.ResolveRequest req = new TurboSignFieldResolver.ResolveRequest();
        req.recordId = o.Id;
        req.paths = new List<String>{ 'Name', 'Amount', 'Account.Name' };

        Test.startTest();
        Map<String, Object> vals = TurboSignFieldResolver.resolve(req);
        Test.stopTest();

        System.assertEquals('Lease - Acme', vals.get('Name'), 'local field');
        System.assertEquals(1234, vals.get('Amount'), 'numeric field');
        System.assertEquals('Acme Senior Living', vals.get('Account.Name'), 'cross-object dot path');
    }

    @IsTest
    static void rejectsInjectionAndNonexistentPaths() {
        Account a = new Account(Name='Acme'); insert a;
        Opportunity o = new Opportunity(Name='Op', StageName='Prospecting',
            CloseDate=Date.today().addDays(10), Amount=99, AccountId=a.Id);
        insert o;

        TurboSignFieldResolver.ResolveRequest req = new TurboSignFieldResolver.ResolveRequest();
        req.recordId = o.Id;
        req.paths = new List<String>{
            'Name',
            'Bogus_Not_A_Field__c',
            '(SELECT Id FROM OpportunityLineItems)',
            'Account.Name'
        };

        Test.startTest();
        // Must not throw despite the injection/nonexistent paths.
        Map<String, Object> vals = TurboSignFieldResolver.resolve(req);
        Test.stopTest();

        System.assertEquals('Op', vals.get('Name'), 'valid field resolves');
        System.assertEquals('Acme', vals.get('Account.Name'), 'valid dot path resolves');
        System.assertEquals(null, vals.get('Bogus_Not_A_Field__c'), 'nonexistent field yields null, not an error');
        System.assertEquals(null, vals.get('(SELECT Id FROM OpportunityLineItems)'), 'injected subquery is rejected');
    }
}
