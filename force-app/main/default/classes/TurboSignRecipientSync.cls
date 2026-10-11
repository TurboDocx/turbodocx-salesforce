/**
 * Populates TurboSign_Recipient__c child records from the backend's per-recipient state
 * (GET /turbosign/documents/{id}/recipients) and rolls the counts onto the envelope, so
 * admins can report on signature status per recipient (issue #23).
 */
public with sharing class TurboSignRecipientSync {

    /** Pure mapping: backend recipient list -> child records for one envelope (no DML). */
    public static List<TurboSign_Recipient__c> toRecords(Id envelopeId, List<Object> backendRecipients) {
        List<TurboSign_Recipient__c> out = new List<TurboSign_Recipient__c>();
        if (backendRecipients == null) return out;
        for (Object o : backendRecipients) {
            // Skip anything that isn't a recipient object rather than fail the whole list on a cast.
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> r = (Map<String, Object>) o;
            // The id is the upsert key: without one, every sync would add another row for this recipient.
            String recipientId = str(r.get('id'));
            if (String.isBlank(recipientId)) continue;
            Map<String, Object> d = (r.get('delivery') instanceof Map<String, Object>)
                ? (Map<String, Object>) r.get('delivery') : new Map<String, Object>();
            out.add(new TurboSign_Recipient__c(
                Envelope__c               = envelopeId,
                TurboDocx_Recipient_Id__c = recipientId,
                Recipient_Name__c         = str(r.get('name')),
                Email__c                  = str(r.get('email')),
                Status__c                 = str(r.get('status')),
                Effective_Status__c       = str(r.get('effectiveStatus')),
                Signing_Order__c          = dec(r.get('signingOrder')),
                Signed_On__c              = dt(r.get('signedOn')),
                First_Sent_On__c          = dt(d.get('firstSentOn')),
                Last_Sent_On__c           = dt(d.get('lastSentOn')),
                Total_Sent__c             = dec(d.get('totalSent')),
                Reminder_Count__c         = dec(d.get('reminderCount')),
                Last_Reminded_At__c       = dt(d.get('lastRemindedAt')),
                Warning_Count__c          = dec(d.get('warningCount')),
                Last_Warning_At__c        = dt(d.get('lastWarningAt'))
            ));
        }
        return out;
    }

    /**
     * Why toRecords dropped some backend recipients, for the admin log; null when none were dropped.
     * Mirrors toRecords' two skips: an entry that is not a recipient object, and one without an id.
     */
    public static String describeDropped(List<Object> backendRecipients) {
        if (backendRecipients == null || backendRecipients.isEmpty()) return null;
        Integer notObjects = 0;
        Integer missingIds = 0;
        for (Object o : backendRecipients) {
            if (!(o instanceof Map<String, Object>)) {
                notObjects++;
            } else if (String.isBlank(str(((Map<String, Object>) o).get('id')))) {
                missingIds++;
            }
        }
        Integer dropped = notObjects + missingIds;
        if (dropped == 0) return null;
        return 'TurboDocx returned recipients that were not recorded: ' + dropped + ' of '
            + backendRecipients.size() + ' (' + notObjects + ' not a recipient object, '
            + missingIds + ' without an id).';
    }

    /** An envelope synced this recently is current enough; a load-time sync skips the callout. */
    @TestVisible private static final Integer RECENT_SYNC_MINUTES = 5;

    /**
     * Fetches the live recipient state for an envelope, upserts the child records by external id
     * (idempotent), and rolls total/completed counts + Last_Synced__c onto the envelope.
     * @param force true from the Refresh button: sync even if the envelope was synced moments ago.
     *              Anything else (the panel's load-time sync passes nothing) honours the throttle.
     * @return number of recipients synced (0 when throttled).
     */
    @AuraEnabled
    public static Integer syncEnvelope(Id envelopeId, Boolean force) {
        TurboSign_Envelope__c env = [
            SELECT Id, TurboDocx_Document_Id__c, Last_Synced__c
            FROM TurboSign_Envelope__c WHERE Id = :envelopeId WITH USER_MODE LIMIT 1];
        if (force != true && env.Last_Synced__c != null
                && env.Last_Synced__c > System.now().addMinutes(-RECENT_SYNC_MINUTES)) {
            return 0;
        }

        Map<String, Object> resp = TurboSignHttpClient.getRecipients(env.TurboDocx_Document_Id__c);
        List<Object> recips = (resp != null && resp.get('recipients') instanceof List<Object>)
            ? (List<Object>) resp.get('recipients') : new List<Object>();

        List<TurboSign_Recipient__c> records = toRecords(envelopeId, recips);
        if (!records.isEmpty()) {
            upsert as user records TurboSign_Recipient__c.TurboDocx_Recipient_Id__c;
        }

        // Re-read (and lock) after the callout: a Void or the completion callback can land while the
        // callout is in flight, and the status fetched before it must not overwrite that.
        TurboSign_Envelope__c current = [
            SELECT Id, Status__c, Sent_On__c, Completed_On__c
            FROM TurboSign_Envelope__c WHERE Id = :envelopeId WITH USER_MODE LIMIT 1 FOR UPDATE];

        // Recipient_Count__c and Signed_Count__c are roll-up summaries over the (master-detail)
        // child recipients, so they recompute automatically from the upsert above — we only stamp
        // the sync time here. Update only the fields the sync writes: the re-read record carries fields
        // a rep may read but not edit, and `update as user` rejects them.
        TurboSign_Envelope__c changes = new TurboSign_Envelope__c(Id = envelopeId, Last_Synced__c = System.now());
        applyDocumentStatus(current, changes, resp, firstSentOn(records));
        update as user changes;
        // TurboDocx named recipients but none could be recorded: say so, or the envelope reads 0 of 0.
        if (records.isEmpty() && !recips.isEmpty()) {
            TurboSignService.logRecipientFailure(envelopeId, 'TurboSignRecipientSync.syncEnvelope',
                describeDropped(recips));
        }
        return records.size();
    }

    private static final Set<String> TERMINAL = new Set<String>{ 'completed', 'voided', 'expired' };

    /**
     * Mirror the document's status onto the envelope; terminal states stamp completion and stop syncing.
     * Forward only: a finished envelope (completed, voided, expired) never changes again.
     */
    private static void applyDocumentStatus(TurboSign_Envelope__c env, TurboSign_Envelope__c changes, Map<String, Object> resp, Datetime firstSent) {
        if (TERMINAL.contains(env.Status__c)) return;
        Object docObj = (resp == null) ? null : resp.get('document');
        if (!(docObj instanceof Map<String, Object>)) return;
        Map<String, Object> doc = (Map<String, Object>) docObj;
        String status = str(doc.get('status'));
        if (String.isBlank(status)) return;
        status = status.toLowerCase();
        if (!new Set<String>{ 'sent', 'under_review', 'completed', 'voided', 'expired' }.contains(status)) return;
        changes.Status__c = status;
        // A review link has no Sent_On__c until the rep sends it from TurboDocx. Its status can read
        // under_review before then, so the status never says it was sent. The document's sent time
        // (its DOCUMENT_SENT audit) does, and covers embedded signing, which emails nobody; the
        // earliest recipient delivery is the fallback for a response without one.
        Datetime sentOn = dt(doc.get('sentOn'));
        if (sentOn == null) sentOn = firstSent;
        if (env.Sent_On__c == null && sentOn != null) changes.Sent_On__c = sentOn;
        if (TERMINAL.contains(status)) changes.Sync_Active__c = false;
        if (status == 'completed' && env.Completed_On__c == null) changes.Completed_On__c = System.now();
    }

    /** The earliest recipient First_Sent_On__c, or null when no recipient has been sent the document. */
    private static Datetime firstSentOn(List<TurboSign_Recipient__c> records) {
        Datetime earliest;
        for (TurboSign_Recipient__c r : records) {
            if (r.First_Sent_On__c != null && (earliest == null || r.First_Sent_On__c < earliest)) {
                earliest = r.First_Sent_On__c;
            }
        }
        return earliest;
    }

    // ---- helpers ----
    private static String str(Object o) { return o == null ? null : String.valueOf(o); }

    private static Decimal dec(Object o) {
        if (o == null) return null;
        try { return Decimal.valueOf(String.valueOf(o)); } catch (Exception e) { return null; }
    }

    /** Parse an ISO-8601 string (e.g. "2026-08-27T14:56:15.000Z") to Datetime; null-safe. */
    private static Datetime dt(Object o) {
        if (o == null) return null;
        String s = String.valueOf(o);
        if (String.isBlank(s)) return null;
        try { return (Datetime) JSON.deserialize('"' + s + '"', Datetime.class); } catch (Exception e) { return null; }
    }
}
