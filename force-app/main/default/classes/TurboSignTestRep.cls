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
        Id profileId = standardUserProfileId();
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

    /**
     * The Standard User profile, found by what it is rather than by name: the name is translated for a
     * user or an org in another language. It is the standard Salesforce-license profile for internal
     * users that is not an admin and not one of the other standard profiles (Contract Manager, Marketing
     * User, Solution Manager, Minimum Access, and Read Only, which can't edit tasks).
     */
    public static Id standardUserProfileId() {
        return [SELECT ProfileId FROM PermissionSet
            WHERE IsOwnedByProfile = true AND IsCustom = false
            AND Profile.UserType = 'Standard' AND Profile.UserLicense.LicenseDefinitionKey = 'SFDC'
            AND PermissionsModifyAllData = false AND PermissionsViewAllData = false
            AND PermissionsApiEnabled = true AND PermissionsEditTask = true AND PermissionsActivateContract = false
            AND PermissionsImportLeads = false AND PermissionsManageSolutions = false
            LIMIT 1].ProfileId;
    }
}
