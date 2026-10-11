/** Shared helpers for the TurboSign Flow actions. */
public with sharing class TurboSignActionUtil {
    public static final String NO_ENVELOPE_EDIT = 'You do not have permission to edit this envelope.';
    public static final String NO_VOID_FIELDS = 'You do not have permission to void this envelope.';

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
        Set<Id> targets = new Set<Id>(targetByEnv.values());
        targets.remove(null);
        Set<Id> editable = editableRecords(targets);
        for (Id envId : envIds) {
            Id target = targetByEnv.get(envId);
            if (target == null || !editable.contains(target)) {
                throw refusal('You do not have access to the record this envelope belongs to.');
            }
        }
    }

    /** A voided envelope, as both the panel and the Flow action write it. */
    public static TurboSign_Envelope__c voided(Id envelopeId, String reason) {
        return new TurboSign_Envelope__c(Id = envelopeId, Status__c = 'voided',
            Voided_On__c = System.now(), Void_Reason__c = reason, Sync_Active__c = false);
    }

    /**
     * Void calls TurboDocx and then writes the envelope as the user, so check first that the write will
     * succeed: the user can edit the record each envelope belongs to, the envelope itself (envelope
     * sharing may be Private), and the fields a void writes. Otherwise the document would end up void in
     * TurboDocx and 'sent' in Salesforce.
     */
    public static void requireVoidAccess(Set<Id> envIds) {
        requireEditAccess(envIds);
        Set<Id> editable = editableRecords(envIds);
        for (Id envId : envIds) {
            if (!editable.contains(envId)) throw refusal(NO_ENVELOPE_EDIT);
        }
        if (!Security.stripInaccessible(AccessType.UPDATABLE, new List<SObject>{ voided(null, null) })
                .getRemovedFields().isEmpty()) {
            throw refusal(NO_VOID_FIELDS);
        }
    }

    /** The records in ids the running user can edit (sharing and object permissions). */
    private static Set<Id> editableRecords(Set<Id> ids) {
        Set<Id> editable = new Set<Id>();
        if (ids.isEmpty()) return editable;
        for (UserRecordAccess a : [SELECT RecordId, HasEditAccess FROM UserRecordAccess
                                   WHERE UserId = :UserInfo.getUserId() AND RecordId IN :ids WITH USER_MODE]) {
            if (a.HasEditAccess) editable.add(a.RecordId);
        }
        return editable;
    }

    private static AuraHandledException refusal(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
