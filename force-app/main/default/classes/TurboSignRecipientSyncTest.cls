@IsTest
private class TurboSignRecipientSyncTest {

    private static TurboSign_Envelope__c newEnvelope(String docId) {
        TurboSign_Envelope__c e = new TurboSign_Envelope__c(TurboDocx_Document_Id__c = docId);
        insert e;
        return e;
    }

    @IsTest
    static void toRecordsMapsEveryBackendField() {
        TurboSign_Envelope__c env = newEnvelope('doc-1');
        List<Object> recips = (List<Object>) JSON.deserializeUntyped(
            '[{"id":"r1","name":"Pat Example","email":"a@x.com","status":"completed",' +
            '"effectiveStatus":"completed","signingOrder":1,"signedOn":"2026-08-27T14:56:15.000Z",' +
            '"delivery":{"firstSentOn":"2026-08-27T14:50:00.000Z","lastSentOn":"2026-08-27T14:50:00.000Z",' +
            '"totalSent":1,"reminderCount":0,"warningCount":0}}]');

        List<TurboSign_Recipient__c> out = TurboSignRecipientSync.toRecords(env.Id, recips);

        System.assertEquals(1, out.size(), 'one record per backend recipient');
        TurboSign_Recipient__c r = out[0];
        System.assertEquals('r1', r.TurboDocx_Recipient_Id__c, 'external id from backend recipient id');
        System.assertEquals(env.Id, r.Envelope__c, 'parented to the envelope');
        System.assertEquals('Pat Example', r.Recipient_Name__c);
        System.assertEquals('a@x.com', r.Email__c);
        System.assertEquals('completed', r.Status__c);
        System.assertEquals('completed', r.Effective_Status__c);
        System.assertEquals(1, r.Signing_Order__c);
        System.assertEquals(1, r.Total_Sent__c);
        System.assertNotEquals(null, r.Signed_On__c, 'ISO signedOn parsed to Datetime');
        System.assertNotEquals(null, r.First_Sent_On__c, 'delivery.firstSentOn parsed');
    }

    @IsTest
    static void toRecordsToleratesMissingDeliveryAndSignedOn() {
        TurboSign_Envelope__c env = newEnvelope('doc-2');
        List<Object> recips = (List<Object>) JSON.deserializeUntyped(
            '[{"id":"r9","name":"Pending Person","email":"p@x.com","status":"pending",' +
            '"effectiveStatus":"pending","signingOrder":3}]');

        List<TurboSign_Recipient__c> out = TurboSignRecipientSync.toRecords(env.Id, recips);

        System.assertEquals(1, out.size());
        System.assertEquals(null, out[0].Signed_On__c, 'no signedOn -> null, not an error');
        System.assertEquals(null, out[0].First_Sent_On__c, 'no delivery block -> null');
        System.assertEquals(3, out[0].Signing_Order__c);
    }

    @IsTest
    static void syncEnvelopeUpsertsRecipientsAndRollsEnvelopeCounts() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-9');
            String body =
                '{"data":{"recipients":[' +
                '{"id":"r1","name":"A","email":"a@x.com","status":"completed","effectiveStatus":"completed",' +
                '"signingOrder":1,"signedOn":"2026-08-27T14:56:15.000Z","delivery":{"firstSentOn":"2026-08-27T14:50:00.000Z","totalSent":1}},' +
                '{"id":"r2","name":"B","email":"b@x.com","status":"pending","effectiveStatus":"pending",' +
                '"signingOrder":2,"delivery":{"totalSent":0}}],' +
                '"summary":{"total":2,"completed":1}}}';
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200, body));

            Test.startTest();
            Integer n = TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals(2, n, 'returns the number of recipients synced');
            List<TurboSign_Recipient__c> recs = [
                SELECT TurboDocx_Recipient_Id__c, Status__c, Signing_Order__c
                FROM TurboSign_Recipient__c WHERE Envelope__c = :env.Id ORDER BY Signing_Order__c];
            System.assertEquals(2, recs.size(), 'both recipients written as child records');
            System.assertEquals('completed', recs[0].Status__c);
            System.assertEquals('pending', recs[1].Status__c);

            TurboSign_Envelope__c e2 = [
                SELECT Recipient_Count__c, Signed_Count__c, Last_Synced__c
                FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals(2, e2.Recipient_Count__c, 'total rolled onto the envelope');
            System.assertEquals(1, e2.Signed_Count__c, 'completed count rolled onto the envelope');
            System.assertNotEquals(null, e2.Last_Synced__c, 'sync stamps Last_Synced__c');
        }
    }

    @IsTest
    static void syncIsIdempotentByExternalId() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-idem');
            String body =
                '{"data":{"recipients":[' +
                '{"id":"r1","name":"A","email":"a@x.com","status":"completed","effectiveStatus":"completed","signingOrder":1}],' +
                '"summary":{"total":1,"completed":1}}}';
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200, body));

            List<Object> sameRecips = (List<Object>) JSON.deserializeUntyped(
                '[{"id":"r1","name":"A","email":"a@x.com","status":"completed","effectiveStatus":"completed","signingOrder":1}]');

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true); // real sync: callout + upsert
            // A later sync upserts the same external id again (no second callout in one txn, per Apex rules).
            upsert TurboSignRecipientSync.toRecords(env.Id, sameRecips) TurboSign_Recipient__c.TurboDocx_Recipient_Id__c;
            Test.stopTest();

            System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Recipient__c WHERE Envelope__c = :env.Id],
                'upsert by external id -> no duplicate child records on re-sync');
        }
    }

    // A rep presses Refresh twice. The second sync writes Envelope__c (a master-detail that can't be
    // reparented) on rows that already exist, alongside a new row; `upsert as user` accepts the unchanged value.
    @IsTest
    static void aSecondSyncAsTheRepUpdatesTheRecipients() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-resync');
            String recipient = '{"data":{"recipients":[{"id":"r-resync","name":"A","email":"a@x.com",'
                + '"status":"STATUS","effectiveStatus":"STATUS","signingOrder":1}]}}';
            // The first Refresh's rows, written as the rep exactly as syncEnvelope writes them. (Apex allows
            // no callout after DML in one transaction, so the test can't call out for both syncs.)
            Map<String, Object> first = (Map<String, Object>) ((Map<String, Object>)
                JSON.deserializeUntyped(recipient.replace('STATUS', 'pending'))).get('data');
            insert as user TurboSignRecipientSync.toRecords(env.Id, (List<Object>) first.get('recipients'));

            // The second Refresh returns the same recipient, now completed, and one added since.
            String second = recipient.replace('STATUS', 'completed').replace('}]}}',
                '},{"id":"r-added","name":"B","email":"b@x.com","status":"pending","effectiveStatus":"pending","signingOrder":2}]}}');
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200, second));
            Test.startTest();
            Integer n = TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals(2, n, 'the second sync succeeds');
            List<TurboSign_Recipient__c> recs = [SELECT TurboDocx_Recipient_Id__c, Status__c FROM TurboSign_Recipient__c
                WHERE Envelope__c = :env.Id ORDER BY Signing_Order__c];
            System.assertEquals(2, recs.size(), 'the existing recipient is updated, not duplicated, and the new one added');
            System.assertEquals('completed', recs[0].Status__c, 'the second sync updates the status');
            System.assertEquals('r-added', recs[1].TurboDocx_Recipient_Id__c, 'the new recipient is inserted');
        }
    }

    // Review: the sync already receives document.status; write terminal states onto the envelope.
    @IsTest
    static void syncMarksACompletedDocumentCompleted() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-done');
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"completed"},"recipients":[{"id":"r9","name":"A","email":"a@x.com",'
                + '"status":"completed","effectiveStatus":"completed","signingOrder":1}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Completed_On__c, Sync_Active__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('completed', e.Status__c, 'status follows the document');
            System.assertNotEquals(null, e.Completed_On__c, 'completion time stamped');
            System.assertEquals(false, e.Sync_Active__c, 'terminal status stops syncing');
        }
    }

    // Second review: a sync must never move a finished envelope back to "out for signature".
    @IsTest
    static void syncNeverMovesATerminalStatus() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-void');
            env.Status__c = 'voided';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"under_review"},"recipients":[]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals('voided', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :env.Id].Status__c,
                'a voided envelope stays voided');
        }
    }

    /** Voids the envelope while the callout is in flight, as a rep's Void would. */
    private class VoidDuringCalloutMock implements HttpCalloutMock {
        Id envelopeId;
        VoidDuringCalloutMock(Id envelopeId) { this.envelopeId = envelopeId; }
        public HttpResponse respond(HttpRequest req) {
            update new TurboSign_Envelope__c(Id = envelopeId, Status__c = 'voided');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"data":{"document":{"status":"under_review"},"recipients":[]}}');
            return res;
        }
    }

    @IsTest
    static void syncDoesNotOverwriteAVoidThatLandsDuringTheCallout() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-race');
            env.Status__c = 'sent';
            update env;
            Test.setMock(HttpCalloutMock.class, new VoidDuringCalloutMock(env.Id));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals('voided', [SELECT Status__c FROM TurboSign_Envelope__c WHERE Id = :env.Id].Status__c,
                'the status is re-read after the callout, so the void wins');
        }
    }

    @IsTest
    static void syncSkipsTheCalloutWhenSyncedInTheLastFiveMinutes() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-recent');
            Datetime recent = System.now().addMinutes(-1);
            env.Last_Synced__c = recent;
            update env;
            // No callout mock: a callout here would throw.

            Test.startTest();
            Integer n = TurboSignRecipientSync.syncEnvelope(env.Id, false);
            Test.stopTest();

            System.assertEquals(0, n, 'nothing synced');
            System.assertEquals(recent, [SELECT Last_Synced__c FROM TurboSign_Envelope__c WHERE Id = :env.Id].Last_Synced__c,
                'a throttled sync leaves Last_Synced__c alone');
        }
    }

    @IsTest
    static void forcedSyncCallsOutEvenWhenSyncedRecently() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-force');
            env.Last_Synced__c = System.now().addMinutes(-1);
            update env;
            TurboSignHttpMock mock = new TurboSignHttpMock(200, '{"data":{"recipients":[]}}');
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertNotEquals(null, mock.lastEndpoint, 'Refresh forces the callout');
        }
    }

    @IsTest
    static void unforcedSyncCallsOutWhenTheLastSyncIsStale() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-stale');
            env.Last_Synced__c = System.now().addMinutes(-10);
            update env;
            TurboSignHttpMock mock = new TurboSignHttpMock(200, '{"data":{"recipients":[]}}');
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, null);
            Test.stopTest();

            System.assertNotEquals(null, mock.lastEndpoint, 'a stale envelope syncs; a null force means not forced');
        }
    }

    // The document's own sent time (its DOCUMENT_SENT audit) is the source of Sent_On__c. Embedded
    // signing emails nobody, so no recipient has a firstSentOn, yet the document was sent.
    @IsTest
    static void syncStampsSentOnFromTheDocumentSentTimeWithNoRecipientDelivery() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-embedded-sent');
            env.Status__c = 'review_ready';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"sent","sentOn":"2026-10-03T12:00:00.000Z"},"recipients":['
                + '{"id":"r1","status":"pending","delivery":{"totalSent":0}}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('sent', e.Status__c);
            System.assertEquals(Datetime.newInstanceGmt(2026, 10, 3, 12, 0, 0), e.Sent_On__c,
                'sent when the document was sent, even though no recipient was emailed');
        }
    }

    @IsTest
    static void syncPrefersTheDocumentSentTimeOverRecipientDelivery() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-sent-both');
            env.Status__c = 'review_ready';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"sent","sentOn":"2026-10-03T12:00:00.000Z"},"recipients":['
                + '{"id":"r1","delivery":{"firstSentOn":"2026-10-04T09:00:00.000Z"}}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals(Datetime.newInstanceGmt(2026, 10, 3, 12, 0, 0), e.Sent_On__c,
                'the document sent time wins over a later recipient delivery');
        }
    }

    // Without a document sent time (an older backend), the recipients' first delivery time is the
    // fallback that says a review link went out, so the panel offers Remind and Void.
    @IsTest
    static void syncStampsSentOnFromTheFirstRecipientDelivery() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-review-sent');
            env.Status__c = 'review_ready';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"under_review"},"recipients":['
                + '{"id":"r1","delivery":{"firstSentOn":"2026-10-02T09:30:00.000Z"}},'
                + '{"id":"r2","delivery":{"firstSentOn":"2026-10-01T08:15:00.000Z"}},'
                + '{"id":"r3","delivery":{}}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('under_review', e.Status__c);
            System.assertEquals(Datetime.newInstanceGmt(2026, 10, 1, 8, 15, 0), e.Sent_On__c,
                'sent when the first recipient was first sent the document');
        }
    }

    // An unsent review link can also read under_review; with no recipient delivered, it is still unsent.
    @IsTest
    static void syncLeavesAnUnsentUnderReviewLinkUnsent() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-review-unsent');
            env.Status__c = 'under_review';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"under_review"},"recipients":['
                + '{"id":"r1","status":"pending","delivery":{"totalSent":0}},{"id":"r2","status":"pending"}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('under_review', e.Status__c);
            System.assertEquals(null, e.Sent_On__c, 'no recipient was sent the document, so it is not sent');
        }
    }

    @IsTest
    static void syncDoesNotStampSentOnForATerminalDocumentNeverSent() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-review-expired');
            env.Status__c = 'review_ready';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"expired"},"recipients":[{"id":"r1","status":"pending"}]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('expired', e.Status__c);
            System.assertEquals(null, e.Sent_On__c, 'finishing is not sending: no first-sent time, no Sent_On__c');
        }
    }

    @IsTest
    static void syncLeavesAReviewOnlyEnvelopeUnsent() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-review-only');
            env.Status__c = 'review_ready';
            update env;
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"review_ready"},"recipients":[]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            TurboSign_Envelope__c e = [SELECT Status__c, Sent_On__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
            System.assertEquals('review_ready', e.Status__c);
            System.assertEquals(null, e.Sent_On__c, 'still only prepared for review');
        }
    }

    // A recipient without an id would upsert a null external id: a fresh row on every sync.
    @IsTest
    static void toRecordsSkipsRecipientsWithoutAnId() {
        TurboSign_Envelope__c env = newEnvelope('doc-noid');
        List<Object> recips = (List<Object>) JSON.deserializeUntyped(
            '[{"id":"","name":"Blank"},{"name":"Missing"},{"id":"  ","name":"Spaces"},{"id":"r1","name":"Kept"}]');

        List<TurboSign_Recipient__c> out = TurboSignRecipientSync.toRecords(env.Id, recips);

        System.assertEquals(1, out.size(), 'only the recipient with an id is kept');
        System.assertEquals('r1', out[0].TurboDocx_Recipient_Id__c);
    }

    // TurboDocx named recipients but none could be recorded: say so, or the envelope reads 0 of 0.
    @IsTest
    static void syncLogsWhenEveryReturnedRecipientIsDropped() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-all-dropped');
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"sent"},"recipients":[{"name":"No Id"},"junk"]}}'));

            Test.startTest();
            Integer synced = TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals(0, synced);
            TurboSign_Log__c log = [SELECT Operation__c, Envelope__c, Error_Message__c FROM TurboSign_Log__c];
            System.assertEquals(env.Id, log.Envelope__c);
            System.assertEquals('TurboSignRecipientSync.syncEnvelope', log.Operation__c);
            System.assert(log.Error_Message__c.contains('2 of 2'), 'how many were dropped: ' + log.Error_Message__c);
            System.assert(log.Error_Message__c.contains('1 not a recipient object'), log.Error_Message__c);
            System.assert(log.Error_Message__c.contains('1 without an id'), log.Error_Message__c);
        }
    }

    @IsTest
    static void syncWithNoRecipientsInTheResponseIsNotLogged() {
        System.runAs(TurboSignTestRep.user()) {
            TurboSign_Envelope__c env = newEnvelope('doc-no-recipients');
            Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
                '{"data":{"document":{"status":"sent"},"recipients":[]}}'));

            Test.startTest();
            TurboSignRecipientSync.syncEnvelope(env.Id, true);
            Test.stopTest();

            System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Log__c], 'nothing was dropped');
        }
    }
}
