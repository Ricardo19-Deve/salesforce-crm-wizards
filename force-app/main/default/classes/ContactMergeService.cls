/**
 * Review and save steps of the Contact wizard when the user picked existing records in the Identify step.
 *
 *  - getMergeData: field-by-field comparison between what the user typed, up to 3 Contacts and any number of
 *    Leads. Lead values are mapped to Contact fields with the standard conversion mapping plus custom fields
 *    with the same API name. Only fields whose values differ become rows.
 *  - mergeContacts: updates the Contact to keep with the chosen values, merges the others into it, converts the
 *    chosen Leads into it and links secondary Accounts as Related Accounts. One savepoint: all or nothing.
 *  - finishContact: lead conversion + Related Accounts, also used after a brand-new Contact is created.
 */
public with sharing class ContactMergeService {
    public static final Integer MAX_CONTACTS = 3;

    public class RecordSummary {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordType;
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
    }

    public class MergeData {
        @AuraEnabled public List<RecordSummary> records;
        @AuraEnabled public List<MergeRow> rows;
        @AuraEnabled public Integer identicalCount;
    }

    public class MergeRow {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public List<MergeCell> cells;
    }

    public class MergeCell {
        // 'form' for the value typed in the wizard, otherwise the Contact or Lead Id.
        @AuraEnabled public String source;
        @AuraEnabled public Object value;
        @AuraEnabled public String display;
    }

    // Standard Lead -> Contact conversion mapping. Custom fields are matched by identical API name.
    private static final Map<String, String> STANDARD_LEAD_TO_CONTACT = new Map<String, String>{
        'Salutation' => 'Salutation', 'FirstName' => 'FirstName', 'MiddleName' => 'MiddleName',
        'LastName' => 'LastName', 'Suffix' => 'Suffix', 'Title' => 'Title', 'Email' => 'Email',
        'Phone' => 'Phone', 'MobilePhone' => 'MobilePhone', 'Fax' => 'Fax', 'Description' => 'Description',
        'DoNotCall' => 'DoNotCall', 'HasOptedOutOfEmail' => 'HasOptedOutOfEmail', 'HasOptedOutOfFax' => 'HasOptedOutOfFax',
        'Street' => 'MailingStreet', 'City' => 'MailingCity', 'State' => 'MailingState',
        'PostalCode' => 'MailingPostalCode', 'Country' => 'MailingCountry'
    };

    private final WizardSystemDml dml = new WizardSystemDml();

    public MergeData getMergeData(
        WizardConfig.RecordTypeOption recordType, List<Id> contactIds, List<Id> leadIds, Map<String, Object> formValues
    ) {
        contactIds = contactIds == null ? new List<Id>() : contactIds;
        leadIds = leadIds == null ? new List<Id>() : leadIds;
        if (contactIds.size() > MAX_CONTACTS) {
            throw new WizardException('Select at most ' + MAX_CONTACTS + ' Contacts to merge.');
        }
        if (contactIds.isEmpty() && leadIds.isEmpty()) {
            throw new WizardException('Select at least one Contact or Lead.');
        }
        Schema.DescribeSObjectResult contactDescribe = Contact.SObjectType.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = contactDescribe.fields.getMap();
        List<WizardConfig.FieldConfig> configs = WizardConfig.fields(contactDescribe, recordType.developerName);

        Set<String> contactSelect = new Set<String>{ 'Id', 'Name', 'Email', 'Account.Name' };
        for (WizardConfig.FieldConfig config : configs) {
            contactSelect.add(config.fieldApiName);
        }
        Map<Id, SObject> contacts = new Map<Id, SObject>(contactIds.isEmpty() ? new List<SObject>() : dml.query(
            'SELECT ' + String.join(new List<String>(contactSelect), ', ') + ' FROM Contact WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => contactIds }
        ));

        Map<String, String> leadFieldByContactField = new Map<String, String>();
        Map<String, String> mapping = leadToContactMapping();
        for (String leadField : mapping.keySet()) {
            leadFieldByContactField.put(mapping.get(leadField).toLowerCase(), leadField);
        }
        Set<String> leadSelect = new Set<String>{ 'Id', 'Name', 'Email', 'Company' };
        for (WizardConfig.FieldConfig config : configs) {
            String leadField = leadFieldByContactField.get(config.fieldApiName.toLowerCase());
            if (leadField != null) leadSelect.add(leadField);
        }
        Map<Id, SObject> leads = new Map<Id, SObject>(leadIds.isEmpty() ? new List<SObject>() : dml.query(
            'SELECT ' + String.join(new List<String>(leadSelect), ', ') + ' FROM Lead WHERE Id IN :ids AND IsConverted = false',
            new Map<String, Object>{ 'ids' => leadIds }
        ));
        Map<String, Account> companyAccounts = new ContactMatchService().companyAccounts((List<Lead>) leads.values(), recordType);

        Set<Id> extraAccountIds = new Set<Id>();
        for (Account acc : companyAccounts.values()) extraAccountIds.add(acc.Id);
        Map<Id, String> referenceNames = referenceNames(configs, fieldMap, contacts.values(), formValues, extraAccountIds);

        MergeData data = new MergeData();
        data.records = new List<RecordSummary>();
        for (Id contactId : contactIds) {
            Contact c = (Contact) contacts.get(contactId);
            if (c == null) {
                throw new WizardException('One of the selected Contacts no longer exists.');
            }
            data.records.add(summary(c.Id, 'Contact', c.Name, ContactMatchService.joinParts(new List<String>{ c.Email, c.Account?.Name })));
        }
        for (Id leadId : leadIds) {
            Lead l = (Lead) leads.get(leadId);
            if (l == null) {
                throw new WizardException('One of the selected Leads no longer exists or was already converted.');
            }
            data.records.add(summary(l.Id, 'Lead', l.Name, ContactMatchService.joinParts(new List<String>{ l.Email, l.Company })));
        }

        data.rows = new List<MergeRow>();
        data.identicalCount = 0;
        for (WizardConfig.FieldConfig config : configs) {
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(config.fieldApiName.toLowerCase()).getDescribe();
            if (config.readOnly || fieldDescribe.isCalculated()) {
                continue;
            }
            MergeRow row = new MergeRow();
            row.apiName = fieldDescribe.getName();
            row.label = WizardFieldWriter.labelOf(config, fieldDescribe);
            row.cells = new List<MergeCell>();
            row.cells.add(cell('form', formValues.get(row.apiName.toLowerCase()), fieldDescribe, referenceNames));
            for (Id contactId : contactIds) {
                row.cells.add(cell(contactId, contacts.get(contactId).get(row.apiName), fieldDescribe, referenceNames));
            }
            String leadField = leadFieldByContactField.get(row.apiName.toLowerCase());
            for (Id leadId : leadIds) {
                Lead l = (Lead) leads.get(leadId);
                Object value = null;
                if (row.apiName == 'AccountId') {
                    Account companyAccount = l.Company == null ? null : companyAccounts.get(l.Company.trim().toLowerCase());
                    value = companyAccount?.Id;
                } else if (leadField != null) {
                    value = l.get(leadField);
                }
                row.cells.add(cell(leadId, value, fieldDescribe, referenceNames));
            }
            Set<String> distinct = new Set<String>();
            for (MergeCell c : row.cells) {
                distinct.add(c.display == null ? '' : c.display.toLowerCase());
            }
            if (distinct.size() > 1) {
                data.rows.add(row);
            } else {
                data.identicalCount++;
            }
        }
        return data;
    }

    public Id mergeContacts(
        WizardConfig.RecordTypeOption recordType, Id masterId, List<Id> mergeIds, Map<String, Object> values,
        List<Id> leadIds, List<Id> relatedAccountIds
    ) {
        List<Id> others = new List<Id>();
        for (Id contactId : mergeIds == null ? new List<Id>() : mergeIds) {
            if (contactId != masterId && !others.contains(contactId)) {
                others.add(contactId);
            }
        }
        if (masterId == null || others.size() > MAX_CONTACTS - 1) {
            throw new WizardException('Select the Contact to keep and at most ' + (MAX_CONTACTS - 1) + ' other Contacts to merge into it.');
        }
        Schema.DescribeSObjectResult contactDescribe = Contact.SObjectType.getDescribe();
        Contact master = new Contact(Id = masterId);
        WizardFieldWriter.apply(master, contactDescribe, WizardConfig.fields(contactDescribe, recordType.developerName), values, true);

        Savepoint sp = Database.setSavepoint();
        try {
            Set<Id> mergedAccounts = new Set<Id>();
            if (!others.isEmpty()) {
                for (SObject c : dml.query('SELECT AccountId FROM Contact WHERE Id IN :ids', new Map<String, Object>{ 'ids' => others })) {
                    mergedAccounts.add((Id) c.get('AccountId'));
                }
            }
            dml.updateReviewedRecord(master);
            if (!others.isEmpty()) {
                dml.mergeContacts(masterId, others);
            }
            // The Accounts of the merged Contacts stay as Related Accounts of the surviving Contact.
            finishContact(master.Id, recordType, leadIds, relatedAccountIds, mergedAccounts, true);
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
        return masterId;
    }

    // relatedAccountIds = the Accounts the user kept in the list (the principal one excluded). They come from the
    // browser, so they must be eligible Accounts; trustedAccountIds (Accounts of the merged Contacts) skip that check.
    // Only the Accounts in the list are linked: the user may remove an Account of a merged Contact.
    public void finishContact(
        Id contactId, WizardConfig.RecordTypeOption recordType, List<Id> leadIds, List<Id> relatedAccountIds,
        Set<Id> trustedAccountIds, Boolean allowDuplicates
    ) {
        Contact saved = (Contact) dml.query('SELECT Id, AccountId FROM Contact WHERE Id = :contactId',
            new Map<String, Object>{ 'contactId' => contactId })[0];
        dml.convertLeadsInto(saved.Id, saved.AccountId, leadIds, allowDuplicates);

        Set<Id> accounts = relatedAccountIds == null ? new Set<Id>() : new Set<Id>(relatedAccountIds);
        accounts.remove(saved.AccountId);
        accounts.remove(null);
        Set<Id> toValidate = new Set<Id>(accounts);
        if (trustedAccountIds != null) toValidate.removeAll(trustedAccountIds);
        Set<Id> allowed = ContactMatchService.allowedAccountRecordTypes(recordType);
        if (!allowed.isEmpty() && !toValidate.isEmpty()) {
            Integer valid = dml.query('SELECT Id FROM Account WHERE Id IN :ids AND RecordTypeId IN :allowed',
                new Map<String, Object>{ 'ids' => toValidate, 'allowed' => allowed }).size();
            if (valid != toValidate.size()) {
                throw new WizardException('One of the related Accounts is not allowed in this wizard.');
            }
        }
        dml.linkAccounts(saved.Id, accounts);
    }

    @TestVisible
    private static Map<String, String> leadToContactMapping() {
        Map<String, Schema.SObjectField> leadFields = Lead.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> contactFields = Contact.SObjectType.getDescribe().fields.getMap();
        Map<String, String> mapping = new Map<String, String>();
        for (String leadField : STANDARD_LEAD_TO_CONTACT.keySet()) {
            if (leadFields.containsKey(leadField.toLowerCase())) {
                mapping.put(leadField, STANDARD_LEAD_TO_CONTACT.get(leadField));
            }
        }
        for (Schema.SObjectField field : leadFields.values()) {
            Schema.DescribeFieldResult leadDescribe = field.getDescribe();
            Schema.SObjectField target = contactFields.get(leadDescribe.getName().toLowerCase());
            if (!leadDescribe.isCustom() || target == null) {
                continue;
            }
            Schema.DescribeFieldResult contactDescribe = target.getDescribe();
            if (contactDescribe.getType() == leadDescribe.getType() && !contactDescribe.isCalculated()) {
                mapping.put(leadDescribe.getName(), contactDescribe.getName());
            }
        }
        return mapping;
    }

    private static RecordSummary summary(Id recordId, String recordType, String name, String detail) {
        RecordSummary item = new RecordSummary();
        item.recordId = recordId;
        item.recordType = recordType;
        item.name = name;
        item.detail = detail;
        return item;
    }

    private static MergeCell cell(String source, Object raw, Schema.DescribeFieldResult fieldDescribe, Map<Id, String> referenceNames) {
        MergeCell c = new MergeCell();
        c.source = source;
        Boolean blank = raw == null || String.isBlank(String.valueOf(raw));
        Schema.DisplayType fieldType = fieldDescribe.getType();
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            Boolean checked = !blank && Boolean.valueOf(String.valueOf(raw));
            c.value = checked;
            c.display = checked ? 'Yes' : 'No';
            return c;
        }
        if (blank) {
            return c;
        }
        c.value = raw;
        String text = String.valueOf(raw);
        if (fieldType == Schema.DisplayType.REFERENCE) {
            c.display = referenceNames.containsKey((Id) text) ? referenceNames.get((Id) text) : text;
        } else if (fieldType == Schema.DisplayType.MULTIPICKLIST) {
            List<String> parts = text.split(';');
            parts.sort();
            c.display = String.join(parts, '; ');
        } else if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.CURRENCY
            || fieldType == Schema.DisplayType.PERCENT || fieldType == Schema.DisplayType.INTEGER) {
            c.display = Decimal.valueOf(text).stripTrailingZeros().toPlainString();
        } else {
            c.display = text;
        }
        return c;
    }

    // Names of every record referenced by a lookup cell, one query per target object.
    private Map<Id, String> referenceNames(
        List<WizardConfig.FieldConfig> configs, Map<String, Schema.SObjectField> fieldMap, List<SObject> records,
        Map<String, Object> formValues, Set<Id> extraAccountIds
    ) {
        Map<String, Set<Id>> idsByObject = new Map<String, Set<Id>>();
        for (WizardConfig.FieldConfig config : configs) {
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(config.fieldApiName.toLowerCase()).getDescribe();
            if (fieldDescribe.getType() != Schema.DisplayType.REFERENCE || fieldDescribe.getReferenceTo().isEmpty()) {
                continue;
            }
            String target = fieldDescribe.getReferenceTo()[0].getDescribe().getName();
            if (!idsByObject.containsKey(target)) {
                idsByObject.put(target, new Set<Id>());
            }
            Object formValue = formValues.get(config.fieldApiName.toLowerCase());
            if (formValue instanceof String && !String.isBlank((String) formValue)) {
                idsByObject.get(target).add(Id.valueOf((String) formValue));
            }
            for (SObject record : records) {
                Object value = record.get(fieldDescribe.getName());
                if (value != null) {
                    idsByObject.get(target).add((Id) value);
                }
            }
        }
        if (!extraAccountIds.isEmpty()) {
            if (!idsByObject.containsKey('Account')) idsByObject.put('Account', new Set<Id>());
            idsByObject.get('Account').addAll(extraAccountIds);
        }
        Map<Id, String> names = new Map<Id, String>();
        for (String target : idsByObject.keySet()) {
            if (idsByObject.get(target).isEmpty()) {
                continue;
            }
            for (SObject record : dml.query(
                'SELECT Id, Name FROM ' + target + ' WHERE Id IN :ids', new Map<String, Object>{ 'ids' => idsByObject.get(target) }
            )) {
                names.put(record.Id, String.valueOf(record.get('Name')));
            }
        }
        return names;
    }
}
