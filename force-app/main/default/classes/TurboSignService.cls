/**
 * Orchestration facade for the send path (spec §9.1). Resolves nothing customer-specific by name;
 * callers pass already-resolved variables/recipients/fields. Generates the deliverable, creates the
 * signature review link, and records a TurboSign_Envelope__c.
 */
public with sharing class TurboSignService {
    public class SendRequest {
        public Id recordId;
        public String templateId;
        public String documentName;
        public List<Object> variables;   // [{placeholder,text,mimeType}]
        public List<Object> recipients;  // [{name,email,signingOrder}]
        public List<Object> fields;      // [{type,recipientEmail,template:{anchor,...}}]
        public String configDeveloperName;
        public String senderEmail;       // required by the API for sends
        public String senderName;
        public Id sentByUserId;          // §6.1.1 — captured in sync context, passed into async jobs
        public String completionField;   // §M5 — optional: field to set on the record when signing completes
        public String completionValue;   // §M5 — value to write into completionField
        public Integer generationTimeoutMs; // optional: null keeps the send's full generation timeout
    }

    /**
     * §M5: the write-back target the backend's SalesforceSignatureCompletionCallback reads. Always
     * carries integrationName and salesforceOrgId (this org's 18-char id). The backend uses the
     * TurboDocx Salesforce connection whose Salesforce org matches salesforceOrgId; if none matches,
     * write-back is skipped and recorded. With a record, it also carries salesforceRecordId plus the
     * optional completion field/value/objectType so the callback can advance status. Without a record,
     * those keys are omitted (never the literal 'null'), so there is nothing to write back to.
     */
    private static Map<String, Object> integrationMetadata(SendRequest req) {
        Map<String, Object> m = new Map<String, Object>{
            'integrationName' => 'salesforce',
            'salesforceOrgId' => UserInfo.getOrganizationId()
        };
        if (req.recordId == null) {
            return m;
        }
        m.put('salesforceRecordId', String.valueOf(req.recordId));
        if (String.isNotBlank(req.completionField)) {
            m.put('salesforceObjectType', sObjectTypeOf(req.recordId));
            m.put('salesforceCompletionField', req.completionField);
            m.put('salesforceCompletionValue', req.completionValue);
        }
        return m;
    }

    /**
     * Renders the document for this request at TurboDocx (POST /v1/deliverable) and returns the
     * deliverable id. One body for every path, so the Review step's Preview PDF shows exactly the
     * document a send generates.
     */
    public static String generateDeliverable(SendRequest req) {
        return TurboSignHttpClient.generateDeliverable(new Map<String, Object>{
            'templateId' => req.templateId,
            'name'       => req.documentName,
            'variables'  => req.variables
        }, req.generationTimeoutMs);
    }

    /** API name of the record's SObject type, or null when there is no record. */
    private static String sObjectTypeOf(Id recordId) {
        return recordId == null ? null : recordId.getSObjectType().getDescribe().getName();
    }

    // System mode on purpose: the envelope's TurboDocx document id and related record are written by
    // the send itself, and reps are deliberately denied edit on those fields (see TurboSign_User).
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Id createEnvelopeForReview(SendRequest req) {
        // §6.1.1 — capture the sending user NOW, in synchronous context. Never inside async, where
        // the job may run as the integration user and misattribute every envelope.
        Id sentBy = (req.sentByUserId != null) ? req.sentByUserId : UserInfo.getUserId();

        String deliverableId = generateDeliverable(req);

        TurboSignHttpClient.ReviewResult review = TurboSignHttpClient.createSignatureReviewLink(
            new Map<String, Object>{
                'deliverableId' => deliverableId,
                'recipients'    => req.recipients,
                'fields'        => req.fields,
                'documentName'  => req.documentName,
                // §M5: stamp the completion target so the backend's SalesforceSignatureCompletionCallback
                // pushes the signed PDF back onto this record (and optionally advances a field). salesforceUserId
                // is omitted: the backend uses the TurboDocx Salesforce connection whose Salesforce org matches
                // salesforceOrgId; if none matches, write-back is skipped and recorded.
                'integrationMetadata' => integrationMetadata(req)
            });

        String sobjType = sObjectTypeOf(req.recordId);
        TurboSign_Envelope__c e = new TurboSign_Envelope__c(
            TurboDocx_Document_Id__c = review.documentId,
            Preview_Url__c           = review.previewUrl,
            Status__c                = review.status,
            Document_Name__c         = req.documentName,
            Related_Record_Id__c     = req.recordId,
            Related_SObject_Type__c  = sobjType,
            Config_Developer_Name__c = req.configDeveloperName,
            Sent_By__c               = sentBy
        );
        // Convenience Opportunity lookup — safe because Opportunity is standard (§6.1.2).
        if (sobjType == 'Opportunity') {
            e.Related_Opportunity__c = req.recordId;
        }
        insert as system e;
        return e.Id;
    }

    /**
     * Generates the document and SENDS it for signature immediately (emails go out), then records
     * the envelope with Status 'sent' and Sent_On. Same §6.1.1 running-user capture.
     */
    /**
     * Where the last sendForSignature got to: 'generate', 'send' (the call that emails signers), or
     * 'record' (TurboDocx accepted; writing the envelope). Lets the rep-facing caller tell "nothing was
     * sent" from "TurboDocx may already have emailed the signers" when it fails.
     */
    public static String stage;

    // System mode on purpose: the envelope's TurboDocx document id and related record are written by
    // the send itself, and reps are deliberately denied edit on those fields (see TurboSign_User).
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Id sendForSignature(SendRequest req) {
        Id sentBy = (req.sentByUserId != null) ? req.sentByUserId : UserInfo.getUserId();
        stage = 'generate';

        String deliverableId = generateDeliverable(req);

        stage = 'send';
        TurboSignHttpClient.ReviewResult sent = TurboSignHttpClient.sendSignature(
            new Map<String, Object>{
                'deliverableId' => deliverableId,
                'recipients'    => req.recipients,
                'fields'        => req.fields,
                'documentName'  => req.documentName,
                'senderEmail'   => req.senderEmail,
                'senderName'    => req.senderName,
                // §M5 — see createEnvelopeForReview: stamp the write-back target for the backend callback.
                'integrationMetadata' => integrationMetadata(req)
            });

        stage = 'record';
        String sobjType = sObjectTypeOf(req.recordId);
        TurboSign_Envelope__c e = new TurboSign_Envelope__c(
            TurboDocx_Document_Id__c = sent.documentId,
            Status__c                = 'sent',
            Sent_On__c               = System.now(),
            Document_Name__c         = req.documentName,
            Related_Record_Id__c     = req.recordId,
            Related_SObject_Type__c  = sobjType,
            Config_Developer_Name__c = req.configDeveloperName,
            Sent_By__c               = sentBy
        );
        if (sobjType == 'Opportunity') {
            e.Related_Opportunity__c = req.recordId;
        }
        insert as system e;
        recordRecipients(e.Id, sent.recipients);
        return e.Id;
    }

    /**
     * Records the recipients TurboDocx created for this send, so the envelope's roll-up counts read
     * "0 of 1 signed" at once instead of "0 of 0" until the first status sync. Keyed by the TurboDocx
     * recipient id, which the sync upserts on, so it updates these rows rather than adding new ones.
     * Best effort: the document is already out, so a row that won't save is logged, never thrown,
     * which would report a successful send as possibly sent.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static void recordRecipients(Id envelopeId, List<Object> recipients) {
        try {
            // Parsing sits inside the try too: an unexpected response shape must not throw here.
            List<TurboSign_Recipient__c> rows = TurboSignRecipientSync.toRecords(envelopeId, recipients);
            // Some (or all) recipients could not be keyed to a row: say which and why, or the envelope
            // undercounts ("0 of 0 signed") with nothing to explain it.
            if (recipients != null && rows.size() < recipients.size()) {
                logRecipientFailure(envelopeId, RECORD_RECIPIENTS, TurboSignRecipientSync.describeDropped(recipients));
            }
            if (rows.isEmpty()) return;
            // Partial save: one row that won't save must not drop the others.
            List<Database.UpsertResult> results = Database.upsert(
                rows, TurboSign_Recipient__c.TurboDocx_Recipient_Id__c, false, AccessLevel.SYSTEM_MODE);
            List<String> failures = new List<String>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) continue;
                List<String> messages = new List<String>();
                for (Database.Error err : results[i].getErrors()) messages.add(err.getMessage());
                failures.add(rows[i].TurboDocx_Recipient_Id__c + ': ' + String.join(messages, '; '));
            }
            if (!failures.isEmpty()) logRecipientFailure(envelopeId, RECORD_RECIPIENTS, String.join(failures, '\n'));
        } catch (Exception ex) {
            logRecipientFailure(envelopeId, RECORD_RECIPIENTS, ex.getMessage());
        }
    }

    private static final String RECORD_RECIPIENTS = 'TurboSignService.recordRecipients';

    /**
     * Logs a recipient that could not be recorded. Never throws: this runs after the document was sent
     * (or after a sync's callout), so a log that won't save is only debugged.
     * @param operation the method that dropped the recipient, shown to the admin on the log row.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static void logRecipientFailure(Id envelopeId, String operation, String message) {
        try {
            insert as system new TurboSign_Log__c(
                Operation__c = operation,
                Envelope__c = envelopeId,
                Error_Message__c = (message == null) ? null : message.abbreviate(32768),
                Occurred_On__c = System.now());
        } catch (Exception logEx) {
            System.debug(LoggingLevel.ERROR, 'TurboSign recipient log failed: ' + logEx.getMessage() + ' / ' + message);
        }
    }
}
