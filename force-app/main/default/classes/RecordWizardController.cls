/**
 * Server API of the record wizard (LWC recordWizard). Thin layer: checks access, resolves the configured object
 * and record type, delegates to the services and turns WizardException into messages for the user.
 *
 * Flow in the UI: record type -> (Contact) Contact creation / identify -> (records picked) Review values -> form pages
 * (Contact: Accounts list with one principal + Related Accounts) -> Summary -> done.
 * Everything the user sees is configured in Custom Metadata, see WizardConfig.
 *
 * Access: custom permission Use_Record_Wizard (permission set Record_Wizard_User).
 */
public with sharing class RecordWizardController {
    public static final String ACCESS_PERMISSION = 'Use_Record_Wizard';

    public class SaveOutcome {
        @AuraEnabled public Id recordId;
        // Filled when a duplicate rule stopped the save; recordId is then null.
        @AuraEnabled public List<ContactMergeService.RecordSummary> duplicates;
        // True when every matching rule only alerts, so the user may save anyway.
        @AuraEnabled public Boolean canSaveAnyway;
        @AuraEnabled public String message;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean hasWizardAccess() {
        return FeatureManagement.checkPermission(ACCESS_PERMISSION);
    }

    // False when "Contacts to Multiple Accounts" is off: the UI then hides the Related Accounts section.
    @AuraEnabled(cacheable=true)
    public static Boolean supportsRelatedAccounts() {
        return WizardSystemDml.relatedAccountsEnabled();
    }

    @AuraEnabled(cacheable=true)
    public static List<WizardConfig.RecordTypeOption> getRecordTypes(String objectApiName) {
        try {
            return WizardConfig.availableRecordTypes(WizardConfig.describeConfiguredObject(objectApiName));
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<WizardConfig.FieldConfig> getFields(String objectApiName, String recordTypeDeveloperName) {
        try {
            return WizardConfig.fields(WizardConfig.describeConfiguredObject(objectApiName), recordTypeDeveloperName);
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    // Empty list = no Identify step. Only Contact has one (it compares with Contacts and Leads).
    @AuraEnabled(cacheable=true)
    public static List<WizardConfig.MatchRule> getMatchRules(String objectApiName) {
        try {
            Schema.DescribeSObjectResult objectDescribe = WizardConfig.describeConfiguredObject(objectApiName);
            return objectDescribe.getSObjectType() == Contact.SObjectType
                ? WizardConfig.matchRules(objectDescribe)
                : new List<WizardConfig.MatchRule>();
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static ContactMatchService.MatchResult findMatches(Id recordTypeId, String inputsJson) {
        try {
            requireAccess();
            return new ContactMatchService().findMatches(contactRecordType(recordTypeId), WizardFieldWriter.parse(inputsJson));
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static List<ContactMatchService.AccountSuggestion> suggestAccounts(Id recordTypeId, List<String> companies) {
        try {
            requireAccess();
            return new ContactMatchService().suggestAccounts(contactRecordType(recordTypeId), companies);
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    // Names (and city / country for Accounts) of records chosen in record pickers, for the Accounts list and the
    // Summary step. Read in user mode: the user only gets names of records they can already see.
    @AuraEnabled
    public static List<ContactMergeService.RecordSummary> describeRecords(List<Id> recordIds) {
        List<ContactMergeService.RecordSummary> result = new List<ContactMergeService.RecordSummary>();
        if (recordIds == null || recordIds.isEmpty()) return result;
        if (recordIds.size() > 50) {
            throw auraError('Too many records to describe.');
        }
        Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
        for (Id recordId : recordIds) {
            if (recordId == null) continue;
            if (!idsByType.containsKey(recordId.getSObjectType())) idsByType.put(recordId.getSObjectType(), new Set<Id>());
            idsByType.get(recordId.getSObjectType()).add(recordId);
        }
        for (Schema.SObjectType objectType : idsByType.keySet()) {
            Schema.DescribeSObjectResult objectDescribe = objectType.getDescribe();
            if (!objectDescribe.fields.getMap().containsKey('name')) continue;
            Boolean isAccount = objectType == Account.SObjectType;
            for (SObject row : Database.queryWithBinds(
                'SELECT Id, Name' + (isAccount ? ', BillingCity, BillingCountry' : '') + ' FROM ' + objectDescribe.getName() +
                ' WHERE Id IN :ids', new Map<String, Object>{ 'ids' => idsByType.get(objectType) }, AccessLevel.USER_MODE
            )) {
                ContactMergeService.RecordSummary item = new ContactMergeService.RecordSummary();
                item.recordId = row.Id;
                item.recordType = objectDescribe.getName();
                item.name = String.valueOf(row.get('Name'));
                if (isAccount) {
                    item.detail = ContactMatchService.joinParts(
                        new List<String>{ (String) row.get('BillingCity'), (String) row.get('BillingCountry') });
                }
                result.add(item);
            }
        }
        return result;
    }

    // leadIds = Leads to convert into the new Contact; relatedAccountIds = Accounts linked as Related Accounts.
    @AuraEnabled
    public static SaveOutcome createRecord(
        String objectApiName, Id recordTypeId, String fieldsJson, Boolean allowDuplicates,
        List<Id> leadIds, List<Id> relatedAccountIds
    ) {
        Savepoint sp;
        try {
            requireAccess();
            Schema.DescribeSObjectResult objectDescribe = WizardConfig.describeConfiguredObject(objectApiName);
            WizardConfig.RecordTypeOption recordType = WizardConfig.requireRecordType(objectDescribe, recordTypeId);

            SObject record = objectDescribe.getSObjectType().newSObject(recordTypeId, true);
            WizardFieldWriter.apply(
                record, objectDescribe, WizardConfig.fields(objectDescribe, recordType.developerName),
                WizardFieldWriter.parse(fieldsJson), false
            );

            sp = Database.setSavepoint();
            Database.SaveResult result = new WizardSystemDml().insertRecord(record, allowDuplicates == true);
            if (!result.isSuccess()) {
                return duplicateOutcome(result, objectDescribe);
            }
            if (record instanceof Contact) {
                new ContactMergeService().finishContact(record.Id, recordType, leadIds, relatedAccountIds, null, allowDuplicates == true);
            }
            SaveOutcome outcome = new SaveOutcome();
            outcome.recordId = record.Id;
            return outcome;
        } catch (WizardException e) {
            if (sp != null) Database.rollback(sp);
            throw auraError(e);
        } catch (DmlException e) {
            if (sp != null) Database.rollback(sp);
            throw auraError(e.getDmlMessage(0));
        }
    }

    @AuraEnabled
    public static ContactMergeService.MergeData getMergeData(Id recordTypeId, List<Id> contactIds, List<Id> leadIds, String fieldsJson) {
        try {
            requireAccess();
            return new ContactMergeService().getMergeData(
                contactRecordType(recordTypeId), contactIds, leadIds, WizardFieldWriter.parse(fieldsJson)
            );
        } catch (WizardException e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Id mergeContacts(
        Id recordTypeId, Id masterId, List<Id> mergeIds, String valuesJson, List<Id> leadIds, List<Id> relatedAccountIds
    ) {
        try {
            requireAccess();
            return new ContactMergeService().mergeContacts(
                contactRecordType(recordTypeId), masterId, mergeIds, WizardFieldWriter.parse(valuesJson), leadIds, relatedAccountIds
            );
        } catch (WizardException e) {
            throw auraError(e);
        } catch (DmlException e) {
            throw auraError(e.getDmlMessage(0));
        }
    }

    // Duplicate rules are reported like the standard New page; any other error is thrown.
    private static SaveOutcome duplicateOutcome(Database.SaveResult result, Schema.DescribeSObjectResult objectDescribe) {
        SaveOutcome outcome = new SaveOutcome();
        outcome.duplicates = new List<ContactMergeService.RecordSummary>();
        outcome.canSaveAnyway = true;
        Set<Id> ids = new Set<Id>();
        for (Database.Error error : result.getErrors()) {
            if (!(error instanceof Database.DuplicateError)) {
                throw new WizardException(error.getMessage());
            }
            Datacloud.DuplicateResult duplicateResult = ((Database.DuplicateError) error).getDuplicateResult();
            outcome.canSaveAnyway = outcome.canSaveAnyway && duplicateResult.isAllowSave();
            outcome.message = duplicateResult.getErrorMessage();
            for (Datacloud.MatchResult matchResult : duplicateResult.getMatchResults()) {
                for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                    ids.add(matchRecord.getRecord().Id);
                }
            }
        }
        Boolean isContact = objectDescribe.getSObjectType() == Contact.SObjectType;
        String query = 'SELECT Id, Name' + (isContact ? ', Email, Account.Name' : '') +
            ' FROM ' + objectDescribe.getName() + ' WHERE Id IN :ids';
        for (SObject match : new WizardSystemDml().query(query, new Map<String, Object>{ 'ids' => ids })) {
            ContactMergeService.RecordSummary item = new ContactMergeService.RecordSummary();
            item.recordId = match.Id;
            item.recordType = objectDescribe.getName();
            item.name = String.valueOf(match.get('Name'));
            if (isContact) {
                Contact c = (Contact) match;
                item.detail = ContactMatchService.joinParts(new List<String>{ c.Email, c.Account?.Name });
            }
            outcome.duplicates.add(item);
        }
        return outcome;
    }

    private static WizardConfig.RecordTypeOption contactRecordType(Id recordTypeId) {
        return WizardConfig.requireRecordType(WizardConfig.describeConfiguredObject('Contact'), recordTypeId);
    }

    private static void requireAccess() {
        if (!hasWizardAccess()) {
            throw new WizardException('You do not have access to this wizard. Ask your administrator for the Record Wizard User permission set.');
        }
    }

    private static AuraHandledException auraError(Exception e) {
        return auraError(e.getMessage());
    }

    // setMessage() makes the text readable in Apex tests too; the LWC receives it either way.
    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
