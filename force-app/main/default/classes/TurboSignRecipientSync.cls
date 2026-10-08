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
            Map<String, Object> r = (Map<String, Object>) o;
            Map<String, Object> d = (r.get('delivery') instanceof Map<String, Object>)
                ? (Map<String, Object>) r.get('delivery') : new Map<String, Object>();
            out.add(new TurboSign_Recipient__c(
                Envelope__c               = envelopeId,
                TurboDocx_Recipient_Id__c = str(r.get('id')),
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
     * Fetches the live recipient state for an envelope, upserts the child records by external id
     * (idempotent), and rolls total/completed counts + Last_Synced__c onto the envelope.
     * @return number of recipients synced.
     */
    @AuraEnabled
    public static Integer syncEnvelope(Id envelopeId) {
        TurboSign_Envelope__c env = [
            SELECT Id, TurboDocx_Document_Id__c, Completed_On__c
            FROM TurboSign_Envelope__c WHERE Id = :envelopeId WITH USER_MODE LIMIT 1];

        Map<String, Object> resp = TurboSignHttpClient.getRecipients(env.TurboDocx_Document_Id__c);
        List<Object> recips = (resp != null && resp.get('recipients') instanceof List<Object>)
            ? (List<Object>) resp.get('recipients') : new List<Object>();

        List<TurboSign_Recipient__c> records = toRecords(envelopeId, recips);
        if (!records.isEmpty()) {
            upsert as user records TurboSign_Recipient__c.TurboDocx_Recipient_Id__c;
        }

        // Recipient_Count__c and Signed_Count__c are roll-up summaries over the (master-detail)
        // child recipients, so they recompute automatically from the upsert above — we only stamp
        // the sync time here.
        env.Last_Synced__c = System.now();
        applyDocumentStatus(env, resp);
        update as user env;
        return records.size();
    }

    private static final Set<String> TERMINAL = new Set<String>{ 'completed', 'voided', 'expired' };

    /** Mirror the document's status onto the envelope; terminal states stamp completion and stop syncing. */
    private static void applyDocumentStatus(TurboSign_Envelope__c env, Map<String, Object> resp) {
        Object doc = (resp == null) ? null : resp.get('document');
        if (!(doc instanceof Map<String, Object>)) return;
        String status = str(((Map<String, Object>) doc).get('status'));
        if (String.isBlank(status)) return;
        status = status.toLowerCase();
        if (!new Set<String>{ 'sent', 'under_review', 'completed', 'voided', 'expired' }.contains(status)) return;
        env.Status__c = status;
        if (TERMINAL.contains(status)) env.Sync_Active__c = false;
        if (status == 'completed' && env.Completed_On__c == null) env.Completed_On__c = System.now();
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
