/**
 * Records the outcome of the async CMDT deploy kicked off by TurboSignConfigController.saveConfig
 * (spec #7). enqueueDeployment returns before the deploy runs, so this callback fires on completion
 * and writes a TurboSign_Log__c keyed by the job id; the config-builder LWC polls
 * getConfigDeployStatus(jobId) to show the admin a real success/failure instead of an optimistic toast.
 */
public with sharing class TurboSignConfigDeployCallback implements Metadata.DeployCallback {
    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        List<String> errors = new List<String>();
        if (result != null && result.details != null && result.details.componentFailures != null) {
            for (Metadata.DeployMessage m : result.details.componentFailures) {
                errors.add(m.fullName + ': ' + m.problem);
            }
        }
        String status = (result != null) ? String.valueOf(result.status) : 'Unknown';
        // Key on the deployment id (== the value enqueueDeployment returned to saveConfig/the LWC),
        // NOT context.getCallbackJobId() which is a different async-job id the caller never sees.
        String key = (result != null && result.id != null) ? result.id : String.valueOf(context.getCallbackJobId());
        TurboSignConfigController.logDeployResult(key, status, errors);
    }
}
