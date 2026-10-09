/**
 * A sales rep for access tests: a Standard User profile user with only the TurboSign User permission
 * set, so a test that runs as this user sees what a real rep sees, not what the admin running the
 * tests sees. Created once per test and reused; run test data DML inside System.runAs(user()) so the
 * rep owns it.
 */
@IsTest
public class TurboSignTestRep {
    private static User rep;

    public static User user() {
        if (rep != null) return rep;
        Id profileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'TurboSign_User' LIMIT 1].Id;
        String unique = UserInfo.getOrganizationId() + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User u = new User(
            ProfileId = profileId,
            Username = 'turbosign.rep.' + unique + '@example.com',
            Email = 'turbosign.rep@example.com',
            LastName = 'Rep', FirstName = 'TurboSign',
            Alias = 'tsrep',
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        // Setup-object DML in its own runAs, so a test that already inserted records does not hit mixed DML.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = permSetId);
        }
        rep = u;
        return rep;
    }
}
