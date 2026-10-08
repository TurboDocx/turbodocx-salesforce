/** Shared helpers for the TurboSign Flow actions. */
public with sharing class TurboSignActionUtil {
    public static Map<Id, String> docIdsForEnvelopes(Set<Id> envIds) {
        Map<Id, String> m = new Map<Id, String>();
        for (TurboSign_Envelope__c e : [SELECT Id, TurboDocx_Document_Id__c
                                        FROM TurboSign_Envelope__c WHERE Id IN :envIds WITH USER_MODE]) {
            m.put(e.Id, e.TurboDocx_Document_Id__c);
        }
        return m;
    }

    /**
     * Remind and void call TurboDocx with the org's shared key, so check the caller can edit the record
     * each envelope belongs to (or the envelope itself when it has none). Envelope sharing alone isn't
     * enough: the envelope object is ReadWrite while the Opportunity may be Private.
     */
    public static void requireEditAccess(Set<Id> envIds) {
        Map<Id, Id> targetByEnv = new Map<Id, Id>();
        for (TurboSign_Envelope__c e : [SELECT Id, Related_Record_Id__c FROM TurboSign_Envelope__c WHERE Id IN :envIds WITH USER_MODE]) {
            Id target = e.Id;
            if (String.isNotBlank(e.Related_Record_Id__c)) {
                try { target = Id.valueOf(e.Related_Record_Id__c); } catch (Exception ex) { target = null; }
            }
            targetByEnv.put(e.Id, target);
        }
        Set<Id> editable = new Set<Id>();
        Set<Id> targets = new Set<Id>(targetByEnv.values());
        targets.remove(null);
        if (!targets.isEmpty()) {
            for (UserRecordAccess a : [SELECT RecordId, HasEditAccess FROM UserRecordAccess
                                       WHERE UserId = :UserInfo.getUserId() AND RecordId IN :targets WITH USER_MODE]) {
                if (a.HasEditAccess) editable.add(a.RecordId);
            }
        }
        for (Id envId : envIds) {
            Id target = targetByEnv.get(envId);
            if (target == null || !editable.contains(target)) {
                String msg = 'You do not have access to the record this envelope belongs to.';
                AuraHandledException ex = new AuraHandledException(msg);
                ex.setMessage(msg);
                throw ex;
            }
        }
    }
}
