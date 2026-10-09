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
    }

    /**
     * §M5 — the write-back target the backend's SalesforceSignatureCompletionCallback reads. Carries
     * the record + (optional) completion field/value/objectType so the callback can advance status.
     */
    private static Map<String, Object> integrationMetadata(SendRequest req) {
        Map<String, Object> m = new Map<String, Object>{
            'integrationName'    => 'salesforce',
            'salesforceRecordId' => String.valueOf(req.recordId),
            // 18-char org id: the backend matches the TurboDocx Salesforce connection by org id.
            'salesforceOrgId'    => UserInfo.getOrganizationId()
        };
        if (String.isNotBlank(req.completionField)) {
            m.put('salesforceObjectType', req.recordId.getSObjectType().getDescribe().getName());
            m.put('salesforceCompletionField', req.completionField);
            m.put('salesforceCompletionValue', req.completionValue);
        }
        return m;
    }

    // System mode on purpose: the envelope's TurboDocx document id and related record are written by
    // the send itself, and reps are deliberately denied edit on those fields (see TurboSign_User).
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Id createEnvelopeForReview(SendRequest req) {
        // §6.1.1 — capture the sending user NOW, in synchronous context. Never inside async, where
        // the job may run as the integration user and misattribute every envelope.
        Id sentBy = (req.sentByUserId != null) ? req.sentByUserId : UserInfo.getUserId();

        String deliverableId = TurboSignHttpClient.generateDeliverable(new Map<String, Object>{
            'templateId' => req.templateId,
            'name'       => req.documentName,
            'variables'  => req.variables
        });

        TurboSignHttpClient.ReviewResult review = TurboSignHttpClient.createSignatureReviewLink(
            new Map<String, Object>{
                'deliverableId' => deliverableId,
                'recipients'    => req.recipients,
                'fields'        => req.fields,
                'documentName'  => req.documentName,
                // §M5 — stamp the completion target so the backend's SalesforceSignatureCompletionCallback
                // pushes the signed PDF back onto this record (and optionally advances a field). salesforceUserId
                // is omitted: the backend resolves the org's Salesforce connection (org API key auth).
                'integrationMetadata' => integrationMetadata(req)
            });

        String sobjType = req.recordId.getSObjectType().getDescribe().getName();
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

        String deliverableId = TurboSignHttpClient.generateDeliverable(new Map<String, Object>{
            'templateId' => req.templateId,
            'name'       => req.documentName,
            'variables'  => req.variables
        });

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
        String sobjType = req.recordId.getSObjectType().getDescribe().getName();
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
        return e.Id;
    }
}
