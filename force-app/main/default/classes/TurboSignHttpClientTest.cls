@IsTest
private class TurboSignHttpClientTest {
    // Friction #9: a bare /template-item lists the root level only (folders included), so a template
    // inside a folder never reached the config builder's picker. type=template lists templates from
    // every folder; the endpoint pages by offset, not page.
    @IsTest
    static void listTemplatesAsksForTemplatesInEveryFolder() {
        TurboSignHttpMock mock = new TurboSignHttpMock(200,
            '{"data":{"results":[{"id":"t-1","name":"Service Agreement","type":"template"}],"totalRecords":1}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TurboSignHttpClient.listTemplates();
        Test.stopTest();

        System.assert(mock.lastEndpoint.endsWith('/template-item?type=template&limit=200&offset=0'),
            'templates from every folder, got ' + mock.lastEndpoint);
        System.assertEquals('GET', mock.lastMethod, 'GET');
    }

    @IsTest
    static void createReviewLinkParsesWrappedResponse() {
        String body = '{"data":{"success":true,"documentId":"doc-123","status":"under_review",'
            + '"previewUrl":"https://td/preview/abc","message":"ok"}}';
        TurboSignHttpMock mock = new TurboSignHttpMock(200, body);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TurboSignHttpClient.ReviewResult res = TurboSignHttpClient.createSignatureReviewLink(
            new Map<String, Object>{ 'deliverableId' => 'del-1' });
        Test.stopTest();

        System.assertEquals('doc-123', res.documentId, 'documentId parsed from data wrapper');
        System.assertEquals('https://td/preview/abc', res.previewUrl, 'previewUrl parsed');
        System.assertEquals('under_review', res.status, 'status parsed');
        System.assert(mock.lastEndpoint.endsWith('/turbosign/single/prepare-for-review'),
            'hits the prepare-for-review path, got ' + mock.lastEndpoint);
        System.assertEquals('POST', mock.lastMethod, 'POST');
    }

    @IsTest
    static void badRequestThrowsApiException() {
        TurboSignHttpMock mock = new TurboSignHttpMock(400, '{"message":"senderEmail required"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean threw = false;
        try {
            TurboSignHttpClient.createSignatureReviewLink(new Map<String, Object>());
        } catch (TurboSignHttpClient.ApiException e) {
            threw = true;
            System.assert(e.getMessage().contains('senderEmail required'), 'surfaces API message');
        }
        Test.stopTest();
        System.assert(threw, '400 must raise ApiException');
    }

    // #39: the API key and org id live on the TurboDocx_API External Credential principal and are
    // merged in by the platform at callout time. Apex stores and reads neither, so no Setup
    // screen or custom setting shows them.
    private static final String AUTH = 'Bearer {!$Credential.TurboDocx_API.ApiKey}';
    private static final String ORG = '{!$Credential.TurboDocx_API.OrgId}';

    @IsTest
    static void bothHeadersComeFromTheExternalCredential() {
        HttpRequest req = new HttpRequest();

        TurboSignHttpClient.applyAuth(req);

        System.assertEquals(AUTH, req.getHeader('Authorization'), 'API key is the ApiKey merge field');
        System.assertEquals(ORG, req.getHeader('x-rapiddocx-org-id'), 'org id is the OrgId merge field');
    }

    // Guards the wiring, not just applyAuth: a real GET and POST must carry both auth headers.
    @IsTest
    static void realGetAndPostCarryTheAuthHeaders() {
        TurboSignHttpMock mock = new TurboSignHttpMock(200, '{"data":{"documentId":"d"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TurboSignHttpClient.getStatus('d');
        String getAuth = mock.lastAuthorization, getOrg = mock.lastOrgId, getUrl = mock.lastEndpoint;
        TurboSignHttpClient.createSignatureReviewLink(new Map<String, Object>());
        Test.stopTest();

        System.assertEquals(AUTH, getAuth, 'GET carries the ApiKey merge field');
        System.assertEquals(ORG, getOrg, 'GET carries the OrgId merge field');
        System.assert(getUrl.startsWith('callout:TurboDocx_API/'), 'unpackaged code calls the bare Named Credential');
        System.assertEquals(AUTH, mock.lastAuthorization, 'POST carries the ApiKey merge field');
        System.assertEquals(ORG, mock.lastOrgId, 'POST carries the OrgId merge field');
    }

    // Namespace readiness: every credential reference is built from one prefix derived from the
    // class's own name, so a namespaced package version needs no string hunt.
    @IsTest
    static void namespacePrefixComesFromTheQualifiedClassName() {
        System.assertEquals('', TurboSignHttpClient.prefixFor('TurboSignHttpClient'), 'unpackaged: no prefix');
        System.assertEquals('turbodocx__', TurboSignHttpClient.prefixFor('turbodocx.TurboSignHttpClient'),
            'packaged: ns__');
    }

    @IsTest
    static void credentialReferencesUseTheNamespacePrefix() {
        TurboSignHttpClient.nsPrefix = 'turbodocx__';
        HttpRequest req = new HttpRequest();

        TurboSignHttpClient.applyAuth(req);

        System.assertEquals('callout:turbodocx__TurboDocx_API', TurboSignHttpClient.base(), 'namespaced Named Credential');
        System.assertEquals('Bearer {!$Credential.turbodocx__TurboDocx_API.ApiKey}', req.getHeader('Authorization'),
            'namespaced External Credential in the ApiKey merge field');
        System.assertEquals('{!$Credential.turbodocx__TurboDocx_API.OrgId}', req.getHeader('x-rapiddocx-org-id'),
            'namespaced External Credential in the OrgId merge field');
    }
    private class PdfMock implements HttpCalloutMock {
        private final Integer status;
        public String calloutError; // thrown instead of answering, as the platform does
        public String lastEndpoint; public String lastMethod; public String lastAuthorization;
        PdfMock(Integer status) { this.status = status; }
        public HttpResponse respond(HttpRequest req) {
            lastEndpoint = req.getEndpoint(); lastMethod = req.getMethod(); lastAuthorization = req.getHeader('Authorization');
            if (calloutError != null) throw new CalloutException(calloutError);
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            if (status == 200) {
                res.setHeader('Content-Type', 'application/pdf');
                res.setBodyAsBlob(Blob.valueOf('%PDF-1.4 preview'));
            } else {
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"message":"There was an issue loading your file"}');
            }
            return res;
        }
    }

    // #45: the Review step's Preview PDF reads the rendered PDF of a generated deliverable as bytes.
    @IsTest
    static void getDeliverablePdfReturnsTheBytes() {
        PdfMock mock = new PdfMock(200);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Blob pdf = TurboSignHttpClient.getDeliverablePdf('del-1', 1000000);
        Test.stopTest();

        System.assertEquals('%PDF-1.4 preview', pdf.toString(), 'PDF bytes returned unchanged');
        System.assert(mock.lastEndpoint.endsWith('/v1/deliverable/file/pdf/del-1'), 'PDF path, got ' + mock.lastEndpoint);
        System.assertEquals('GET', mock.lastMethod, 'GET');
        System.assertEquals(AUTH, mock.lastAuthorization, 'authenticated through the External Credential');
    }

    @IsTest
    static void getDeliverablePdfFailureThrowsTheApiMessage() {
        Test.setMock(HttpCalloutMock.class, new PdfMock(404));

        Test.startTest();
        String msg;
        try {
            TurboSignHttpClient.getDeliverablePdf('del-1', 1000000);
        } catch (TurboSignHttpClient.ApiException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg != null && msg.contains('issue loading your file'), 'surfaces API message, got ' + msg);
    }

    // Review: a response without Content-Length is checked once, after the read, in the client.
    @IsTest
    static void pdfWithoutContentLengthOverTheLimitIsTooLarge() {
        Test.setMock(HttpCalloutMock.class, new PdfMock(200));

        Test.startTest();
        Long bytes;
        try {
            TurboSignHttpClient.getDeliverablePdf('del-1', 5);
        } catch (TurboSignHttpClient.PdfTooLargeException e) {
            bytes = e.bytes;
        }
        Test.stopTest();

        System.assertEquals('%PDF-1.4 preview'.length(), bytes, 'reports the size it read');
    }

    // Review: past the platform's response size cap the callout itself throws; that is still "too large".
    @IsTest
    static void platformSizeCapIsTooLarge() {
        PdfMock mock = new PdfMock(200);
        mock.calloutError = 'Exceeded max size limit of 6000000';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean tooLarge = false;
        try {
            TurboSignHttpClient.getDeliverablePdf('del-1', 1000000);
        } catch (TurboSignHttpClient.PdfTooLargeException e) {
            tooLarge = (e.bytes == null);
        }
        Test.stopTest();

        System.assert(tooLarge, 'size unknown, still too large');
    }

    @IsTest
    static void otherCalloutFailuresAreNotTooLarge() {
        PdfMock mock = new PdfMock(200);
        mock.calloutError = 'Read timed out';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String msg;
        try {
            TurboSignHttpClient.getDeliverablePdf('del-1', 1000000);
        } catch (TurboSignHttpClient.PdfTooLargeException e) {
            msg = 'too large';
        } catch (CalloutException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assertEquals('Read timed out', msg, 'passed through unchanged');
    }

    // Review 3: the preview deletes its deliverable once the PDF is read (soft delete on the backend).
    @IsTest
    static void deleteDeliverableSendsAnAuthenticatedDelete() {
        PdfMock mock = new PdfMock(200);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TurboSignHttpClient.deleteDeliverable('del-1');
        Test.stopTest();

        System.assertEquals('DELETE', mock.lastMethod, 'DELETE');
        System.assert(mock.lastEndpoint.endsWith('/v1/deliverable/del-1'), 'deliverable path, got ' + mock.lastEndpoint);
        System.assertEquals(AUTH, mock.lastAuthorization, 'authenticated through the External Credential');
    }

    @IsTest
    static void deleteDeliverableFailureThrowsTheApiMessage() {
        Test.setMock(HttpCalloutMock.class, new PdfMock(404));

        Test.startTest();
        String msg;
        try {
            TurboSignHttpClient.deleteDeliverable('del-1');
        } catch (TurboSignHttpClient.ApiException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg != null && msg.startsWith('404'), 'the caller decides what a failed delete means, got ' + msg);
    }
}
