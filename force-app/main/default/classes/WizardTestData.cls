/**
 * Test data shared by the wizard tests. Controller tests run against the sample configuration shipped in
 * force-app/main/default/customMetadata (Contact, Campaign and Opportunity); if you change that configuration,
 * adapt the field values used here.
 */
@IsTest
public class WizardTestData {

    public static Id recordTypeId(SObjectType objectType, String developerName) {
        return objectType.getDescribe().getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    // A user with only the given permission sets on top of the Standard User profile.
    public static User userWith(List<String> permissionSetNames) {
        // Profile names are translated into the org language: fall back to any non-admin Salesforce-licence profile.
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        if (profiles.isEmpty()) {
            profiles = [
                SELECT Id FROM Profile
                WHERE UserLicense.Name = 'Salesforce' AND PermissionsModifyAllData = false AND PermissionsViewAllData = false
                ORDER BY CreatedDate LIMIT 1
            ];
        }
        Profile profile = profiles[0];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User u = new User(
            ProfileId = profile.Id,
            LastName = 'Wizard Tester',
            Alias = 'wiztest',
            Email = 'wizard.tester@example.com',
            Username = 'wizard.tester.' + unique + '@example.com',
            TimeZoneSidKey = 'Europe/Lisbon',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
        }
        insert assignments;
        return u;
    }

    public static Account customerAccount(String name, String country) {
        return new Account(
            Name = name,
            BillingCountry = country,
            RecordTypeId = recordTypeId(Account.SObjectType, 'Customer_Account')
        );
    }

    public static Contact customerContact(Id accountId, String firstName, String lastName, String email) {
        return new Contact(
            AccountId = accountId,
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            RecordTypeId = recordTypeId(Contact.SObjectType, 'Customer_Contact')
        );
    }
}
