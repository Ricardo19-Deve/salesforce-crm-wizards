@IsTest
private class RecordWizardControllerTest {
    // What the user typed in the Identify step: matches both Ana Silva Contacts and the Lead.
    private static final String IDENTIFY = JSON.serialize(new Map<String, Object>{
        'Email' => 'ana.silva@example.com', 'LastName' => 'Silva', 'FirstName' => 'Ana'
    });

    @TestSetup
    static void setup() {
        Account acme = WizardTestData.customerAccount('Northwind Traders', 'Portugal');
        Account other = WizardTestData.customerAccount('Contoso Ltd', 'Spain');
        Account partner = new Account(Name = 'Partner Co', RecordTypeId = WizardTestData.recordTypeId(Account.SObjectType, 'Partner_Account'));
        insert new List<Account>{ acme, other, partner };

        insert new List<Contact>{
            WizardTestData.customerContact(acme.Id, 'Ana', 'Silva', 'ana.silva@example.com'),
            WizardTestData.customerContact(other.Id, 'Ana', 'Silva', 'ana.s@example.com')
        };
        insert new Lead(FirstName = 'Ana', LastName = 'Silva', Email = 'ana.silva@example.com', Company = 'Contoso Ltd');

        System.runAs(new User(Id = UserInfo.getUserId())) {
            WizardTestData.userWith(new List<String>{ 'Record_Wizard_User' });
        }
    }

    private static User wizardUser() {
        return [SELECT Id FROM User WHERE LastName = 'Wizard Tester' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Id customerContactType() {
        return WizardTestData.recordTypeId(Contact.SObjectType, 'Customer_Contact');
    }

    private static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    @IsTest
    static void configurationIsServedToTheUi() {
        System.runAs(wizardUser()) {
            Assert.isTrue(RecordWizardController.hasWizardAccess());
            Assert.areEqual(2, RecordWizardController.getRecordTypes('Contact').size());
            Assert.isFalse(RecordWizardController.getFields('Contact', 'Customer_Contact').isEmpty());
            Assert.isFalse(RecordWizardController.getMatchRules('Contact').isEmpty());
            Assert.isTrue(RecordWizardController.getMatchRules('Campaign').isEmpty(), 'Only Contact has an Identify step');
            Assert.isNotNull(RecordWizardController.supportsRelatedAccounts());
        }
    }

    @IsTest
    static void usersWithoutThePermissionCannotSave() {
        User noAccess = WizardTestData.userWith(new List<String>());
        System.runAs(noAccess) {
            try {
                RecordWizardController.createRecord('Contact', customerContactType(), '{}', false, null, null, null);
                Assert.fail('Users without Use_Record_Wizard must be rejected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('do not have access'));
            }
        }
    }

    @IsTest
    static void identifyScoresContactsAndLeads() {
        System.runAs(wizardUser()) {
            ContactMatchService.MatchResult result = RecordWizardController.findMatches(
                customerContactType(),
                JSON.serialize(new Map<String, Object>{ 'Email' => 'ANA.SILVA@example.com', 'LastName' => 'silva', 'FirstName' => 'Ana' })
            );
            Assert.areEqual(3, result.candidates.size(), 'Two Contacts and one Lead');
            Assert.areEqual(100, result.candidates[0].score, 'Email + names = capped at 100');
            Set<String> types = new Set<String>();
            for (ContactMatchService.MatchCandidate c : result.candidates) types.add(c.recordType);
            Assert.isTrue(types.contains('Lead'));

            List<ContactMatchService.AccountSuggestion> suggestions =
                RecordWizardController.suggestAccounts(customerContactType(), new List<String>{ 'Contoso' });
            Assert.areEqual(1, suggestions.size(), 'Partner accounts are not suggested for customer contacts');
        }
    }

    @IsTest
    static void createContactConvertsChosenLead() {
        Id leadId = [SELECT Id FROM Lead LIMIT 1].Id;
        Map<String, Object> fields = new Map<String, Object>{
            'LastName' => 'Costa', 'FirstName' => 'Rui', 'Email' => 'rui.costa@example.com',
            'AccountId' => accountId('Northwind Traders'), 'Preferred_Language__c' => 'Portuguese'
        };
        RecordWizardController.SaveOutcome outcome;
        Test.startTest();
        System.runAs(wizardUser()) {
            outcome = RecordWizardController.createRecord(
                'Contact', customerContactType(), JSON.serialize(fields), true,
                new List<Id>{ leadId }, new List<Id>{ accountId('Contoso Ltd') }, IDENTIFY
            );
        }
        Test.stopTest();

        Contact created = [SELECT LastName, Preferred_Language__c FROM Contact WHERE Id = :outcome.recordId];
        Assert.areEqual('Portuguese', created.Preferred_Language__c);
        Lead converted = [SELECT IsConverted, ConvertedContactId FROM Lead WHERE Id = :leadId];
        Assert.isTrue(converted.IsConverted);
        Assert.areEqual(outcome.recordId, converted.ConvertedContactId);
    }

    @IsTest
    static void lookupRecordTypeIsEnforcedOnTheServer() {
        Map<String, Object> fields = new Map<String, Object>{
            'LastName' => 'Costa', 'Email' => 'rui@example.com', 'AccountId' => accountId('Partner Co')
        };
        System.runAs(wizardUser()) {
            try {
                RecordWizardController.createRecord('Contact', customerContactType(), JSON.serialize(fields), true, null, null, null);
                Assert.fail('Partner accounts are not allowed for customer contacts');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not allowed'));
            }
        }
    }

    @IsTest
    static void requiredFieldsAreChecked() {
        System.runAs(wizardUser()) {
            try {
                RecordWizardController.createRecord('Contact', customerContactType(), '{"FirstName":"Only"}', false, null, null, null);
                Assert.fail('Last Name is required');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('required'));
            }
        }
    }

    @IsTest
    static void duplicatesAreReportedOrSaved() {
        Map<String, Object> fields = new Map<String, Object>{
            'LastName' => 'Silva', 'FirstName' => 'Ana', 'Email' => 'ana.silva@example.com', 'AccountId' => accountId('Northwind Traders')
        };
        System.runAs(wizardUser()) {
            RecordWizardController.SaveOutcome first = RecordWizardController.createRecord(
                'Contact', customerContactType(), JSON.serialize(fields), false, null, null, null);
            if (first.duplicates != null) {
                // An active duplicate rule found the existing Ana Silva: the user can review it or save anyway.
                Assert.isFalse(first.duplicates.isEmpty());
                if (first.canSaveAnyway) {
                    RecordWizardController.SaveOutcome second = RecordWizardController.createRecord(
                        'Contact', customerContactType(), JSON.serialize(fields), true, null, null, null);
                    Assert.isNotNull(second.recordId);
                }
            } else {
                Assert.isNotNull(first.recordId, 'No active duplicate rule in this org');
            }
        }
    }

    @IsTest
    static void reviewAndMergeContacts() {
        List<Contact> contacts = [SELECT Id, AccountId FROM Contact ORDER BY Email];
        Id keep = contacts[1].Id;      // ana.silva@example.com
        Id other = contacts[0].Id;     // ana.s@example.com
        Id leadId = [SELECT Id FROM Lead LIMIT 1].Id;

        Test.startTest();
        System.runAs(wizardUser()) {
            ContactMergeService.MergeData data = RecordWizardController.getMergeData(
                customerContactType(), new List<Id>{ keep, other }, new List<Id>{ leadId },
                JSON.serialize(new Map<String, Object>{ 'LastName' => 'Silva', 'Email' => 'ana.silva@example.com' }),
                IDENTIFY
            );
            Assert.areEqual(3, data.records.size());
            Assert.isFalse(data.rows.isEmpty(), 'Email and Account differ between the records');

            RecordWizardController.mergeContacts(
                customerContactType(), keep, new List<Id>{ keep, other },
                JSON.serialize(new Map<String, Object>{ 'Email' => 'ana.silva@example.com', 'Title' => '' }),
                new List<Id>{ leadId }, null, IDENTIFY
            );
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE Id IN (:keep, :other)], 'The other Contact was merged');
        Assert.areEqual(keep, [SELECT ConvertedContactId FROM Lead WHERE Id = :leadId].ConvertedContactId);
    }

    @IsTest
    static void mergeLimitsAreEnforced() {
        System.runAs(wizardUser()) {
            try {
                RecordWizardController.getMergeData(customerContactType(), new List<Id>(), new List<Id>(), '{}', null);
                Assert.fail('Nothing selected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('at least one'));
            }
            try {
                RecordWizardController.mergeContacts(customerContactType(), null, null, '{}', null, null, null);
                Assert.fail('The Contact to keep is required');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Contact to keep'));
            }
        }
    }

    @IsTest
    static void campaignNameIsBuiltByTheFlow() {
        Id eventType = WizardTestData.recordTypeId(Campaign.SObjectType, 'Event_Campaign');
        Map<String, Object> fields = new Map<String, Object>{
            'Region__c' => 'North', 'Name_Suffix__c' => 'Spring Summit', 'StartDate' => '2027-03-10'
        };
        RecordWizardController.SaveOutcome outcome;
        System.runAs(wizardUser()) {
            outcome = RecordWizardController.createRecord('Campaign', eventType, JSON.serialize(fields), false, null, null, null);
        }
        Assert.areEqual('North-2027-Spring Summit', [SELECT Name FROM Campaign WHERE Id = :outcome.recordId].Name);
    }

    @IsTest
    static void configurationErrorsReachTheUser() {
        List<String> messages = new List<String>();
        try { RecordWizardController.getRecordTypes('Case'); } catch (AuraHandledException e) { messages.add(e.getMessage()); }
        try { RecordWizardController.getFields('Case', null); } catch (AuraHandledException e) { messages.add(e.getMessage()); }
        try { RecordWizardController.getMatchRules('Case'); } catch (AuraHandledException e) { messages.add(e.getMessage()); }
        System.runAs(wizardUser()) {
            try { RecordWizardController.findMatches(null, '{}'); } catch (AuraHandledException e) { messages.add(e.getMessage()); }
            try { RecordWizardController.suggestAccounts(null, null); } catch (AuraHandledException e) { messages.add(e.getMessage()); }
        }
        Assert.areEqual(5, messages.size());
        Assert.isTrue(messages[0].contains('not configured'));
        Assert.isTrue(messages[3].contains('not available'));
    }

    @IsTest
    static void identifyWithoutSearchValuesReturnsNothing() {
        System.runAs(wizardUser()) {
            ContactMatchService.MatchResult result = RecordWizardController.findMatches(customerContactType(), '{"FirstName":"Ana"}');
            Assert.isTrue(result.candidates.isEmpty(), 'First Name alone is not a search filter');
            Assert.isTrue(RecordWizardController.suggestAccounts(customerContactType(), new List<String>{ 'ab' }).isEmpty());
        }
    }

    @IsTest
    static void describeRecordsReturnsNamesAndPlace() {
        Id acmeId = accountId('Northwind Traders');
        List<ContactMergeService.RecordSummary> rows = RecordWizardController.describeRecords(new List<Id>{ acmeId, null });
        Assert.areEqual(1, rows.size());
        Assert.areEqual('Northwind Traders', rows[0].name);
        Assert.areEqual('Portugal', rows[0].detail);
        Assert.isTrue(RecordWizardController.describeRecords(null).isEmpty());
        List<Id> tooMany = new List<Id>();
        for (Integer i = 0; i < 51; i++) tooMany.add(acmeId);
        try {
            RecordWizardController.describeRecords(tooMany);
            Assert.fail('More than 50 records are rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Too many'));
        }
    }

    @IsTest
    static void billingAddressFillsTheMailingFields() {
        Account acc = WizardTestData.customerAccount('Address Account', 'Portugal');
        acc.BillingStreet = '1 Main Street';
        acc.BillingCity = 'Lisbon';
        acc.BillingPostalCode = '1000-001';
        insert acc;
        System.runAs(wizardUser()) {
            Map<String, String> address = RecordWizardController.getAccountBillingAddress(acc.Id);
            Assert.areEqual('1 Main Street', address.get('MailingStreet'));
            Assert.areEqual('Lisbon', address.get('MailingCity'));
            Assert.areEqual('Portugal', address.get('MailingCountry'));
            Assert.isTrue(RecordWizardController.getAccountBillingAddress(null).isEmpty());
        }
    }

    @IsTest
    static void matchingHelpers() {
        Assert.isTrue(ContactMatchService.variants('ana silva').contains('Ana Silva'));
        Assert.isTrue(ContactMatchService.sameValue('+351 912 000 001', '351912000001'));
        Assert.isFalse(ContactMatchService.sameValue('123', '0123'));
        Assert.isFalse(ContactMatchService.sameValue(null, 'x'));
        Assert.areEqual('MailingCity', ContactMergeService.leadToContactMapping().get('City'));
        Assert.areEqual('Preferred_Language__c', ContactMergeService.leadToContactMapping().get('Preferred_Language__c'));
    }

    @IsTest
    static void recordsTheUserCannotOpenAreShownWithoutDetails() {
        Contact hidden = [SELECT Id FROM Contact WHERE Email = 'ana.silva@example.com' LIMIT 1];
        ContactMatchService.unreadableForTest = new Set<Id>{ hidden.Id };
        System.runAs(wizardUser()) {
            ContactMatchService.MatchResult result = RecordWizardController.findMatches(customerContactType(), IDENTIFY);
            Boolean found = false;
            for (ContactMatchService.MatchCandidate c : result.candidates) {
                if (c.recordId != hidden.Id) continue;
                found = true;
                Assert.isTrue(c.restricted);
                Assert.areEqual('a•••@e•••.com', c.email, 'Email masked');
                Assert.isNull(c.accountName, 'Account hidden');
                Assert.areEqual('Ana Silva', c.name, 'The name stays, to recognise the duplicate');
            }
            Assert.isTrue(found, 'Restricted duplicates are still reported');
        }
    }

    @IsTest
    static void onlyGenuineDuplicatesOfOthersCanBeMerged() {
        List<Contact> contacts = [SELECT Id FROM Contact ORDER BY Email];
        Id keep = contacts[1].Id;      // ana.silva@example.com
        Id other = contacts[0].Id;     // ana.s@example.com
        ContactMatchService.unreadableForTest = new Set<Id>{ keep, other };
        System.runAs(wizardUser()) {
            String unrelated = JSON.serialize(new Map<String, Object>{ 'Email' => 'someone.else@example.com', 'LastName' => 'Costa' });
            try {
                RecordWizardController.mergeContacts(customerContactType(), keep, new List<Id>{ keep, other }, '{}', null, null, unrelated);
                Assert.fail('Records the user cannot open must be genuine duplicates of what was typed');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not a duplicate'));
            }
            try {
                RecordWizardController.getMergeData(customerContactType(), new List<Id>{ keep }, null, '{}', null);
                Assert.fail('Without Identify values, only records the user can open are accepted');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not a duplicate'));
            }
            ContactMergeService.MergeData data = RecordWizardController.getMergeData(
                customerContactType(), new List<Id>{ keep, other }, null, '{}', IDENTIFY);
            Assert.areEqual(2, data.records.size(), 'Genuine duplicates owned by others stay mergeable');
        }
    }

    @IsTest
    static void maskedEmailKeepsOnlyInitials() {
        Assert.areEqual('a•••@n•••.com', ContactMatchService.maskEmail('ana.silva@northwind.com'));
        Assert.isNull(ContactMatchService.maskEmail('not-an-email'));
        Assert.isNull(ContactMatchService.maskEmail(null));
    }
}
