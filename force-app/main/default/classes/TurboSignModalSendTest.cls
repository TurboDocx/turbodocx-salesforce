/**
 * The rep's Send button must report what actually happened. A send that fails at TurboDocx must
 * reach the rep as an error, never as a "Sent" toast followed by a silent log row.
 */
@IsTest
private class TurboSignModalSendTest {
    private class SendMock implements HttpCalloutMock {
        private final Integer deliverableStatus;
        private final String deliverableBody;
        SendMock(Integer deliverableStatus, String deliverableBody) {
            this.deliverableStatus = deliverableStatus; this.deliverableBody = deliverableBody;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().endsWith('/v1/deliverable')) {
                res.setStatusCode(deliverableStatus);
                res.setBody(deliverableBody);
            } else {
                res.setStatusCode(200);
                res.setBody('{"data":{"success":true,"documentId":"doc-1","status":"sent","message":"ok"}}');
            }
            return res;
        }
    }

    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Acme QA');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'QA Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = a.Id);
        insert o;
        return o;
    }

    @IsTest
    static void sendCallsOutNowAndReturnsTheEnvelope() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendMock(200,
            '{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Id envelopeId = (Id) res.get('envelopeId');
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        TurboSign_Envelope__c e = [SELECT Status__c, TurboDocx_Document_Id__c FROM TurboSign_Envelope__c WHERE Id = :envelopeId];
        System.assertEquals('sent', e.Status__c, 'the envelope exists by the time the rep sees success');
        System.assertEquals('doc-1', e.TurboDocx_Document_Id__c, 'linked to the TurboDocx document');
        System.assertEquals(0, jobs, 'the rep-initiated send does not defer to a background job');
        System.assertEquals(true, res.get('ok'), 'reported as sent');
    }

    @IsTest
    static void failedSendThrowsTheBackendReasonAndCreatesNothing() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendMock(400,
            '{"message":"There was an issue validating the body","type":"ValidationError","data":{"errors":'
            + '[{"message":"\\"variables[8].text\\" is not allowed to be empty","path":["variables",8,"text"]}]}}'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        String msg = (String) res.get('message');
        System.assertEquals(false, res.get('ok'), 'a failed send is reported as failed');
        System.assert(msg.contains('variables[8].text'), 'names the failing field, got: ' + msg);
        System.assertEquals(false, res.get('maybeSent'), 'a validation 400 means nothing was sent');
        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Log__c], 'the failure is logged for the admin');
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Envelope__c], 'no envelope for a failed send');
    }

    private class TimeoutOnSendMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            if (req.getEndpoint().contains('prepare-for-signing')) throw new CalloutException('Read timed out');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}');
            return res;
        }
    }

    // Review: if the send call itself times out, TurboDocx may already have emailed the signers, so the
    // rep is warned instead of being invited to send a duplicate.
    @IsTest
    static void timeoutDuringSendIsFlaggedAsMaybeSent() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new TimeoutOnSendMock());

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(false, res.get('ok'));
        System.assertEquals(true, res.get('maybeSent'), 'a timeout on the send call may have sent it');
    }

    // Review: the rep modal lists configs through the rep controller, not the admin one.
    @IsTest
    static void repControllerListsConfigs() {
        List<Map<String, Object>> cfgs = TurboSignQuickActionController.listConfigs('Opportunity');
        System.assertNotEquals(null, cfgs, 'config list available to reps');
    }


    @IsTest
    static void sendAppliesTheRepsEditsFromTheModal() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendMock(200,
            '{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}'));
        String overrides = JSON.serialize(new Map<String, Object>{
            'variables' => new Map<String, Object>{ '{ClientName}' => 'Edited Inc' },
            'recipients' => new List<Object>{ new Map<String, Object>{ 'role' => '', 'name' => 'x' } } });

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', overrides);
        Test.stopTest();

        System.assertNotEquals(null, res.get('envelopeId'), 'send with rep edits still creates the envelope');
    }

    @IsTest
    static void previewAndAnchorCheckBackTheReviewStep() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());

        Test.startTest();
        Map<String, Object> pv = TurboSignQuickActionController.previewForSignature(o.Id, 'Example_Agreement');
        List<Object> anchors = TurboSignQuickActionController.checkAnchors(o.Id, 'Example_Agreement');
        Test.stopTest();

        System.assertNotEquals(null, pv.get('variables'), 'preview resolves variables for the review step');
        System.assert(!anchors.isEmpty(), 'anchor check reports the configured signature spots');
    }

    @IsTest
    static void remindAndVoidCallTheDocumentOnTheEnvelope() {
        TurboSign_Envelope__c e = new TurboSign_Envelope__c(
            Document_Name__c = 'T', Status__c = 'sent', TurboDocx_Document_Id__c = 'doc-1');
        insert e;
        Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
            '{"data":{"results":[{"recipientId":"r1","status":"sent"}],"id":"doc-1","status":"voided"}}'));

        Test.startTest();
        String reminded = TurboSignQuickActionController.remind(e.Id);
        TurboSignQuickActionController.voidEnvelope(e.Id, 'Superseded');
        Test.stopTest();

        System.assert(reminded.contains('r1'), 'reminder results returned to the panel');
        System.assertEquals('voided', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :e.Id].Status__c, 'voided locally');
    }
}
