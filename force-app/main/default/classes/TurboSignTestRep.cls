/**
 * The running test user with the TurboSign User permission set, as a rep has it. A package build org's
 * admin has no access to the package's fields, and an assignment only applies inside System.runAs.
 */
@IsTest
public class TurboSignTestRep {
    public static User user() {
        Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'TurboSign_User'].Id;
        User me = new User(Id = UserInfo.getUserId());
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :me.Id AND PermissionSetId = :ps] == 0) {
            System.runAs(me) { insert new PermissionSetAssignment(AssigneeId = me.Id, PermissionSetId = ps); }
        }
        return me;
    }
}
