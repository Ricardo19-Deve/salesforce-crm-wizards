@IsTest
private class WizardConfigTest {

    // In-memory custom metadata rows: the tests below never depend on the shipped sample configuration.
    private static void useConfig() {
        WizardConfig.recordTypeRows = new List<Wizard_Record_Type__mdt>{
            new Wizard_Record_Type__mdt(DeveloperName = 'B', Object_Api_Name__c = 'Contact', Record_Type_Developer_Name__c = 'Partner_Contact',
                Sort_Order__c = 20, Active__c = true),
            new Wizard_Record_Type__mdt(DeveloperName = 'A', Object_Api_Name__c = 'Contact', Record_Type_Developer_Name__c = 'Customer_Contact',
                Sort_Order__c = 10, Minimum_Match_Score__c = 45, Description__c = 'Custom description', Active__c = true),
            new Wizard_Record_Type__mdt(DeveloperName = 'C', Object_Api_Name__c = 'Contact', Record_Type_Developer_Name__c = 'Does_Not_Exist',
                Active__c = true)
        };
        WizardConfig.fieldRows = new List<Wizard_Field__mdt>{
            new Wizard_Field__mdt(DeveloperName = 'Email', Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'Email',
                Page__c = 1, Section__c = 'Main', Section_Order__c = 10, Sort_Order__c = 20, Required__c = true, Active__c = true),
            new Wizard_Field__mdt(DeveloperName = 'LastName', Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'LastName',
                Page__c = 1, Section__c = 'Main', Section_Order__c = 10, Sort_Order__c = 10, Field_Label__c = 'Surname', Active__c = true),
            new Wizard_Field__mdt(DeveloperName = 'Account', Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'AccountId',
                Record_Types__c = 'Customer_Contact', Lookup_Record_Types__c = 'Customer_Account', Column__c = 'Right', Active__c = true),
            new Wizard_Field__mdt(DeveloperName = 'Inactive', Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'Title', Active__c = false)
        };
        WizardConfig.matchRuleRows = new List<Wizard_Match_Rule__mdt>{
            new Wizard_Match_Rule__mdt(Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'LastName', Weight__c = 30, Sort_Order__c = 20, Active__c = true),
            new Wizard_Match_Rule__mdt(Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'Email', Lead_Field_Api_Name__c = 'Email',
                Weight__c = 60, Sort_Order__c = 10, Active__c = true),
            new Wizard_Match_Rule__mdt(Object_Api_Name__c = 'Contact', Field_Api_Name__c = 'Unknown__c', Weight__c = 99, Active__c = true)
        };
        WizardConfig.ignoreRecordTypeAvailability = true;
    }

    @IsTest
    static void recordTypesAreFilteredAndSorted() {
        useConfig();
        List<WizardConfig.RecordTypeOption> options =
            WizardConfig.availableRecordTypes(WizardConfig.describeConfiguredObject('Contact'));

        Assert.areEqual(2, options.size(), 'Unknown record types are skipped');
        Assert.areEqual('Customer_Contact', options[0].developerName, 'Sorted by Sort Order');
        Assert.areEqual('Custom description', options[0].description);
        Assert.areEqual(45, WizardConfig.minimumScore('Contact', 'Customer_Contact'));
        Assert.areEqual(WizardConfig.DEFAULT_MINIMUM_SCORE, WizardConfig.minimumScore('Contact', 'Partner_Contact'));
    }

    @IsTest
    static void fieldsFollowRecordTypeAndOrder() {
        useConfig();
        Schema.DescribeSObjectResult contactDescribe = Contact.SObjectType.getDescribe();

        List<WizardConfig.FieldConfig> customer = WizardConfig.fields(contactDescribe, 'Customer_Contact');
        Assert.areEqual(3, customer.size());
        Assert.areEqual('LastName', customer[0].fieldApiName, 'Sorted by Sort Order inside the section');
        Assert.isTrue(customer[0].useCustomLabel);
        Assert.areEqual('Surname', customer[0].fieldLabel);
        Assert.areEqual(2, customer[2].columnNumber);
        Assert.areEqual(1, customer[2].lookupRecordTypeIds.size());

        Assert.areEqual(2, WizardConfig.fields(contactDescribe, 'Partner_Contact').size(), 'AccountId row is Customer only');
        Assert.areEqual(2, WizardConfig.fields(contactDescribe, null).size(), 'null = rows for every record type');
    }

    @IsTest
    static void matchRulesSkipUnknownFields() {
        useConfig();
        List<WizardConfig.MatchRule> rules = WizardConfig.matchRules(Contact.SObjectType.getDescribe());
        Assert.areEqual(2, rules.size());
        Assert.areEqual('Email', rules[0].fieldApiName);
        Assert.areEqual('Email', rules[0].leadFieldApiName);
        Assert.isNull(rules[1].leadFieldApiName);
    }

    @IsTest
    static void configurationErrorsAreExplained() {
        useConfig();
        WizardConfig.fieldRows.add(new Wizard_Field__mdt(DeveloperName = 'Broken', Object_Api_Name__c = 'Contact',
            Field_Api_Name__c = 'Missing_Field__c', Active__c = true));
        try {
            WizardConfig.fields(Contact.SObjectType.getDescribe(), null);
            Assert.fail('A missing field must be reported');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('Missing_Field__c'));
        }
        try {
            WizardConfig.describeConfiguredObject('Case');
            Assert.fail('Objects without configuration are rejected');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('not configured'));
        }
        try {
            WizardConfig.describeConfiguredObject('NotAnObject__x');
            Assert.fail('Unknown objects are rejected');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('Unknown object'));
        }
        try {
            WizardConfig.requireRecordType(Contact.SObjectType.getDescribe(), null);
            Assert.fail('Record types outside the wizard are rejected');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('not available'));
        }
    }

    @IsTest
    static void lookupRecordTypesMustExist() {
        useConfig();
        WizardConfig.fieldRows[2].Lookup_Record_Types__c = 'No_Such_Type';
        try {
            WizardConfig.fields(Contact.SObjectType.getDescribe(), 'Customer_Contact');
            Assert.fail('Unknown lookup record types must be reported');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('No_Such_Type'));
        }
    }

    @IsTest
    static void fieldWriterCoercesTypes() {
        Map<String, Schema.SObjectField> fields = Opportunity.SObjectType.getDescribe().fields.getMap();
        Assert.areEqual(Date.newInstance(2030, 1, 31), WizardFieldWriter.coerce(fields.get('closedate').getDescribe(), '2030-01-31'));
        Assert.areEqual(12.5, WizardFieldWriter.coerce(fields.get('amount').getDescribe(), '12.5'));
        Assert.areEqual(true, WizardFieldWriter.coerce(fields.get('isprivate').getDescribe(), 'true'));
        Assert.isNotNull(WizardFieldWriter.coerce(Event.SObjectType.getDescribe().fields.getMap().get('activitydatetime').getDescribe(),
            '2030-01-31T10:00:00.000Z'));
        Assert.areEqual('text', WizardFieldWriter.coerce(fields.get('name').getDescribe(), 'text'));
    }
}
