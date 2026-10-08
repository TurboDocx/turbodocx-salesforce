@IsTest
private class TurboSignHttpClientTest {
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
}
