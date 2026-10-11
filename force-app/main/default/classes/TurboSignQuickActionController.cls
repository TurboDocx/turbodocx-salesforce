/** @AuraEnabled surface for the record-page LWC (spec §9.2). */
public with sharing class TurboSignQuickActionController {

    @AuraEnabled(cacheable=true)
    public static List<TurboSign_Envelope__c> getEnvelopes(Id recordId) {
        if (recordId == null) return new List<TurboSign_Envelope__c>();
        // Don't leak envelopes (incl. Preview_Url__c) for a parent record the caller cannot read.
        // The envelope OWD is org-wide ReadWrite, so `with sharing` alone imposes no parent-record check.
        List<UserRecordAccess> access = [
            SELECT RecordId FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId AND HasReadAccess = true WITH USER_MODE];
        if (access.isEmpty()) return new List<TurboSign_Envelope__c>();
        return [
            SELECT Id, Name, Status__c, Document_Name__c, Preview_Url__c, Sent_On__c, Completed_On__c,
                   Recipient_Count__c, Signed_Count__c, Reminders_Sent__c, TurboDocx_Document_Id__c,
                   Days_Outstanding__c, Last_Synced__c
            FROM TurboSign_Envelope__c
            WHERE Related_Record_Id__c = :String.valueOf(recordId)
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    /**
     * Resolved-but-not-sent view for the pre-send review modal: variables prefilled from the record
     * (with an editable flag), resolved recipients, and configured anchors. The LWC shows these for the
     * rep to eyeball/correct before sending. Anchor found/missing QA is layered in by the LWC calling
     * the backend preview separately (kept off this cacheable method so it stays a cheap, no-callout read).
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> previewForSignature(Id recordId, String configDeveloperName) {
        return TurboSignRequestBuilder.preview(recordId, configDeveloperName);
    }

    /**
     * Pre-send anchor QA: renders the deliverable at TurboDocx and reports which configured anchors are
     * actually present, so the rep sees signature spots are in place before sending. Makes a callout
     * (not cacheable). Returns [{anchor, found, occurrences}].
     */
    @AuraEnabled
    public static List<Object> checkAnchors(Id recordId, String configDeveloperName) {
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(recordId, configDeveloperName);
        List<Object> variables = new List<Object>();
        for (Object vo : req.variables) {
            Map<String, Object> v = (Map<String, Object>) vo;
            variables.add(new Map<String, Object>{ 'placeholder' => v.get('placeholder'), 'text' => v.get('text') });
        }
        List<Object> anchors = new List<Object>();
        Set<String> seen = new Set<String>();
        for (Object fo : req.fields) {
            Map<String, Object> tpl = (Map<String, Object>) ((Map<String, Object>) fo).get('template');
            String a = (tpl == null) ? null : (String) tpl.get('anchor');
            if (String.isNotBlank(a) && !seen.contains(a)) { seen.add(a); anchors.add(a); }
        }
        return TurboSignHttpClient.checkAnchors(new Map<String, Object>{
            'templateId' => req.templateId, 'variables' => variables, 'anchors' => anchors });
    }

    /**
     * Sends a record + config for signature NOW, applying the rep's edited variable values
     * (placeholder -> value JSON) from the review modal. Pass null/blank overridesJson for a plain send.
     * Returns the new envelope id. (@AuraEnabled can't be overloaded, so this is the single send entry.)
     *
     * Why synchronous: the rep is waiting on this click, so the modal must only say "Sent" after
     * TurboDocx accepted the envelope, and must show the real reason when it didn't. This used to
     * enqueue TurboSignSendQueueable and return at once, so every send showed a success toast and
     * failures only reached TurboSign_Log__c, where no rep looks. Salesforce allows callouts from a
     * user-initiated @AuraEnabled call; the async rule (spec §2.4) is for trigger and automation
     * context, which still uses the Queueable (TurboSignSendAction for Flow/bulk). Callout wait time is
     * excluded from the concurrent long-running request limit, so many reps sending at once do not
     * throttle the org. TurboSignService.sendForSignature makes both callouts before any DML, as a
     * synchronous transaction requires. If generation ever gets slow enough to freeze the modal,
     * move this to a Continuation rather than back to fire-and-forget.
     */
    @AuraEnabled
    public static Map<String, Object> sendForSignature(Id recordId, String configDeveloperName, String overridesJson) {
        Id sentBy = UserInfo.getUserId(); // §6.1.1
        TurboSignService.stage = null;
        try {
            // Parsed inside the try: malformed overrides are a failed send with a log row, like any other.
            Overrides ov = new Overrides(overridesJson);
            TurboSignService.SendRequest req = TurboSignRequestBuilder.build(recordId, configDeveloperName, ov.variables, ov.recipients);
            req.sentByUserId = sentBy;
            return new Map<String, Object>{ 'ok' => true, 'envelopeId' => TurboSignService.sendForSignature(req) };
        } catch (Exception e) {
            // Returned, not thrown: a throw would roll back the log row, and the rep needs to know whether
            // TurboDocx may already have emailed the signers (a timeout on the send call, or a failure
            // after it accepted) so they don't send a duplicate.
            String stage = TurboSignService.stage;
            Boolean rejected = e instanceof TurboSignHttpClient.ApiException && e.getMessage().startsWith('4');
            Boolean maybeSent = stage == 'record' || (stage == 'send' && !rejected);
            insert as user new TurboSign_Log__c(
                Operation__c = 'TurboSignQuickActionController.sendForSignature',
                Error_Message__c = (stage == null ? '' : '[' + stage + '] ') + e.getMessage(),
                Occurred_On__c = System.now());
            String msg = maybeSent
                ? 'TurboDocx may already have sent this document. Check before sending again. (' + e.getMessage() + ')'
                : e.getMessage();
            return new Map<String, Object>{ 'ok' => false, 'maybeSent' => maybeSent, 'message' => msg };
        }
    }

    /** The rep's edits from the review modal (placeholder -> value, role -> name/email), parsed once. */
    private class Overrides {
        Map<String, String> variables = new Map<String, String>();
        Map<String, Map<String, String>> recipients = new Map<String, Map<String, String>>();
        Overrides(String overridesJson) {
            if (String.isBlank(overridesJson)) return;
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(overridesJson);
            if (raw.get('variables') instanceof Map<String, Object>) {
                Map<String, Object> vm = (Map<String, Object>) raw.get('variables');
                for (String k : vm.keySet()) variables.put(k, vm.get(k) == null ? '' : String.valueOf(vm.get(k)));
            }
            if (raw.get('recipients') instanceof List<Object>) {
                for (Object ro : (List<Object>) raw.get('recipients')) {
                    Map<String, Object> rm = (Map<String, Object>) ro;
                    String role = String.valueOf(rm.get('role'));
                    if (String.isBlank(role)) continue;
                    recipients.put(role, new Map<String, String>{
                        'name' => rm.get('name') == null ? '' : String.valueOf(rm.get('name')),
                        'email' => rm.get('email') == null ? '' : String.valueOf(rm.get('email')) });
                }
            }
        }
    }

    /**
     * Largest PDF the preview returns. The response body, its blob copy and the base64 copy (4/3 the size)
     * all sit on the 6 MB synchronous heap together, so 1 MB of PDF keeps the transaction clear of the limit.
     */
    @TestVisible private static Integer maxPreviewBytes = 1000000;

    /**
     * Review step "Preview PDF": renders this send's document with the rep's edits (the same
     * POST /v1/deliverable body a send uses) and returns the backend's rendered PDF as base64, so the
     * browser never needs TurboDocx credentials. Creates no signature request, emails nobody, and does
     * no DML. The deliverable is deleted again once its PDF is read (best effort).
     * Returns { fileName, base64 }; throws a readable AuraHandledException on failure.
     */
    @AuraEnabled
    public static Map<String, Object> previewPdf(Id recordId, String configDeveloperName, String overridesJson) {
        String message;
        try {
            Overrides ov = new Overrides(overridesJson);
            TurboSignRequestBuilder.BuildParams p = new TurboSignRequestBuilder.BuildParams();
            p.recordId = recordId;
            p.configDeveloperName = configDeveloperName;
            p.overrides = ov.variables;
            p.recipientOverrides = ov.recipients;
            // Recipients don't stop a preview: the deliverable needs only the template, name and variables.
            TurboSignService.SendRequest req = TurboSignRequestBuilder.buildForPreview(p);
            req.generationTimeoutMs = TurboSignHttpClient.PREVIEW_GENERATION_TIMEOUT_MS;
            String deliverableId = TurboSignService.generateDeliverable(req);
            Blob pdf;
            try {
                pdf = TurboSignHttpClient.getDeliverablePdf(deliverableId, maxPreviewBytes);
            } finally {
                discardPreviewDeliverable(deliverableId);
            }
            return new Map<String, Object>{
                'fileName' => (String.isBlank(req.documentName) ? 'Preview' : req.documentName) + '.pdf',
                'base64' => EncodingUtil.base64Encode(pdf) };
        } catch (TurboSignHttpClient.PdfTooLargeException e) {
            message = 'This document is too large to preview here ('
                + (e.bytes == null ? '' : megabytes(e.bytes, System.RoundingMode.CEILING) + ' MB, ')
                + 'the limit is ' + megabytes(maxPreviewBytes, System.RoundingMode.FLOOR) + ' MB). You can still send it.';
        } catch (Exception e) {
            message = 'Could not render the preview: ' + e.getMessage();
        }
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        throw ex;
    }

    /**
     * Best effort: the preview's deliverable has served its purpose once the PDF is read (or found too large),
     * so it is soft-deleted rather than left in the org's deliverables. A failed delete never fails the preview.
     * It is logged to the debug log, not TurboSign_Log__c: the preview does no DML, and a too-large preview
     * throws, which would roll a log row back anyway.
     */
    private static void discardPreviewDeliverable(String deliverableId) {
        try {
            TurboSignHttpClient.deleteDeliverable(deliverableId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'TurboSign preview: could not delete deliverable ' + deliverableId + ': ' + e.getMessage());
        }
    }

    // The size rounds up and the limit down, so a PDF over the limit never reads as "1.0 MB, the limit is 1.0 MB".
    private static String megabytes(Long bytes, System.RoundingMode mode) {
        return String.valueOf(Decimal.valueOf(bytes).divide(1000000, 1, mode));
    }

    /**
     * URL of the Visualforce page the Document tab frames to show the preview. The page reference adds the
     * package namespace prefix when there is one, which a hardcoded /apex/ path would miss.
     */
    @AuraEnabled(cacheable=true)
    public static String getViewerUrl() {
        return Page.TurboSign_PdfViewer.getUrl();
    }

    /** Config picker for the rep's send modal (reps don't get the admin TurboSignConfigController). */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> listConfigs(String sourceObject) {
        return TurboSignConfigController.listConfigs(sourceObject);
    }

    @AuraEnabled
    public static String remind(Id envelopeId) {
        TurboSignActionUtil.requireEditAccess(new Set<Id>{ envelopeId });
        String docId = TurboSignActionUtil.docIdsForEnvelopes(new Set<Id>{ envelopeId }).get(envelopeId);
        Map<String, Object> res = TurboSignHttpClient.sendReminder(docId, null);
        return JSON.serialize(res.get('results'));
    }

    @AuraEnabled
    public static void voidEnvelope(Id envelopeId, String reason) {
        // The write runs as the user, like the Flow action. Check the related record, the envelope and the
        // fields first, so a user who can't write them is refused before TurboDocx voids the document.
        TurboSignActionUtil.requireVoidAccess(new Set<Id>{ envelopeId });
        TurboSign_Envelope__c voided = TurboSignActionUtil.voided(envelopeId, reason);
        String docId = TurboSignActionUtil.docIdsForEnvelopes(new Set<Id>{ envelopeId }).get(envelopeId);
        TurboSignHttpClient.voidDocument(docId, reason);
        update as user voided;
    }
}
