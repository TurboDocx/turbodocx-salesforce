@IsTest
private class TurboSignActionsTest {
    /** Path-routing mock for the TurboSign document endpoints. */
    private static Integer sends = 0;
    private class Mock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            String ep = req.getEndpoint();
            if (ep.contains('/status')) {
                res.setBody('{"data":{"status":"sent","expiresAt":"2026-09-01T00:00:00.000Z"}}');
            } else if (ep.contains('/send-reminder')) {
                res.setBody('{"data":{"results":[{"recipientId":"r1","status":"sent"}]}}');
            } else if (ep.contains('/void')) {
                res.setBody('{"data":{"id":"doc-1","name":"n","status":"voided","voidedAt":"x"}}');
            } else if (ep.endsWith('/v1/deliverable')) {
                res.setBody('{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}');
            } else if (ep.contains('/prepare-for-signing')) {
                // A distinct document per send (doc-1, doc-2, ...): envelope document ids are unique.
                res.setBody('{"data":{"success":true,"documentId":"doc-' + (++sends) + '","status":"sent","message":"ok"}}');
            } else {
                res.setBody('{"data":{}}');
            }
            return res;
        }
    }

    private static TurboSign_Envelope__c makeEnvelope() {
        TurboSign_Envelope__c e = new TurboSign_Envelope__c(
            Document_Name__c = 'T', Status__c = 'sent', TurboDocx_Document_Id__c = 'doc-1');
        insert e;
        return e;
    }

    @IsTest
    static void statusActionReturnsLiveStatus() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c e = makeEnvelope();
            Test.setMock(HttpCalloutMock.class, new Mock());
            TurboSignStatusAction.Input inp = new TurboSignStatusAction.Input();
            inp.envelopeId = e.Id;
            Test.startTest();
            List<TurboSignStatusAction.Output> outs = TurboSignStatusAction.run(new List<TurboSignStatusAction.Input>{ inp });
            Test.stopTest();
            System.assertEquals('sent', outs[0].status, 'status parsed from live call');
        }
    }

    @IsTest
    static void reminderActionSurfacesResults() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c e = makeEnvelope();
            Test.setMock(HttpCalloutMock.class, new Mock());
            TurboSignReminderAction.Input inp = new TurboSignReminderAction.Input();
            inp.envelopeId = e.Id;
            Test.startTest();
            List<TurboSignReminderAction.Output> outs = TurboSignReminderAction.run(new List<TurboSignReminderAction.Input>{ inp });
            Test.stopTest();
            System.assertEquals('ok', outs[0].status, 'reminder ok');
            System.assert(outs[0].message.contains('sent'), 'results surfaced');
        }
    }

    @IsTest
    static void voidActionUpdatesEnvelope() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c e = makeEnvelope();
            Test.setMock(HttpCalloutMock.class, new Mock());
            TurboSignVoidAction.Input inp = new TurboSignVoidAction.Input();
            inp.envelopeId = e.Id; inp.reason = 'Superseded';
            Test.startTest();
            TurboSignVoidAction.run(new List<TurboSignVoidAction.Input>{ inp });
            Test.stopTest();
            TurboSign_Envelope__c after = [SELECT Status__c, Void_Reason__c, Sync_Active__c FROM TurboSign_Envelope__c WHERE Id=:e.Id];
            System.assertEquals('voided', after.Status__c, 'envelope voided');
            System.assertEquals('Superseded', after.Void_Reason__c, 'reason stored');
            System.assertEquals(false, after.Sync_Active__c, 'sync stopped');
        }
    }

    @IsTest
    static void sendClientPathParses() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        TurboSignHttpClient.ReviewResult r = TurboSignHttpClient.sendSignature(new Map<String, Object>{
            'deliverableId' => 'd1',
            'recipients' => new List<Object>{ new Map<String, Object>{ 'name'=>'A','email'=>'a@x.com','signingOrder'=>1 } },
            'fields' => new List<Object>()
        });
        Test.stopTest();
        System.assertEquals('doc-1', r.documentId, 'send parsed documentId');
        System.assertEquals('sent', r.status, 'send status');
    }

    @IsTest
    static void sendActionBulkEnqueuesOneJobNotOnePerRecord() {
        Account a = new Account(Name = 'Bulk'); insert a;
        List<TurboSignSendAction.Input> inputs = new List<TurboSignSendAction.Input>();
        for (Integer i = 0; i < 55; i++) { // > 50: one-enqueue-per-input would blow the queueable-jobs limit
            TurboSignSendAction.Input inp = new TurboSignSendAction.Input();
            inp.recordId = a.Id;
            inp.configDeveloperName = 'Example_Agreement';
            inputs.add(inp);
        }
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        TurboSignSendAction.run(inputs);
        System.assertEquals(1, Limits.getQueueableJobs(), 'a bulk invocation enqueues exactly one job, not one per record');
        Test.stopTest();
    }

    @IsTest
    static void getEnvelopesReturnsEnvelopesForAccessibleParent() {
        System.runAs(TurboSignTestRep.user()) {
            Account a = new Account(Name = 'Parent'); insert a;
            insert new TurboSign_Envelope__c(Document_Name__c = 'D', Status__c = 'sent',
                TurboDocx_Document_Id__c = 'doc-1', Related_Record_Id__c = a.Id);
            Test.startTest();
            List<TurboSign_Envelope__c> got = TurboSignQuickActionController.getEnvelopes(a.Id);
            Test.stopTest();
            System.assertEquals(1, got.size(), 'running user can read the parent record, so its envelopes are returned');
        }
    }

    // Review: one transaction can't call out after DML, so the bulk job sends ONE record and chains the
    // rest; it used to loop and fail every record after the first with "uncommitted work pending".
    @IsTest
    static void bulkJobSendsOneRecordThenChainsTheRest() {
        List<Id> ids = new List<Id>();
        Account a = new Account(Name = 'Bulk Co');
        insert a;
        for (Integer i = 0; i < 2; i++) {
            Opportunity o = new Opportunity(Name = 'Bulk ' + i, StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = a.Id);
            insert o;
            ids.add(o.Id);
        }
        Test.setMock(HttpCalloutMock.class, new Mock());

        Test.startTest();
        new TurboSignSendQueueable(ids, new List<String>{ 'Example_Agreement', 'Example_Agreement' }, UserInfo.getUserId()).execute(null);
        Integer sentInFirstJob = [SELECT COUNT() FROM TurboSign_Envelope__c];
        Integer chained = Limits.getQueueableJobs();
        Test.stopTest(); // runs the chained job for the second record

        List<TurboSign_Log__c> logs = [SELECT Error_Message__c FROM TurboSign_Log__c];
        System.assertEquals(1, sentInFirstJob, 'one record per job; logs: ' + logs);
        System.assertEquals(1, chained, 'the remaining record is chained to a new job');
        System.assertEquals(2, [SELECT COUNT() FROM TurboSign_Envelope__c], 'the chain sends every record; logs: ' + logs);
        System.assertEquals(0, logs.size(), 'no "uncommitted work" failure logged');
    }

    // Review: remind/void must not act on an envelope whose record the user can't access.
    @IsTest
    static void remindAndVoidRequireAccessToTheRecord() {
        System.runAs(TurboSignTestRep.user()) {
            Opportunity gone = new Opportunity(Name = 'Gone', StageName = 'Prospecting', CloseDate = Date.today());
            insert gone;
            Id goneId = gone.Id;
            delete gone;
            TurboSign_Envelope__c e = new TurboSign_Envelope__c(Document_Name__c = 'T', Status__c = 'sent',
                TurboDocx_Document_Id__c = 'doc-1', Related_Record_Id__c = goneId);
            insert e;
            Test.setMock(HttpCalloutMock.class, new Mock());

            Integer blocked = 0;
            try { TurboSignQuickActionController.voidEnvelope(e.Id, 'x'); } catch (AuraHandledException ex) { blocked++; }
            try { TurboSignQuickActionController.remind(e.Id); } catch (AuraHandledException ex) { blocked++; }
            System.assertEquals(2, blocked, 'both actions refuse without access to the related record');
            System.assertEquals('sent', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :e.Id].Status__c, 'not voided');
        }
    }
}
