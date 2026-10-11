@IsTest
private class TurboSignActionsTest {
    /** Path-routing mock for the TurboSign document endpoints. */
    private static Integer sends = 0;
    /** Void callouts the mock received, so a test can prove a refused void never reached TurboDocx. */
    private static Integer voids = 0;
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
                voids++;
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
            // The panel skips its load-time sync for an envelope synced in the last few minutes.
            System.assertEquals(null, got[0].Last_Synced__c, 'Last_Synced__c is returned (never synced yet)');
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

    // A rep can read a record but not edit it, so remind/void on an envelope that belongs to one is
    // refused, while the same rep can act on an envelope for a record the rep owns. The read-only record
    // is a Product: Standard User reads products but cannot edit them, whatever the org's sharing
    // defaults (an Account would be editable in an org where Account access is Public Read/Write).
    @IsTest
    static void remindAndVoidFollowTheRepsEditAccess() {
        Product2 product = new Product2(Name = 'Admin owned', IsActive = true);
        insert product;
        User rep = TurboSignTestRep.user();
        UserRecordAccess access = [SELECT RecordId, HasReadAccess, HasEditAccess FROM UserRecordAccess
            WHERE UserId = :rep.Id AND RecordId = :product.Id];
        System.assertEquals(true, access.HasReadAccess, 'the rep can read the record');
        System.assertEquals(false, access.HasEditAccess, 'the rep cannot edit the record');
        System.runAs(rep) {
            Account mine = new Account(Name = 'Rep owned');
            insert mine;
            TurboSign_Envelope__c readOnly = new TurboSign_Envelope__c(Document_Name__c = 'T', Status__c = 'sent',
                TurboDocx_Document_Id__c = 'doc-ro', Related_Record_Id__c = product.Id);
            TurboSign_Envelope__c editable = new TurboSign_Envelope__c(Document_Name__c = 'T', Status__c = 'sent',
                TurboDocx_Document_Id__c = 'doc-ed', Related_Record_Id__c = mine.Id);
            insert new List<TurboSign_Envelope__c>{ readOnly, editable };
            Test.setMock(HttpCalloutMock.class, new Mock());

            Test.startTest();
            Integer blocked = 0;
            try { TurboSignQuickActionController.voidEnvelope(readOnly.Id, 'x'); } catch (AuraHandledException ex) { blocked++; }
            try { TurboSignQuickActionController.remind(readOnly.Id); } catch (AuraHandledException ex) { blocked++; }
            TurboSignQuickActionController.voidEnvelope(editable.Id, 'Superseded');
            Test.stopTest();

            System.assertEquals(2, blocked, 'read-only access to the related record is not enough');
            System.assertEquals('sent', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :readOnly.Id].Status__c);
            System.assertEquals('voided', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :editable.Id].Status__c,
                'the rep can void an envelope for a record the rep can edit');
        }
    }

    // The panel's void and the Flow action write as the rep. A rep who cannot edit Void Reason is refused
    // before TurboDocx is called, so the document is never voided there while 'sent' here.
    @IsTest
    static void voidFromThePanelRespectsFieldLevelSecurity() {
        User rep = TurboSignTestRep.user();
        revokeVoidReasonEdit();
        System.runAs(rep) {
            TurboSign_Envelope__c e = makeEnvelope();
            Test.setMock(HttpCalloutMock.class, new Mock());

            Test.startTest();
            Boolean blocked = false;
            try { TurboSignQuickActionController.voidEnvelope(e.Id, 'Superseded'); } catch (AuraHandledException ex) { blocked = true; }
            Test.stopTest();

            System.assert(blocked, 'a rep without edit on Void Reason cannot void from the panel');
        }
        System.assertEquals(0, voids, 'TurboDocx is not asked to void');
        TurboSign_Envelope__c after = [SELECT Status__c, Void_Reason__c FROM TurboSign_Envelope__c LIMIT 1];
        System.assertEquals('sent', after.Status__c, 'not voided locally');
        System.assertEquals(null, after.Void_Reason__c, 'Void Reason not written in system mode');
    }

    @IsTest
    static void voidActionRespectsFieldLevelSecurity() {
        User rep = TurboSignTestRep.user();
        revokeVoidReasonEdit();
        System.runAs(rep) {
            TurboSign_Envelope__c e = makeEnvelope();
            Test.setMock(HttpCalloutMock.class, new Mock());

            Test.startTest();
            Boolean blocked = false;
            try { runVoidAction(e.Id); } catch (AuraHandledException ex) { blocked = true; }
            Test.stopTest();

            System.assert(blocked, 'a rep without edit on Void Reason cannot void from a Flow');
        }
        System.assertEquals(0, voids, 'TurboDocx is not asked to void');
        System.assertEquals('sent', [SELECT Status__c FROM TurboSign_Envelope__c LIMIT 1].Status__c, 'not voided locally');
    }

    // Edit on the related record is not enough: the void writes the envelope, so a rep who cannot edit the
    // envelope (here, no Edit on the object; in an org with Private envelopes, someone else's) is refused
    // before TurboDocx is called, from the panel and from a Flow.
    @IsTest
    static void voidRequiresEditOnTheEnvelopeFromThePanel() {
        User rep = TurboSignTestRep.user();
        TurboSign_Envelope__c e = envelopeTheRepCannotEdit(rep);
        System.runAs(rep) {
            Test.setMock(HttpCalloutMock.class, new Mock());
            Test.startTest();
            String refused;
            try { TurboSignQuickActionController.voidEnvelope(e.Id, 'Superseded'); } catch (AuraHandledException ex) { refused = ex.getMessage(); }
            Test.stopTest();
            System.assertEquals(TurboSignActionUtil.NO_ENVELOPE_EDIT, refused, 'refused for the envelope itself');
        }
        System.assertEquals(0, voids, 'TurboDocx is not asked to void');
        System.assertEquals('sent', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :e.Id].Status__c);
    }

    @IsTest
    static void voidRequiresEditOnTheEnvelopeFromAFlow() {
        User rep = TurboSignTestRep.user();
        TurboSign_Envelope__c e = envelopeTheRepCannotEdit(rep);
        System.runAs(rep) {
            Test.setMock(HttpCalloutMock.class, new Mock());
            Test.startTest();
            String refused;
            try { runVoidAction(e.Id); } catch (AuraHandledException ex) { refused = ex.getMessage(); }
            Test.stopTest();
            System.assertEquals(TurboSignActionUtil.NO_ENVELOPE_EDIT, refused, 'refused for the envelope itself');
        }
        System.assertEquals(0, voids, 'TurboDocx is not asked to void');
        System.assertEquals('sent', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :e.Id].Status__c);
    }

    private static void runVoidAction(Id envelopeId) {
        TurboSignVoidAction.Input inp = new TurboSignVoidAction.Input();
        inp.envelopeId = envelopeId; inp.reason = 'Superseded';
        TurboSignVoidAction.run(new List<TurboSignVoidAction.Input>{ inp });
    }

    private static void revokeVoidReasonEdit() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            FieldPermissions fp = [SELECT Id FROM FieldPermissions WHERE Parent.Name = 'TurboSign_User'
                AND Field = 'TurboSign_Envelope__c.Void_Reason__c'];
            fp.PermissionsEdit = false;
            update fp;
        }
    }

    /**
     * A 'sent' envelope for an Account the rep owns (so the related-record check passes), with Edit on
     * envelopes taken away from TurboSign User. The test asserts the rep can edit the Account and not
     * the envelope through UserRecordAccess first.
     */
    private static TurboSign_Envelope__c envelopeTheRepCannotEdit(User rep) {
        Account mine;
        TurboSign_Envelope__c e;
        System.runAs(rep) {
            mine = new Account(Name = 'Rep owned');
            insert mine;
            e = new TurboSign_Envelope__c(Document_Name__c = 'T', Status__c = 'sent',
                TurboDocx_Document_Id__c = 'doc-1', Related_Record_Id__c = mine.Id);
            insert e;
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ObjectPermissions op = [SELECT Id FROM ObjectPermissions WHERE Parent.Name = 'TurboSign_User'
                AND SobjectType = 'TurboSign_Envelope__c'];
            op.PermissionsEdit = false;
            op.PermissionsDelete = false; // Delete depends on Edit
            update op;
        }
        Map<Id, Boolean> canEdit = new Map<Id, Boolean>();
        for (UserRecordAccess a : [SELECT RecordId, HasEditAccess FROM UserRecordAccess
                                   WHERE UserId = :rep.Id AND RecordId IN :new List<Id>{ mine.Id, e.Id }]) {
            canEdit.put(a.RecordId, a.HasEditAccess);
        }
        System.assertEquals(true, canEdit.get(mine.Id), 'the rep can edit the related record');
        System.assertEquals(false, canEdit.get(e.Id), 'the rep cannot edit the envelope');
        return e;
    }
}
