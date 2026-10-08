/** Flow action: Get Envelope Status (live status of the signature document). */
public with sharing class TurboSignStatusAction {
    public class Input { @InvocableVariable(required=true label='Envelope Id') public Id envelopeId; }
    public class Output { @InvocableVariable public String status; @InvocableVariable public String expiresAt; }
    @InvocableMethod(label='TurboSign: Get Envelope Status' description='Reads the live status of a signature document.')
    public static List<Output> run(List<Input> inputs) {
        Set<Id> ids = new Set<Id>();
        for (Input inp : inputs) ids.add(inp.envelopeId);
        Map<Id, String> docs = TurboSignActionUtil.docIdsForEnvelopes(ids);
        List<Output> outs = new List<Output>();
        for (Input inp : inputs) {
            Output o = new Output();
            try {
                Map<String, Object> res = TurboSignHttpClient.getStatus(docs.get(inp.envelopeId));
                o.status = (String) res.get('status'); o.expiresAt = (String) res.get('expiresAt');
            } catch (Exception e) { o.status = 'error: ' + e.getMessage(); }
            outs.add(o);
        }
        return outs;
    }
}
