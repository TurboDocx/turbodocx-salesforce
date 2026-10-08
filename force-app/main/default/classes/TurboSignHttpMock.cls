@IsTest
public class TurboSignHttpMock implements HttpCalloutMock {
    public Integer statusCode;
    public String body;
    public String lastEndpoint;
    public String lastMethod;
    public String lastBody;
    public String lastAuthorization;
    public String lastOrgId;
    public TurboSignHttpMock(Integer statusCode, String body) {
        this.statusCode = statusCode; this.body = body;
    }
    public HttpResponse respond(HttpRequest req) {
        lastEndpoint = req.getEndpoint(); lastMethod = req.getMethod(); lastBody = req.getBody();
        lastAuthorization = req.getHeader('Authorization'); lastOrgId = req.getHeader('x-rapiddocx-org-id');
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setHeader('Content-Type', 'application/json');
        res.setBody(body);
        return res;
    }
}
