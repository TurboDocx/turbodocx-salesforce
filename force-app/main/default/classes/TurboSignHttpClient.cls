/**
 * Owns every TurboDocx REST path + header in one place (spec §8, §9.1). All callouts go through
 * the TurboDocx_API Named Credential; applyAuth adds the Authorization + x-rapiddocx-org-id headers
 * as External Credential merge fields.
 * Paths/response shapes verified against the SDK (docs/SDK-REFERENCE.md).
 */
public with sharing class TurboSignHttpClient {
    // '' when unpackaged, 'ns__' inside a namespaced package (this class is then 'ns.TurboSignHttpClient').
    // Every credential reference below is built from it, so a namespaced version is one place to check.
    @TestVisible private static String nsPrefix = prefixFor(TurboSignHttpClient.class.getName());
    // Generation/rendering calls can run long; everything else keeps the 10s Apex default so a
    // hung status/void/reminder fails fast instead of eating the 120s per-transaction callout budget.
    @TestVisible private static final Integer GENERATION_TIMEOUT_MS = 120000;
    // The Review step's preview generates, reads the PDF and deletes the deliverable in one transaction, and
    // Apex allows 120s of callouts per transaction in total: generation 80s, PDF read 25s, delete 10s.
    public static final Integer PREVIEW_GENERATION_TIMEOUT_MS = 80000;
    @TestVisible private static final Integer PDF_TIMEOUT_MS = 25000;
    @TestVisible private static final Integer DELETE_TIMEOUT_MS = 10000;
    public class ApiException extends Exception {}

    public class ReviewResult {
        public Boolean success; public String documentId; public String status;
        public String previewUrl; public String message;
        public List<Object> recipients; // [{id, name, email}] as TurboDocx created them (send only)
    }

    /** POST /turbosign/single/prepare-for-review — prepares a document WITHOUT sending emails. */
    public static ReviewResult createSignatureReviewLink(Map<String, Object> body) {
        serializeArrayFields(body);
        Map<String, Object> data = postJson('/turbosign/single/prepare-for-review', body, GENERATION_TIMEOUT_MS);
        ReviewResult r = new ReviewResult();
        r.success   = (Boolean) data.get('success');
        r.documentId = (String) data.get('documentId');
        r.status    = (String) data.get('status');
        r.previewUrl = (String) data.get('previewUrl');
        r.message   = (String) data.get('message');
        return r;
    }


    /**
     * POST /v1/deliverable: server-side document generation. Returns results.deliverable.id.
     * timeoutMs is optional: null gives a send's full GENERATION_TIMEOUT_MS; the preview passes a shorter one.
     */
    public static String generateDeliverable(Map<String, Object> body, Integer timeoutMs) {
        Map<String, Object> data = postJson('/v1/deliverable', body, timeoutMs == null ? GENERATION_TIMEOUT_MS : timeoutMs);
        Object results = data.get('results');
        if (results instanceof Map<String, Object>) {
            Object deliverable = ((Map<String, Object>) results).get('deliverable');
            if (deliverable instanceof Map<String, Object>) {
                return (String) ((Map<String, Object>) deliverable).get('id');
            }
        }
        throw new ApiException('generateDeliverable: no deliverable id in response');
    }

    /** The PDF is bigger than the caller can hold. bytes is null when only the platform's size cap says so. */
    public class PdfTooLargeException extends Exception {
        public Long bytes; // Long: a Content-Length past 2^31 must not overflow
    }

    /**
     * GET /v1/deliverable/file/pdf/{id} -> the PDF the backend rendered when it generated the deliverable,
     * as raw bytes. Read-only: it creates no signature document and emails nobody.
     *
     * Throws PdfTooLargeException past maxBytes. Content-Length is checked before getBodyAsBlob copies the
     * body (the body is already on the heap when send() returns, and past the 6 MB synchronous heap limit the
     * transaction dies uncatchably); a Content-Length too long for a Long is too large without a size. The
     * Blob is checked again after the read, since Content-Length can be the compressed size or missing.
     * Without Content-Length there is no cheaper check: HttpResponse exposes no body size, and getBody() copies
     * just as getBodyAsBlob() does. The platform's 6 MB response cap bounds it (a body past the cap fails inside
     * send() and maps here too): a body under 1 MB is fine, and one well over 1 MB but under the cap, sent without
     * Content-Length, may exhaust the heap on the copy and fail as a generic error instead of the too-large message.
     */
    public static Blob getDeliverablePdf(String deliverableId, Integer maxBytes) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(base() + '/v1/deliverable/file/pdf/' + EncodingUtil.urlEncode(deliverableId, 'UTF-8'));
        req.setMethod('GET');
        req.setTimeout(PDF_TIMEOUT_MS);
        applyAuth(req);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            if (String.valueOf(e.getMessage()).startsWith('Exceeded max size limit')) {
                throw new PdfTooLargeException(e.getMessage());
            }
            throw e;
        }
        Integer code = res.getStatusCode();
        if (code < 200 || code >= 300) throw errorFor(res);
        String length = res.getHeader('Content-Length');
        if (String.isNotBlank(length) && length.isNumeric()) {
            // A Long holds every 18-digit number; 19 digits and up may not.
            if (length.length() > 18) throw new PdfTooLargeException('PDF Content-Length is ' + length);
            tooLarge(Long.valueOf(length), maxBytes);
        }
        Blob pdf = res.getBodyAsBlob();
        tooLarge(pdf.size(), maxBytes);
        return pdf;
    }

    /** DELETE /v1/deliverable/{id}: soft-deletes a deliverable (the preview's, once its PDF is read). */
    public static void deleteDeliverable(String deliverableId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(base() + '/v1/deliverable/' + EncodingUtil.urlEncode(deliverableId, 'UTF-8'));
        req.setMethod('DELETE');
        req.setTimeout(DELETE_TIMEOUT_MS);
        applyAuth(req);
        HttpResponse res = new Http().send(req);
        Integer code = res.getStatusCode();
        if (code < 200 || code >= 300) throw errorFor(res);
    }

    private static void tooLarge(Long bytes, Integer maxBytes) {
        if (bytes <= maxBytes) return;
        PdfTooLargeException e = new PdfTooLargeException('PDF is ' + bytes + ' bytes');
        e.bytes = bytes;
        throw e;
    }

    /** POST /turbosign/single/prepare-for-signing — prepares AND immediately emails recipients. */
    public static ReviewResult sendSignature(Map<String, Object> body) {
        serializeArrayFields(body);
        Map<String, Object> data = postJson('/turbosign/single/prepare-for-signing', body, GENERATION_TIMEOUT_MS);
        ReviewResult r = new ReviewResult();
        r.recipients = (data.get('recipients') instanceof List<Object>) ? (List<Object>) data.get('recipients') : null;
        r.success = (Boolean) data.get('success');
        r.documentId = (String) data.get('documentId');
        r.status = (String) data.get('status');
        r.previewUrl = (String) data.get('previewUrl');
        r.message = (String) data.get('message');
        return r;
    }

    /** GET /template/{id} → one template's detail, including the placeholders it already declares. */
    public static Map<String, Object> getTemplate(String templateId) {
        return getJson('/template/' + templateId);
    }

    /**
     * GET /template-item?type=template → the org's TurboDocx templates from every folder (for the config
     * builder picker). Without type the endpoint lists the root level only, folders included. It pages by
     * offset, not page.
     */
    public static Map<String, Object> listTemplates() {
        return getJson('/template-item?type=template&limit=200&offset=0');
    }

    /** Pre-send anchor QA: returns [{anchor, found, occurrences}] for the given template + variables. */
    public static List<Object> checkAnchors(Map<String, Object> body) {
        Map<String, Object> data = postJson('/turbosign/single/preview-anchors', body, GENERATION_TIMEOUT_MS);
        Object results = data.get('results');
        if (results instanceof Map<String, Object>) {
            Object anchors = ((Map<String, Object>) results).get('anchors');
            if (anchors instanceof List<Object>) return (List<Object>) anchors;
        }
        return new List<Object>();
    }

    /** GET /turbosign/documents/{id}/status → { status, expiresAt? } */
    public static Map<String, Object> getStatus(String documentId) {
        return getJson('/turbosign/documents/' + documentId + '/status');
    }

    /** GET /turbosign/documents/{id}/recipients → { document, recipients[], summary } */
    public static Map<String, Object> getRecipients(String documentId) {
        return getJson('/turbosign/documents/' + documentId + '/recipients');
    }

    /** POST /turbosign/documents/{id}/send-reminder → { results: [...] }. Omit ids to remind all eligible. */
    public static Map<String, Object> sendReminder(String documentId, List<String> recipientIds) {
        Map<String, Object> body = new Map<String, Object>();
        if (recipientIds != null && !recipientIds.isEmpty()) {
            body.put('recipientIds', recipientIds);
        }
        return postJson('/turbosign/documents/' + documentId + '/send-reminder', body);
    }

    /** POST /turbosign/documents/{id}/resend-email → { success, recipientCount }. recipientIds are UUIDs. */
    public static Map<String, Object> resend(String documentId, List<String> recipientIds) {
        return postJson('/turbosign/documents/' + documentId + '/resend-email',
            new Map<String, Object>{ 'recipientIds' => recipientIds });
    }

    /** POST /turbosign/documents/{id}/void → { id, name, status, voidReason?, voidedAt? }. reason required. */
    public static Map<String, Object> voidDocument(String documentId, String reason) {
        return postJson('/turbosign/documents/' + documentId + '/void',
            new Map<String, Object>{ 'reason' => reason });
    }

    /** Sends an authenticated GET and unwraps the {data:...} envelope. */
    @TestVisible
    private static Map<String, Object> getJson(String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(base() + path);
        req.setMethod('GET');
        applyAuth(req);
        return handle(new Http().send(req));
    }

    /** Sends a JSON POST, maps HTTP status to behavior (§8.7), and unwraps the {data:...} envelope. */
    @TestVisible
    private static Map<String, Object> postJson(String path, Map<String, Object> body) {
        return postJson(path, body, null);
    }

    private static Map<String, Object> postJson(String path, Map<String, Object> body, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(base() + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        if (timeoutMs != null) req.setTimeout(timeoutMs);
        applyAuth(req);
        req.setBody(JSON.serialize(body == null ? new Map<String, Object>() : body));
        HttpResponse res = new Http().send(req);
        return handle(res);
    }

    /**
     * The single-step endpoints (prepare-for-review / -for-signing) expect `recipients` and
     * `fields` as JSON STRINGS (the SDK serializes them, because the multipart path can't carry
     * nested objects). Callers may pass native Lists; stringify them so both paths match.
     */
    @TestVisible
    private static void serializeArrayFields(Map<String, Object> body) {
        for (String k : new List<String>{ 'recipients', 'fields' }) {
            Object v = body.get(k);
            if (v != null && !(v instanceof String)) {
                body.put(k, JSON.serialize(v));
            }
        }
    }

    @TestVisible
    private static String prefixFor(String qualifiedClassName) {
        return qualifiedClassName.contains('.') ? qualifiedClassName.substringBefore('.') + '__' : '';
    }

    private static String credentialName() {
        return nsPrefix + 'TurboDocx_API';
    }

    @TestVisible
    private static String base() {
        return 'callout:' + credentialName();
    }

    /**
     * Attaches the Bearer key and the TurboDocx org id. Apex stores and reads neither: the platform
     * resolves both merge fields from the TurboDocx_API External Credential principal's ApiKey and
     * OrgId parameters (exact names) at callout time (spec §8.2), for users granted principal
     * access. A missing parameter fails the callout with "Field TurboDocx_API.<name> does not exist".
     */
    // The Authorization value is a Named/External Credential merge field, not a literal secret.
    @SuppressWarnings('PMD.ApexSuggestUsingNamedCred')
    @TestVisible
    private static void applyAuth(HttpRequest req) {
        String cred = '{!$Credential.' + credentialName() + '.';
        req.setHeader('Authorization', 'Bearer ' + cred + 'ApiKey}');
        req.setHeader('x-rapiddocx-org-id', cred + 'OrgId}');
    }

    private static Map<String, Object> handle(HttpResponse res) {
        Integer code = res.getStatusCode();
        if (code >= 200 && code < 300) {
            return unwrap(parseBody(res.getBody()));
        }
        // §8.7 — surface the API message; retry policy lives in the Queueable layer, not here.
        throw errorFor(res);
    }

    /** Maps a failed response to its API message, for JSON calls, the binary PDF read and the delete alike. */
    private static ApiException errorFor(HttpResponse res) {
        return new ApiException(res.getStatusCode() + ': ' + messageOf(parseBody(res.getBody()), res));
    }

    private static Map<String, Object> parseBody(String raw) {
        if (String.isBlank(raw)) return new Map<String, Object>();
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            return new Map<String, Object>{ 'message' => raw };
        }
    }

    /** Smart-unwrap: strip the {data:...} envelope the backend wraps responses in. */
    private static Map<String, Object> unwrap(Map<String, Object> parsed) {
        if (parsed.size() == 1 && parsed.containsKey('data') && parsed.get('data') instanceof Map<String, Object>) {
            return (Map<String, Object>) parsed.get('data');
        }
        return parsed;
    }

    /**
     * The backend's 400 says only "There was an issue validating the body"; the failing fields are in
     * data.errors[].message. Append them so the rep (and the log) sees which value was rejected.
     */
    private static String validationDetails(Map<String, Object> parsed) {
        if (!(parsed.get('data') instanceof Map<String, Object>)) return '';
        Object errs = ((Map<String, Object>) parsed.get('data')).get('errors');
        if (!(errs instanceof List<Object>)) return '';
        List<String> msgs = new List<String>();
        for (Object o : (List<Object>) errs) {
            if (o instanceof Map<String, Object> && ((Map<String, Object>) o).get('message') != null) {
                msgs.add(String.valueOf(((Map<String, Object>) o).get('message')));
            }
        }
        return msgs.isEmpty() ? '' : ': ' + String.join(msgs, '; ');
    }

    private static String messageOf(Map<String, Object> parsed, HttpResponse res) {
        if (parsed.get('message') != null) return String.valueOf(parsed.get('message')) + validationDetails(parsed);
        if (parsed.get('error') != null) return String.valueOf(parsed.get('error'));
        return res.getStatus();
    }
}
