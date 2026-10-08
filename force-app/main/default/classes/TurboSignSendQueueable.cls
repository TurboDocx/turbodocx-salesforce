/**
 * Async send for automation and bulk (Flow / TurboSignSendAction): spec §2.4, callouts never
 * synchronous from trigger context, and nobody is waiting on the result, so failures are logged to
 * TurboSign_Log__c, not swallowed. The rep's Send button does NOT use this; it sends synchronously
 * so the modal can report the real outcome (see TurboSignQuickActionController.sendForSignature).
 */
public with sharing class TurboSignSendQueueable implements Queueable, Database.AllowsCallouts {
    private final Id sentByUserId;
    // Many record+config pairs from ONE enqueue, so a Flow never blows the 50-enqueued-jobs-per-transaction
    // limit; execute() works through them one record per chained job.
    private final List<Id> recordIds;
    private final List<String> configDeveloperNames;

    public TurboSignSendQueueable(List<Id> recordIds, List<String> configDeveloperNames, Id sentByUserId) {
        this.recordIds = recordIds;
        this.configDeveloperNames = configDeveloperNames;
        this.sentByUserId = sentByUserId;
    }

    /**
     * Sends ONE record, then chains a job for the rest. A transaction can't make a callout after DML,
     * and every send ends in DML (envelope or log), so looping here failed every record after the first
     * with "uncommitted work pending". One record per job also gives each send its own callout budget.
     * A failing record is logged and the chain continues. Developer Edition orgs cap chain depth at 5;
     * production orgs don't.
     */
    public void execute(QueueableContext ctx) {
        sendOne(recordIds[0], configDeveloperNames[0]);
        if (recordIds.size() > 1) {
            List<Id> restIds = new List<Id>();
            List<String> restCfgs = new List<String>();
            for (Integer i = 1; i < recordIds.size(); i++) {
                restIds.add(recordIds[i]);
                restCfgs.add(configDeveloperNames[i]);
            }
            // Apex tests can't run a chained job from inside a queueable ("Maximum stack depth").
            if (!(Test.isRunningTest() && System.isQueueable())) {
                System.enqueueJob(new TurboSignSendQueueable(restIds, restCfgs, sentByUserId));
            }
        }
    }

    private void sendOne(Id rid, String cfg) {
        try {
            TurboSignService.SendRequest req = TurboSignRequestBuilder.build(rid, cfg);
            req.sentByUserId = sentByUserId; // §6.1.1 — attribute to the rep, not the async user
            TurboSignService.sendForSignature(req);
        } catch (Exception e) {
            insert new TurboSign_Log__c(
                Operation__c = 'TurboSignSendQueueable',
                Error_Message__c = e.getMessage(),
                Occurred_On__c = System.now());
        }
    }
}
