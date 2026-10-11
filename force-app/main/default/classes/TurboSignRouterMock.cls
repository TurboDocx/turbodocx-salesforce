@IsTest
public class TurboSignRouterMock implements HttpCalloutMock {
    public static String lastReviewBody;
    public static String lastSignBody;
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(200);
        String ep = req.getEndpoint();
        if (ep.endsWith('/v1/deliverable')) {
            res.setBody('{"data":{"results":{"deliverable":{"id":"del-999","name":"Lease","fileType":"docx"}}}}');
        } else if (ep.endsWith('/turbosign/single/prepare-for-review')) {
            lastReviewBody = req.getBody();
            res.setBody('{"data":{"success":true,"documentId":"doc-999","status":"under_review","previewUrl":"https://td/p/999","message":"ok"}}');
        } else if (ep.endsWith('/turbosign/single/prepare-for-signing')) {
            lastSignBody = req.getBody();
            res.setBody('{"data":{"success":true,"documentId":"doc-888","status":"sent","message":"ok"}}');
        } else if (ep.endsWith('/turbosign/single/preview-anchors')) {
            res.setBody('{"data":{"results":{"anchors":[' +
                '{"anchor":"{sig}","found":true,"occurrences":1},' +
                '{"anchor":"{date}","found":false,"occurrences":0}]}}}');
        } else if (ep.contains('/template/')) {
            // GET /template/{id} -> template detail incl. its parsed placeholders
            res.setBody('{"data":{"results":{"id":"tpl-1","name":"Lease","variables":[' +
                '{"placeholder":"{ClientName}","mimeType":"text"},' +
                '{"placeholder":"{EffectiveDate}","mimeType":"text"}]}}}');
        } else {
            res.setStatusCode(404); res.setBody('{"message":"unexpected ' + ep + '"}');
        }
        return res;
    }
}
