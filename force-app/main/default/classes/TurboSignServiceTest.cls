@IsTest
private class TurboSignServiceTest {
    @IsTest
    static void createsEnvelopeAttributedToRunningUser() {
        Account a = new Account(Name='Acme Household');
        insert a;
        Opportunity o = new Opportunity(Name='Lease - Howard', StageName='Prospecting',
            CloseDate=Date.today().addDays(30), AccountId=a.Id);
        insert o;

        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        TurboSignService.SendRequest req = new TurboSignService.SendRequest();
        req.recordId = o.Id;
        req.templateId = 'tmpl-1';
        req.documentName = 'Lease - Howard';
        req.variables = new List<Object>();
        req.recipients = new List<Object>{ new Map<String,Object>{'name'=>'Howard','email'=>'h@x.com','signingOrder'=>1} };
        req.fields = new List<Object>();
        req.configDeveloperName = 'Example_Lease';

        Test.startTest();
        Id envId = TurboSignService.createEnvelopeForReview(req);
        Test.stopTest();

        System.assertNotEquals(null, envId, 'envelope created');
        TurboSign_Envelope__c e = [SELECT TurboDocx_Document_Id__c, Preview_Url__c, Status__c,
            Related_Record_Id__c, Related_SObject_Type__c, Related_Opportunity__c, Sent_By__c,
            Document_Name__c, Config_Developer_Name__c FROM TurboSign_Envelope__c WHERE Id=:envId];
        System.assertEquals('doc-999', e.TurboDocx_Document_Id__c, 'documentId stored');
        System.assertEquals('https://td/p/999', e.Preview_Url__c, 'previewUrl stored');
        System.assertEquals('under_review', e.Status__c, 'status stored');
        System.assertEquals(o.Id, e.Related_Record_Id__c, 'generic parent id');
        System.assertEquals('Opportunity', e.Related_SObject_Type__c, 'parent type');
        System.assertEquals(o.Id, e.Related_Opportunity__c, 'opportunity lookup populated');
        System.assertEquals('Example_Lease', e.Config_Developer_Name__c, 'config name');
        // §6.1.1 — MUST be the running user, never the automated process user.
        System.assertEquals(UserInfo.getUserId(), e.Sent_By__c, 'Sent_By is the running rep, not a service account');
    }

    @IsTest
    static void stampsSalesforceIntegrationMetadataOnReview() {
        Opportunity o = new Opportunity(Name = 'IM Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        TurboSignService.SendRequest req = new TurboSignService.SendRequest();
        req.recordId = o.Id;
        req.templateId = '00000000-0000-0000-0000-000000000000';
        req.documentName = 'IM Doc';
        req.variables = new List<Object>();
        req.recipients = new List<Object>();
        req.fields = new List<Object>();

        Test.startTest();
        TurboSignService.createEnvelopeForReview(req);
        Test.stopTest();

        String body = TurboSignRouterMock.lastReviewBody;
        System.assertNotEquals(null, body, 'review request body captured');
        System.assert(body.contains('"integrationName":"salesforce"'),
            'request stamps integrationName=salesforce so the backend completion callback fires: ' + body);
        System.assert(body.contains(String.valueOf(o.Id)),
            'request carries the Salesforce record id as the write-back target: ' + body);
    }
}
