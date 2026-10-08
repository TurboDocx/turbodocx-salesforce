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
        Integer n = TurboSignRecipientSync.syncEnvelope(env.Id);
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

    @IsTest
    static void syncIsIdempotentByExternalId() {
        TurboSign_Envelope__c env = newEnvelope('doc-idem');
        String body =
            '{"data":{"recipients":[' +
            '{"id":"r1","name":"A","email":"a@x.com","status":"completed","effectiveStatus":"completed","signingOrder":1}],' +
            '"summary":{"total":1,"completed":1}}}';
        Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200, body));

        List<Object> sameRecips = (List<Object>) JSON.deserializeUntyped(
            '[{"id":"r1","name":"A","email":"a@x.com","status":"completed","effectiveStatus":"completed","signingOrder":1}]');

        Test.startTest();
        TurboSignRecipientSync.syncEnvelope(env.Id); // real sync: callout + upsert
        // A later sync upserts the same external id again (no second callout in one txn, per Apex rules).
        upsert TurboSignRecipientSync.toRecords(env.Id, sameRecips) TurboSign_Recipient__c.TurboDocx_Recipient_Id__c;
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM TurboSign_Recipient__c WHERE Envelope__c = :env.Id],
            'upsert by external id -> no duplicate child records on re-sync');
    }

    // Review: the sync already receives document.status; write terminal states onto the envelope.
    @IsTest
    static void syncMarksACompletedDocumentCompleted() {
        TurboSign_Envelope__c env = newEnvelope('doc-done');
        Test.setMock(HttpCalloutMock.class, new TurboSignHttpMock(200,
            '{"data":{"document":{"status":"completed"},"recipients":[{"id":"r9","name":"A","email":"a@x.com",'
            + '"status":"completed","effectiveStatus":"completed","signingOrder":1}]}}'));

        Test.startTest();
        TurboSignRecipientSync.syncEnvelope(env.Id);
        Test.stopTest();

        TurboSign_Envelope__c e = [SELECT Status__c, Completed_On__c, Sync_Active__c FROM TurboSign_Envelope__c WHERE Id = :env.Id];
        System.assertEquals('completed', e.Status__c, 'status follows the document');
        System.assertNotEquals(null, e.Completed_On__c, 'completion time stamped');
        System.assertEquals(false, e.Sync_Active__c, 'terminal status stops syncing');
    }
}
