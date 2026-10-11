/** Flow action: Void Envelope (voids the document and updates the envelope). */
public with sharing class TurboSignVoidAction {
    public class Input {
        @InvocableVariable(required=true label='Envelope Id') public Id envelopeId;
        @InvocableVariable(required=true label='Reason') public String reason;
    }
    public class Output { @InvocableVariable public String status; }
    @InvocableMethod(label='TurboSign: Void Envelope' description='Voids the signature document and updates the envelope.')
    public static List<Output> run(List<Input> inputs) {
        Set<Id> ids = new Set<Id>();
        for (Input inp : inputs) ids.add(inp.envelopeId);
        // Refuse before any callout, so TurboDocx never voids a document this user can't mark voided here.
        TurboSignActionUtil.requireVoidAccess(ids);
        Map<Id, String> docs = TurboSignActionUtil.docIdsForEnvelopes(ids);
        List<Output> outs = new List<Output>();
        List<TurboSign_Envelope__c> toUpdate = new List<TurboSign_Envelope__c>();
        for (Input inp : inputs) {
            Output o = new Output();
            try {
                TurboSignHttpClient.voidDocument(docs.get(inp.envelopeId), inp.reason);
                toUpdate.add(TurboSignActionUtil.voided(inp.envelopeId, inp.reason));
                o.status = 'voided';
            } catch (Exception e) { o.status = 'error: ' + e.getMessage(); }
            outs.add(o);
        }
        if (!toUpdate.isEmpty()) update as user toUpdate;
        return outs;
    }
}
