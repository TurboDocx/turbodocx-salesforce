/** Flow action: Send Reminder (manual nudge to current-order signers). */
public with sharing class TurboSignReminderAction {
    public class Input { @InvocableVariable(required=true label='Envelope Id') public Id envelopeId; }
    public class Output { @InvocableVariable public String status; @InvocableVariable public String message; }
    @InvocableMethod(label='TurboSign: Send Reminder' description='Sends a manual reminder to current-order signers.')
    public static List<Output> run(List<Input> inputs) {
        Set<Id> ids = new Set<Id>();
        for (Input inp : inputs) ids.add(inp.envelopeId);
        TurboSignActionUtil.requireEditAccess(ids);
        Map<Id, String> docs = TurboSignActionUtil.docIdsForEnvelopes(ids);
        List<Output> outs = new List<Output>();
        for (Input inp : inputs) {
            Output o = new Output();
            try {
                Map<String, Object> res = TurboSignHttpClient.sendReminder(docs.get(inp.envelopeId), null);
                o.status = 'ok'; o.message = JSON.serialize(res.get('results'));
            } catch (Exception e) { o.status = 'error'; o.message = e.getMessage(); }
            outs.add(o);
        }
        return outs;
    }
}
