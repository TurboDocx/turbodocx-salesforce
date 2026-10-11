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
        Map<String, Object> im = metadataOf(body);
        assertStampsOrgId(im, body);
    }

    @IsTest
    static void stampsSalesforceOrgIdOnDirectSend() {
        Opportunity o = new Opportunity(Name = 'Send Deal', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        insert o;
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        TurboSignService.SendRequest req = baseRequest();
        req.recordId = o.Id;

        Test.startTest();
        Id envId = TurboSignService.sendForSignature(req);
        Test.stopTest();

        System.assertNotEquals(null, envId, 'envelope created');
        String body = TurboSignRouterMock.lastSignBody;
        System.assertNotEquals(null, body, 'prepare-for-signing request body captured');
        Map<String, Object> im = metadataOf(body);
        System.assertEquals('salesforce', im.get('integrationName'), 'direct send stamps integrationName: ' + body);
        System.assertEquals(String.valueOf(o.Id), im.get('salesforceRecordId'), 'direct send carries the record id: ' + body);
        assertStampsOrgId(im, body);
    }

    @IsTest
    static void reviewWithoutRecordOmitsRecordAndCompletionFields() {
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        TurboSignService.SendRequest req = baseRequest();
        req.recordId = null;
        req.completionField = 'StageName';
        req.completionValue = 'Closed Won';

        Test.startTest();
        Id envId = TurboSignService.createEnvelopeForReview(req);
        Test.stopTest();

        String body = TurboSignRouterMock.lastReviewBody;
        System.assertNotEquals(null, body, 'review request still sent without a record');
        assertNoRecordTarget(metadataOf(body), body);
        TurboSign_Envelope__c e = [SELECT Related_Record_Id__c, Related_SObject_Type__c, Related_Opportunity__c
            FROM TurboSign_Envelope__c WHERE Id = :envId];
        System.assertEquals(null, e.Related_Record_Id__c, 'no related record');
        System.assertEquals(null, e.Related_SObject_Type__c, 'no related type');
        System.assertEquals(null, e.Related_Opportunity__c, 'no opportunity lookup');
    }

    @IsTest
    static void directSendWithoutRecordRecordsEnvelopeWithoutNpe() {
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        TurboSignService.SendRequest req = baseRequest();
        req.recordId = null;

        Test.startTest();
        Id envId = TurboSignService.sendForSignature(req);
        Test.stopTest();

        System.assertNotEquals(null, envId, 'envelope recorded after the send even without a record');
        System.assertEquals('record', TurboSignService.stage, 'send reached the record stage');
        String body = TurboSignRouterMock.lastSignBody;
        System.assertNotEquals(null, body, 'prepare-for-signing request body captured');
        assertNoRecordTarget(metadataOf(body), body);
        TurboSign_Envelope__c e = [SELECT Status__c, Related_Record_Id__c, Related_SObject_Type__c
            FROM TurboSign_Envelope__c WHERE Id = :envId];
        System.assertEquals('sent', e.Status__c, 'status sent');
        System.assertEquals(null, e.Related_Record_Id__c, 'no related record');
        System.assertEquals(null, e.Related_SObject_Type__c, 'no related type');
    }

    private static TurboSignService.SendRequest baseRequest() {
        TurboSignService.SendRequest req = new TurboSignService.SendRequest();
        req.templateId = '00000000-0000-0000-0000-000000000000';
        req.documentName = 'IM Doc';
        req.variables = new List<Object>();
        req.recipients = new List<Object>();
        req.fields = new List<Object>();
        req.senderEmail = 'rep@example.com';
        req.senderName = 'Rep';
        return req;
    }

    private static Map<String, Object> metadataOf(String body) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        return (Map<String, Object>) parsed.get('integrationMetadata');
    }

    private static void assertStampsOrgId(Map<String, Object> im, String body) {
        String orgId = (String) im.get('salesforceOrgId');
        System.assertNotEquals(null, orgId, 'request carries salesforceOrgId: ' + body);
        System.assertEquals(18, orgId.length(), 'salesforceOrgId is the 18-char org id: ' + body);
        System.assert(orgId.startsWith('00D'), 'salesforceOrgId is an Organization id (00D prefix): ' + body);
        System.assertEquals(UserInfo.getOrganizationId(), orgId, 'salesforceOrgId is this org: ' + body);
    }

    private static void assertNoRecordTarget(Map<String, Object> im, String body) {
        System.assertEquals('salesforce', im.get('integrationName'), 'integrationName still stamped: ' + body);
        assertStampsOrgId(im, body);
        for (String k : new List<String>{ 'salesforceRecordId', 'salesforceObjectType',
                'salesforceCompletionField', 'salesforceCompletionValue' }) {
            System.assert(!im.containsKey(k), k + ' omitted when there is no record: ' + body);
        }
        for (Object v : im.values()) {
            System.assertNotEquals('null', v, 'no literal null string stamped: ' + body);
        }
    }
}
