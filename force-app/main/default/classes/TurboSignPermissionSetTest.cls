/**
 * Locks the permission-set contract the README promises: TurboSign User alone is enough for a rep
 * to send, and cannot be used to forge which TurboDocx document a void or reminder hits.
 */
@IsTest
private class TurboSignPermissionSetTest {
    private static Id permSetId(String name) {
        return [SELECT Id FROM PermissionSet WHERE Name = :name LIMIT 1].Id;
    }

    private static Integer classAccess(String permSet, String className) {
        Id cls = [SELECT Id FROM ApexClass WHERE Name = :className LIMIT 1].Id;
        return [SELECT COUNT() FROM SetupEntityAccess WHERE ParentId = :permSetId(permSet) AND SetupEntityId = :cls];
    }

    // Access tests run as TurboSignTestRep.user(), so it must be a real rep: not the admin running the
    // tests, a Standard User profile, and TurboSign User as its only TurboSign access.
    @IsTest
    static void testRepIsAStandardUserWithTheUserPermissionSet() {
        User rep = TurboSignTestRep.user();
        System.assertNotEquals(UserInfo.getUserId(), rep.Id, 'not the admin running the tests');
        System.assertEquals('Standard User', [SELECT Profile.Name FROM User WHERE Id = :rep.Id].Profile.Name);
        System.assertEquals(1, [SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId = :rep.Id AND PermissionSet.Name = 'TurboSign_User'], 'TurboSign User assigned');
        System.assertEquals(0, [SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId = :rep.Id AND PermissionSet.Name = 'TurboSign_Admin'], 'no admin set');
        System.assertEquals(rep.Id, TurboSignTestRep.user().Id, 'reused within a test');
    }

    @IsTest
    static void repSetGrantsTheRepClassesButNotTheAdminController() {
        System.assertEquals(1, classAccess('TurboSign_User', 'TurboSignQuickActionController'), 'send modal + panel');
        System.assertEquals(1, classAccess('TurboSign_User', 'TurboSignRecipientSync'), 'panel Refresh syncs recipients');
        System.assertEquals(1, classAccess('TurboSign_Admin', 'TurboSignRecipientSync'), 'admins refresh too');
        System.assertEquals(0, classAccess('TurboSign_User', 'TurboSignConfigController'),
            'reps never get the admin controller (template list/render callouts under the org key)');
    }

    @IsTest
    static void repSetCannotEditTheTurboDocxDocumentId() {
        List<FieldPermissions> fp = [SELECT PermissionsEdit FROM FieldPermissions
            WHERE ParentId = :permSetId('TurboSign_User')
            AND Field = 'TurboSign_Envelope__c.TurboDocx_Document_Id__c'];
        System.assert(fp.isEmpty() || !fp[0].PermissionsEdit,
            'reps must not point an envelope at another TurboDocx document before void/remind');
        List<FieldPermissions> rel = [SELECT PermissionsEdit FROM FieldPermissions
            WHERE ParentId = :permSetId('TurboSign_User') AND Field = 'TurboSign_Envelope__c.Related_Record_Id__c'];
        System.assert(rel.isEmpty() || !rel[0].PermissionsEdit, 'reps must not repoint an envelope at another record');
    }

    @IsTest
    static void bothSetsGrantUserExternalCredentialRead() {
        for (String ps : new List<String>{ 'TurboSign_User', 'TurboSign_Admin' }) {
            System.assertEquals(1, [SELECT COUNT() FROM ObjectPermissions
                WHERE ParentId = :permSetId(ps) AND SobjectType = 'UserExternalCredential'
                AND PermissionsRead = true], ps + ' needs UserExternalCredential read to call out');
        }
    }
}
