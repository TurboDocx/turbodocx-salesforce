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
    private static final Integer GENERATION_TIMEOUT_MS = 120000;
    public class ApiException extends Exception {}

    public class ReviewResult {
        public Boolean success; public String documentId; public String status;
        public String previewUrl; public String message;
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


    /** POST /v1/deliverable — server-side document generation. Returns results.deliverable.id. */
    public static String generateDeliverable(Map<String, Object> body) {
        Map<String, Object> data = postJson('/v1/deliverable', body, GENERATION_TIMEOUT_MS);
        Object results = data.get('results');
        if (results instanceof Map<String, Object>) {
            Object deliverable = ((Map<String, Object>) results).get('deliverable');
            if (deliverable instanceof Map<String, Object>) {
                return (String) ((Map<String, Object>) deliverable).get('id');
            }
        }
        throw new ApiException('generateDeliverable: no deliverable id in response');
    }

    /** POST /turbosign/single/prepare-for-signing — prepares AND immediately emails recipients. */
    public static ReviewResult sendSignature(Map<String, Object> body) {
        serializeArrayFields(body);
        Map<String, Object> data = postJson('/turbosign/single/prepare-for-signing', body, GENERATION_TIMEOUT_MS);
        ReviewResult r = new ReviewResult();
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

    /** GET /template-item → the org's TurboDocx templates (for the config builder picker). */
    public static Map<String, Object> listTemplates() {
        return getJson('/template-item?page=1&limit=200');
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
        Map<String, Object> parsed = parseBody(res.getBody());
        if (code >= 200 && code < 300) {
            return unwrap(parsed);
        }
        // §8.7 — surface the API message; retry policy lives in the Queueable layer, not here.
        throw new ApiException(code + ': ' + messageOf(parsed, res));
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
