/**
 * The only place where the wizards read and write in system mode.
 *
 * Why: the wizards serve users who may not have Create/Edit on the object, and duplicate candidates or Leads
 * may be owned by other users or queues. Access is controlled before reaching this class:
 *  - the custom permission checked by the controllers (Use_Record_Wizard / Use_Opportunity_Wizard);
 *  - the configured field list in Wizard_Field__mdt, the only fields WizardFieldWriter will set.
 * Keep it that way: never call this class with field values that did not go through WizardFieldWriter.
 */
public without sharing class WizardSystemDml {

    public List<SObject> query(String soql, Map<String, Object> binds) {
        return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
    }

    // allowDuplicates = the user confirmed "Save anyway" for duplicate rules whose action is Allow.
    public Database.SaveResult insertRecord(SObject record, Boolean allowDuplicates) {
        Database.DMLOptions options = duplicateOptions(allowDuplicates);
        options.OptAllOrNone = false;
        return Database.insert(record, options, AccessLevel.SYSTEM_MODE);
    }

    public void insertRecords(List<SObject> records) {
        Database.insert(records, AccessLevel.SYSTEM_MODE);
    }

    // The user already reviewed the duplicates, so Allow-type duplicate rules must not stop the update.
    public void updateReviewedRecord(SObject record) {
        Database.SaveResult result = Database.update(record, duplicateOptions(true), AccessLevel.SYSTEM_MODE);
        if (!result.isSuccess()) {
            throw new WizardException(result.getErrors()[0].getMessage());
        }
    }

    public void mergeContacts(Id masterId, List<Id> duplicateIds) {
        for (Database.MergeResult result : Database.merge(new Contact(Id = masterId), duplicateIds, false)) {
            if (!result.isSuccess()) {
                throw new WizardException(result.getErrors()[0].getMessage());
            }
        }
    }

    // AccountContactRelation only exists when "Contacts to Multiple Accounts" is enabled in Setup. It is used
    // dynamically so the project also deploys to orgs without the feature (Related Accounts are then skipped).
    public static Boolean relatedAccountsEnabled() {
        return Schema.getGlobalDescribe().containsKey('accountcontactrelation');
    }

    // Indirect Account-Contact relationships ("Related Accounts"); existing ones are kept as they are.
    public void linkAccounts(Id contactId, Set<Id> accountIds) {
        if (accountIds.isEmpty() || !relatedAccountsEnabled()) return;
        Set<Id> existing = new Set<Id>();
        for (SObject relation : query(
            'SELECT AccountId FROM AccountContactRelation WHERE ContactId = :contactId AND AccountId IN :accountIds',
            new Map<String, Object>{ 'contactId' => contactId, 'accountIds' => accountIds }
        )) {
            existing.add((Id) relation.get('AccountId'));
        }
        Schema.SObjectType relationType = Schema.getGlobalDescribe().get('AccountContactRelation');
        List<SObject> relations = new List<SObject>();
        for (Id accountId : accountIds) {
            if (!existing.contains(accountId)) {
                SObject relation = relationType.newSObject();
                relation.put('AccountId', accountId);
                relation.put('ContactId', contactId);
                relations.add(relation);
            }
        }
        if (!relations.isEmpty()) {
            Database.insert(relations, AccessLevel.SYSTEM_MODE);
        }
    }

    // Each Lead record type can have its own sales process, so not every converted status is valid for every
    // Lead: the converted statuses are tried in order until each Lead converts.
    public void convertLeadsInto(Id contactId, Id accountId, List<Id> leadIds, Boolean allowDuplicates) {
        if (leadIds == null || leadIds.isEmpty()) {
            return;
        }
        Database.DMLOptions options = duplicateOptions(allowDuplicates);
        options.OptAllOrNone = false;
        List<Id> pending = new List<Id>(new Set<Id>(leadIds));
        String lastError;
        for (LeadStatus status : [SELECT ApiName FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
            for (Id leadId : pending) {
                Database.LeadConvert convert = new Database.LeadConvert();
                convert.setLeadId(leadId);
                convert.setContactId(contactId);
                convert.setAccountId(accountId);
                convert.setDoNotCreateOpportunity(true);
                convert.setConvertedStatus(status.ApiName);
                convert.setOwnerId(UserInfo.getUserId());
                converts.add(convert);
            }
            List<Id> stillPending = new List<Id>();
            List<Database.LeadConvertResult> results = Database.convertLead(converts, options);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    stillPending.add(pending[i]);
                    lastError = results[i].getErrors()[0].getMessage();
                }
            }
            pending = stillPending;
            if (pending.isEmpty()) {
                return;
            }
        }
        throw new WizardException('A selected Lead could not be converted: ' + lastError);
    }

    private static Database.DMLOptions duplicateOptions(Boolean allowSave) {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = allowSave == true;
        options.DuplicateRuleHeader.runAsCurrentUser = true;
        return options;
    }
}
