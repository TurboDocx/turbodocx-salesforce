/**
 * #45: the Review step's Preview PDF shows the rep the exact document that will go out, rendered
 * with their edits, without creating a signature request or emailing anyone.
 */
@IsTest
private class TurboSignPreviewPdfTest {
    private class PreviewMock implements HttpCalloutMock {
        private final Integer deliverableStatus;
        private final String deliverableBody;
        public List<String> endpoints = new List<String>();
        public String deliverableRequestBody;
        public String pdfContentLength; // set to report a size before the body is read
        public String pdfCalloutError; // the platform's own exception for the PDF read
        public String pdfBody = '%PDF-1.4 rendered';
        public Integer deleteStatus = 200;
        public String deleteCalloutError; // a delete that times out or can't connect
        PreviewMock(Integer deliverableStatus, String deliverableBody) {
            this.deliverableStatus = deliverableStatus; this.deliverableBody = deliverableBody;
        }
        public HttpResponse respond(HttpRequest req) {
            endpoints.add(req.getMethod() + ' ' + req.getEndpoint().substringAfter('TurboDocx_API'));
            HttpResponse res = new HttpResponse();
            if (req.getMethod() == 'DELETE') {
                if (deleteCalloutError != null) throw new CalloutException(deleteCalloutError);
                res.setHeader('Content-Type', 'application/json');
                res.setStatusCode(deleteStatus);
                res.setBody(deleteStatus == 200
                    ? '{"data":{"message":"Deliverable deleted successfully","deliverableId":"del-1"}}'
                    : '{"message":"delete failed"}');
            } else if (req.getEndpoint().endsWith('/v1/deliverable')) {
                deliverableRequestBody = req.getBody();
                res.setHeader('Content-Type', 'application/json');
                res.setStatusCode(deliverableStatus);
                res.setBody(deliverableBody);
            } else if (req.getEndpoint().contains('/v1/deliverable/file/pdf/')) {
                if (pdfCalloutError != null) throw new CalloutException(pdfCalloutError);
                res.setHeader('Content-Type', 'application/pdf');
                if (pdfContentLength != null) res.setHeader('Content-Length', pdfContentLength);
                res.setStatusCode(200);
                res.setBodyAsBlob(Blob.valueOf(pdfBody));
            } else {
                res.setStatusCode(500);
                res.setBody('{"message":"unexpected ' + req.getEndpoint() + '"}');
            }
            return res;
        }
    }

    private static final String DELIVERABLE_OK =
        '{"data":{"results":{"deliverable":{"id":"del-1","name":"Lease","fileType":"docx"}}}}';

    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Acme QA');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'QA Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = a.Id);
        insert o;
        return o;
    }

    private static String overrides() {
        return JSON.serialize(new Map<String, Object>{
            'variables' => new Map<String, Object>{ '{ClientName}' => 'Edited Inc' } });
    }

    @IsTest
    static void previewReturnsTheRenderedPdfWithoutSending() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', overrides());
        Test.stopTest();

        System.assertEquals('%PDF-1.4 rendered', EncodingUtil.base64Decode((String) res.get('base64')).toString(),
            'the PDF bytes reach the modal as base64');
        System.assert(String.isNotBlank((String) res.get('fileName')), 'named for the browser tab');
        System.assertEquals(new List<String>{
                'POST /v1/deliverable', 'GET /v1/deliverable/file/pdf/del-1', 'DELETE /v1/deliverable/del-1' },
            mock.endpoints, 'generates the document, reads its PDF and deletes the deliverable; never prepares or sends a signature');
        System.assert(mock.deliverableRequestBody.contains('Edited Inc'), 'renders the rep\'s edited values');
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Envelope__c], 'a preview creates no envelope');
    }

    @IsTest
    static void tooLargeToPreviewIsAReadableError() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new PreviewMock(200, DELIVERABLE_OK));
        TurboSignQuickActionController.maxPreviewBytes = 5;

        Test.startTest();
        String msg;
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg != null && msg.contains('too large to preview'), 'explains the size limit, got ' + msg);
    }

    @IsTest
    static void generationFailureIsAReadableError() {
        Opportunity o = makeOpp();
        Test.setMock(HttpCalloutMock.class, new PreviewMock(404,
            '{"error":"TemplateNotFound","message":"Template with id tpl-1 not found"}'));

        Test.startTest();
        String msg;
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg != null && msg.contains('Template with id tpl-1 not found'), 'surfaces the backend reason, got ' + msg);
        System.assertEquals(0, [SELECT COUNT() FROM TurboSign_Log__c], 'a preview writes nothing');
    }

    // Review: the size check must run on Content-Length, before the bytes are copied onto the heap.
    // A real 9 MB PDF would hit the uncatchable heap limit before a post-download check could run.
    @IsTest
    static void tooLargeIsDecidedFromContentLengthBeforeReadingTheBody() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.pdfContentLength = '9000000';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String msg;
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg != null && msg.contains('too large to preview') && msg.contains('9.0 MB'),
            'uses the reported size, got ' + msg);
        System.assert(mock.endpoints.contains('DELETE /v1/deliverable/del-1'),
            'a preview too large to show still deletes its deliverable, got ' + mock.endpoints);
    }

    // Review: a Content-Length past 2^31 must still read as "too large", not as an Integer overflow.
    @IsTest
    static void contentLengthPastIntegerRangeIsTooLarge() {
        String msg = previewErrorFor('3000000000');
        System.assert(msg.contains('too large to preview') && msg.contains('3000.0 MB'), 'uses the reported size, got ' + msg);
    }

    // Review: the response body is already on the heap before the size check, so the cap is 1 MB.
    @IsTest
    static void previewLimitIsOneMegabyte() {
        String msg = previewErrorFor('1500000');
        System.assert(msg.contains('too large to preview') && msg.contains('1.5 MB') && msg.contains('the limit is 1.0 MB'),
            'a 1.5 MB PDF is over the 1 MB limit, got ' + msg);
    }

    // Review 4: rounding to one decimal showed "1.0 MB, the limit is 1.0 MB" for a PDF just over the limit.
    // The size rounds up and the limit down, so the size always reads larger.
    @IsTest
    static void sizeJustOverTheLimitReadsLargerThanTheLimit() {
        String msg = previewErrorFor('1000001');
        System.assert(msg.contains('1.1 MB') && msg.contains('the limit is 1.0 MB'),
            'a PDF one byte over the limit reads larger than it, got ' + msg);
    }

    private static String previewErrorFor(String contentLength) {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.pdfContentLength = contentLength;
        Test.setMock(HttpCalloutMock.class, mock);
        String msg = 'no error';
        Test.startTest();
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();
        return msg;
    }

    // Review: generation plus the PDF read share one transaction, and Apex allows 120s of callouts in total.
    // Sends keep the full 120s for generation.
    // Review 3: the delete is a third callout in the same transaction, so the three share the 120s.
    @IsTest
    static void previewCalloutsFitTheTransactionCalloutBudget() {
        System.assertEquals(80000, TurboSignHttpClient.PREVIEW_GENERATION_TIMEOUT_MS, 'preview generation gets 80s');
        System.assertEquals(25000, TurboSignHttpClient.PDF_TIMEOUT_MS, 'the PDF read gets 25s');
        System.assertEquals(10000, TurboSignHttpClient.DELETE_TIMEOUT_MS, 'the delete gets 10s');
        System.assert(TurboSignHttpClient.PREVIEW_GENERATION_TIMEOUT_MS + TurboSignHttpClient.PDF_TIMEOUT_MS
            + TurboSignHttpClient.DELETE_TIMEOUT_MS <= 120000, 'generation + PDF read + delete must fit in 120000 ms');
        System.assertEquals(120000, TurboSignHttpClient.GENERATION_TIMEOUT_MS, 'the send path keeps its 120s');
    }

    // Review: a hardcoded /apex/TurboSign_PdfViewer breaks in a namespaced package; the page reference adds the prefix.
    @IsTest
    static void viewerUrlComesFromThePageReference() {
        String url = TurboSignQuickActionController.getViewerUrl();
        System.assert(url != null && url.equalsIgnoreCase(Page.TurboSign_PdfViewer.getUrl()),
            'viewer URL is the page reference URL, got ' + url);
        System.assert(url.toLowerCase().contains('turbosign_pdfviewer'), 'points at the viewer page, got ' + url);
    }

    // Review: a PDF past the platform's response cap fails inside the callout; say "too large", not the raw error.
    @IsTest
    static void platformSizeCapIsTheReadableTooLargeMessage() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.pdfCalloutError = 'Exceeded max size limit of 6000000';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String msg;
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assertEquals('This document is too large to preview here (the limit is 1.0 MB). You can still send it.', msg,
            'readable, without a size it does not know');
    }

    // Review 3: previews must not leave deliverables behind, but a failed delete must never cost the rep the preview.
    @IsTest
    static void aFailedDeleteStillReturnsThePdf() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.deleteStatus = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assert(mock.endpoints.contains('DELETE /v1/deliverable/del-1'), 'tried the delete, got ' + mock.endpoints);
        System.assertEquals('%PDF-1.4 rendered', EncodingUtil.base64Decode((String) res.get('base64')).toString(),
            'the PDF still reaches the modal');
    }

    @IsTest
    static void aDeleteThatCannotConnectStillReturnsThePdf() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.deleteCalloutError = 'Read timed out';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, Object> res = TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        Test.stopTest();

        System.assert(mock.endpoints.contains('DELETE /v1/deliverable/del-1'), 'tried the delete, got ' + mock.endpoints);
        System.assertEquals('%PDF-1.4 rendered', EncodingUtil.base64Decode((String) res.get('base64')).toString(),
            'the PDF still reaches the modal');
    }

    // Review 3: a Content-Length too long for a Long is too large, not a TypeException.
    @IsTest
    static void contentLengthPastLongRangeIsTooLarge() {
        String msg = previewErrorFor('99999999999999999999');
        System.assertEquals('This document is too large to preview here (the limit is 1.0 MB). You can still send it.', msg,
            'readable, without a size it can not hold');
    }

    // Review 3: a compressed response reports the compressed size; the decoded body is checked too.
    @IsTest
    static void bodyLargerThanItsContentLengthIsTooLarge() {
        Opportunity o = makeOpp();
        PreviewMock mock = new PreviewMock(200, DELIVERABLE_OK);
        mock.pdfContentLength = '10';
        mock.pdfBody = '%PDF-1.4 ' + 'x'.repeat(40);
        Test.setMock(HttpCalloutMock.class, mock);
        TurboSignQuickActionController.maxPreviewBytes = 20;

        Test.startTest();
        String msg = 'no error';
        try {
            TurboSignQuickActionController.previewPdf(o.Id, 'Example_Agreement', null);
        } catch (AuraHandledException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        System.assert(msg.contains('too large to preview'), 'checks the body it read, got ' + msg);
    }
}
