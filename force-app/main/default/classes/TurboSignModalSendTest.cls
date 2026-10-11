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

    /** Deliverable OK, then a send whose response lists the recipients TurboDocx created. */
    private class SendWithRecipientsMock implements HttpCalloutMock {
        private final String recipientsJson;
        SendWithRecipientsMock(String recipientsJson) { this.recipientsJson = recipientsJson; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            if (req.getEndpoint().endsWith('/v1/deliverable')) {
                res.setBody('{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}');
            } else {
                res.setBody('{"data":{"success":true,"documentId":"doc-1","status":"under_review",'
                    + '"recipients":' + recipientsJson + ',"message":"ok"}}');
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
        System.runAs(TurboSignTestRep.user()) {
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
        System.runAs(TurboSignTestRep.user()) {
            Opportunity o = makeOpp();
            Test.setMock(HttpCalloutMock.class, new TimeoutOnSendMock());

            Test.startTest();
            Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
            Test.stopTest();

            System.assertEquals(false, res.get('ok'));
            System.assertEquals(true, res.get('maybeSent'), 'a timeout on the send call may have sent it');
        }
    }

    // Review: overrides that aren't valid JSON come back as a failed send with a log row, like any other failure,
    // instead of an unhandled exception the modal can only show as a generic error.
    @IsTest
    static void malformedOverridesAreAReturnedFailureWithALogRow() {
        System.runAs(TurboSignTestRep.user()) {
            Opportunity o = makeOpp();
            Test.setMock(HttpCalloutMock.class, new SendMock(200,
                '{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}'));

            Test.startTest();
            Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', '{not json');
            Test.stopTest();

            System.assertEquals(false, res.get('ok'), 'reported as failed');
            System.assertEquals(false, res.get('maybeSent'), 'nothing reached TurboDocx');
            System.assert(String.isNotBlank((String) res.get('message')), 'carries a reason');
            System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Log__c], 'the failure is logged for the admin');
            System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Envelope__c], 'no envelope');
        }
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
        System.runAs(TurboSignTestRep.user()) {
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

    // Friction #16: the counts are roll-ups over the recipient rows, which only the first status sync
    // used to create, so a fresh one-signer send read "0 of 0 signed". The send records the recipients
    // TurboDocx returned, keyed by their TurboDocx id so the later sync updates the same rows.
    @IsTest
    static void sendRecordsTheRecipientsSoTheCountIsRightBeforeTheFirstSync() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '[{"id":"rec-1","name":"Eleanor Whitfield","email":"e@example.com","metadata":{}}]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        TurboSign_Envelope__c e = [SELECT Recipient_Count__c, Signed_Count__c FROM TurboSign_Envelope__c
            WHERE Id = :(Id) res.get('envelopeId')];
        System.assertEquals(1, e.Recipient_Count__c, 'one signer counted at send time');
        System.assertEquals(0, e.Signed_Count__c, 'nobody has signed yet');
        TurboSign_Recipient__c r = [SELECT TurboDocx_Recipient_Id__c, Email__c, Recipient_Name__c FROM TurboSign_Recipient__c];
        System.assertEquals('rec-1', r.TurboDocx_Recipient_Id__c, 'keyed for the later sync upsert');
        System.assertEquals('e@example.com', r.Email__c);
        System.assertEquals('Eleanor Whitfield', r.Recipient_Name__c);
    }

    // Recording the recipients is a convenience: if it fails, the send still succeeded and must not be
    // reported as "may already have been sent", which would push the rep to check for a duplicate.
    @IsTest
    static void aRecipientRowThatCannotBeSavedDoesNotFailTheSend() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '[{"id":"rec-2","name":"Bad Email","email":"not-an-email"}]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Envelope__c], 'the envelope is recorded');
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Recipient__c], 'the bad row is skipped');
        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Log__c], 'and logged for the admin');
    }

    // The document is already emailed by the time the recipients are recorded, so an unexpected entry
    // in the response must be skipped, not thrown as "check before sending again".
    @IsTest
    static void aNonObjectRecipientEntryIsSkippedAndTheSendStillSucceeds() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '["junk",{"id":"rec-3","name":"Good Signer","email":"g@example.com"}]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        TurboSign_Recipient__c r = [SELECT TurboDocx_Recipient_Id__c FROM TurboSign_Recipient__c];
        System.assertEquals('rec-3', r.TurboDocx_Recipient_Id__c, 'the valid recipient is still recorded');
    }

    // One row that won't save must not drop the others: the upsert is partial, and the row error logged.
    @IsTest
    static void oneBadRecipientRowDoesNotDropTheOthers() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '[{"id":"rec-4","name":"Good Signer","email":"g@example.com"},'
            + '{"id":"rec-5","name":"Bad Email","email":"not-an-email"}]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        TurboSign_Recipient__c r = [SELECT TurboDocx_Recipient_Id__c FROM TurboSign_Recipient__c];
        System.assertEquals('rec-4', r.TurboDocx_Recipient_Id__c, 'the good row is saved');
        TurboSign_Log__c log = [SELECT Error_Message__c FROM TurboSign_Log__c];
        System.assert(log.Error_Message__c.contains('rec-5'), 'the failed row is named in the log: ' + log.Error_Message__c);
    }

    // Recipients came back but none had an id, so none could be recorded: say so instead of "0 of 0".
    @IsTest
    static void recipientsThatAllLackAnIdAreLogged() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '[{"id":"","name":"Blank"},{"name":"Missing","email":"m@example.com"}]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Recipient__c], 'no row without an id');
        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Log__c], 'the dropped recipients are logged for the admin');
    }

    @IsTest
    static void noRecipientsInTheResponseIsNotLogged() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock('[]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Log__c], 'nothing was dropped');
    }

    // Some recipients recorded, some dropped: the admin is told how many were dropped and why.
    @IsTest
    static void partlyDroppedRecipientsAreLoggedWithTheReason() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new SendWithRecipientsMock(
            '[{"id":"rec-6","name":"Good Signer","email":"g@example.com"},{"name":"No Id"},42]'));

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.sendForSignature(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assertEquals(true, res.get('ok'), 'still reported as sent: ' + res);
        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Recipient__c], 'the valid recipient is recorded');
        TurboSign_Log__c log = [SELECT Error_Message__c FROM TurboSign_Log__c];
        System.assert(log.Error_Message__c.contains('2 of 3'), 'how many were dropped: ' + log.Error_Message__c);
        System.assert(log.Error_Message__c.contains('1 not a recipient object'), 'non-objects named: ' + log.Error_Message__c);
        System.assert(log.Error_Message__c.contains('1 without an id'), 'missing ids named: ' + log.Error_Message__c);
    }
}
