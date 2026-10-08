/** Flow action: Send for Signature (async per §2.4; §6.1.1 running-user captured synchronously). */
public with sharing class TurboSignSendAction {
    public class Input {
        @InvocableVariable(required=true label='Record Id') public Id recordId;
        @InvocableVariable(required=true label='Config Developer Name') public String configDeveloperName;
    }
    @InvocableMethod(label='TurboSign: Send for Signature'
        description='Generates the configured document and sends it for signature (async).')
    public static void run(List<Input> inputs) {
        if (inputs == null || inputs.isEmpty()) return;
        Id sentBy = UserInfo.getUserId();
        // One Queueable for the whole batch: enqueuing per-input hits the 50-job/transaction cap on a
        // bulk Flow. Async lets the single job make one callout per record.
        List<Id> recordIds = new List<Id>();
        List<String> configs = new List<String>();
        for (Input inp : inputs) {
            recordIds.add(inp.recordId);
            configs.add(inp.configDeveloperName);
        }
        System.enqueueJob(new TurboSignSendQueueable(recordIds, configs, sentBy));
    }
}
