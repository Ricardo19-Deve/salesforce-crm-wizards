/**
 * Reads the wizard configuration from Custom Metadata and turns it into what the UI needs.
 *
 *  - Wizard_Record_Type__mdt  -> record types offered in step 1 (+ minimum duplicate score)
 *  - Wizard_Field__mdt        -> fields, labels, pages, sections, columns, required / read-only, lookup filters
 *  - Wizard_Match_Rule__mdt   -> Identify step fields and their weight in the duplicate score
 *
 * Rows are read with getAll() (no SOQL limits) and sorted here: ORDER BY on custom metadata fields is not
 * reliable. Tests can replace the rows through the @TestVisible lists, so they never depend on the sample
 * configuration shipped with the repository.
 */
public with sharing class WizardConfig {
    @TestVisible private static List<Wizard_Record_Type__mdt> recordTypeRows;
    @TestVisible private static List<Wizard_Field__mdt> fieldRows;
    @TestVisible private static List<Wizard_Match_Rule__mdt> matchRuleRows;

    // Record type visibility normally comes from a permission set the running user may not have (e.g. the
    // deployment user while tests run).
    @TestVisible private static Boolean ignoreRecordTypeAvailability = false;

    public static final Integer DEFAULT_MINIMUM_SCORE = 30;

    public class RecordTypeOption {
        @AuraEnabled public Id recordTypeId;
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String description;
        @AuraEnabled public Boolean isDefault;
    }

    public class FieldConfig {
        @AuraEnabled public String key;
        @AuraEnabled public String fieldApiName;
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public Boolean useCustomLabel;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public String section;
        @AuraEnabled public Integer sectionOrder;
        @AuraEnabled public Integer columnNumber;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public Boolean required;
        @AuraEnabled public Boolean readOnly;
        @AuraEnabled public List<Id> lookupRecordTypeIds;
    }

    public class MatchRule {
        @AuraEnabled public String fieldApiName;
        @AuraEnabled public String leadFieldApiName;
        @AuraEnabled public Integer weight;
        @AuraEnabled public Integer sortOrder;
    }

    // ------------------------------------------------------------------ objects and record types

    public static Schema.DescribeSObjectResult describeConfiguredObject(String objectApiName) {
        Schema.SObjectType objectType = String.isBlank(objectApiName)
            ? null
            : Schema.getGlobalDescribe().get(objectApiName.trim().toLowerCase());
        if (objectType == null) {
            throw new WizardException('Unknown object "' + objectApiName + '".');
        }
        Schema.DescribeSObjectResult objectDescribe = objectType.getDescribe();
        if (recordTypeRows(objectDescribe.getName()).isEmpty()) {
            throw new WizardException('The record wizard is not configured for ' + objectDescribe.getName() + '.');
        }
        return objectDescribe;
    }

    // Configured record types that are active and available to the running user, in configured order.
    public static List<RecordTypeOption> availableRecordTypes(Schema.DescribeSObjectResult objectDescribe) {
        Map<String, Schema.RecordTypeInfo> infos = objectDescribe.getRecordTypeInfosByDeveloperName();
        List<Wizard_Record_Type__mdt> rows = new List<Wizard_Record_Type__mdt>();
        Set<String> developerNames = new Set<String>();
        for (Wizard_Record_Type__mdt row : recordTypeRows(objectDescribe.getName())) {
            Schema.RecordTypeInfo info = infos.get(row.Record_Type_Developer_Name__c.trim());
            if (info != null && info.isActive() && (info.isAvailable() || ignoreRecordTypeAvailability)) {
                rows.add(row);
                developerNames.add(info.getDeveloperName());
            }
        }

        Map<String, String> setupDescriptions = new Map<String, String>();
        for (RecordType rt : [
            SELECT DeveloperName, Description
            FROM RecordType
            WHERE SobjectType = :objectDescribe.getName() AND DeveloperName IN :developerNames
        ]) {
            setupDescriptions.put(rt.DeveloperName, rt.Description);
        }

        List<RecordTypeOption> options = new List<RecordTypeOption>();
        for (Wizard_Record_Type__mdt row : rows) {
            Schema.RecordTypeInfo info = infos.get(row.Record_Type_Developer_Name__c.trim());
            RecordTypeOption option = new RecordTypeOption();
            option.recordTypeId = info.getRecordTypeId();
            option.developerName = info.getDeveloperName();
            option.label = info.getName();
            option.description = String.isBlank(row.Description__c)
                ? setupDescriptions.get(info.getDeveloperName())
                : row.Description__c;
            option.isDefault = info.isDefaultRecordTypeMapping();
            options.add(option);
        }
        return options;
    }

    // The record type sent by the browser must be one the wizard offers to this user.
    public static RecordTypeOption requireRecordType(Schema.DescribeSObjectResult objectDescribe, Id recordTypeId) {
        for (RecordTypeOption option : availableRecordTypes(objectDescribe)) {
            if (option.recordTypeId == recordTypeId) {
                return option;
            }
        }
        throw new WizardException('The selected record type is not available in this wizard.');
    }

    public static Integer minimumScore(String objectApiName, String recordTypeDeveloperName) {
        for (Wizard_Record_Type__mdt row : recordTypeRows(objectApiName)) {
            if (row.Record_Type_Developer_Name__c.trim().equalsIgnoreCase(recordTypeDeveloperName)
                && row.Minimum_Match_Score__c != null) {
                return row.Minimum_Match_Score__c.intValue();
            }
        }
        return DEFAULT_MINIMUM_SCORE;
    }

    // ------------------------------------------------------------------ fields

    // recordTypeDeveloperName = null returns only the rows that apply to every record type.
    public static List<FieldConfig> fields(Schema.DescribeSObjectResult objectDescribe, String recordTypeDeveloperName) {
        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();
        List<FieldConfig> output = new List<FieldConfig>();
        for (Wizard_Field__mdt row : fieldRows(objectDescribe.getName(), recordTypeDeveloperName)) {
            Schema.SObjectField field = fieldMap.get(row.Field_Api_Name__c.trim().toLowerCase());
            if (field == null) {
                throw new WizardException(
                    'Wizard Field "' + row.DeveloperName + '" points to "' + row.Field_Api_Name__c +
                    '", which does not exist on ' + objectDescribe.getName() + '.'
                );
            }
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            FieldConfig item = new FieldConfig();
            item.key = row.DeveloperName;
            item.fieldApiName = fieldDescribe.getName();
            item.fieldLabel = row.Field_Label__c;
            item.useCustomLabel = !String.isBlank(row.Field_Label__c);
            item.pageNumber = row.Page__c == null || row.Page__c < 1 ? 1 : row.Page__c.intValue();
            item.section = String.isBlank(row.Section__c) ? 'Information' : row.Section__c.trim();
            item.sectionOrder = row.Section_Order__c == null ? 999 : row.Section_Order__c.intValue();
            item.columnNumber = row.Column__c == 'Right' ? 2 : 1;
            item.sortOrder = row.Sort_Order__c == null ? 999 : row.Sort_Order__c.intValue();
            item.required = row.Required__c == true;
            item.readOnly = row.Read_Only__c == true;
            item.lookupRecordTypeIds = lookupRecordTypeIds(fieldDescribe, row.Lookup_Record_Types__c);
            output.add(item);
        }
        return output;
    }

    // Lookups show "Account" instead of the technical "Account ID".
    public static String displayLabel(Schema.DescribeFieldResult fieldDescribe) {
        String label = fieldDescribe.getLabel();
        return fieldDescribe.getType() == Schema.DisplayType.REFERENCE ? label.removeEnd(' ID') : label;
    }

    // ------------------------------------------------------------------ match rules

    public static List<MatchRule> matchRules(Schema.DescribeSObjectResult objectDescribe) {
        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();
        List<MatchRule> rules = new List<MatchRule>();
        for (Wizard_Match_Rule__mdt row : matchRuleRows()) {
            if (!objectDescribe.getName().equalsIgnoreCase(row.Object_Api_Name__c?.trim())
                || String.isBlank(row.Field_Api_Name__c)
                || !fieldMap.containsKey(row.Field_Api_Name__c.trim().toLowerCase())) {
                continue;
            }
            MatchRule rule = new MatchRule();
            rule.fieldApiName = fieldMap.get(row.Field_Api_Name__c.trim().toLowerCase()).getDescribe().getName();
            rule.leadFieldApiName = String.isBlank(row.Lead_Field_Api_Name__c) ? null : row.Lead_Field_Api_Name__c.trim();
            rule.weight = row.Weight__c == null ? 0 : row.Weight__c.intValue();
            rule.sortOrder = row.Sort_Order__c == null ? 999 : row.Sort_Order__c.intValue();
            rules.add(rule);
        }
        rules.sort(new MatchRuleOrder());
        return rules;
    }

    // ------------------------------------------------------------------ raw rows

    private static List<Wizard_Record_Type__mdt> recordTypeRows(String objectApiName) {
        List<Wizard_Record_Type__mdt> source = recordTypeRows != null
            ? recordTypeRows
            : Wizard_Record_Type__mdt.getAll().values();
        List<Wizard_Record_Type__mdt> rows = new List<Wizard_Record_Type__mdt>();
        for (Wizard_Record_Type__mdt row : source) {
            if (row.Active__c == true
                && objectApiName.equalsIgnoreCase(row.Object_Api_Name__c?.trim())
                && !String.isBlank(row.Record_Type_Developer_Name__c)) {
                rows.add(row);
            }
        }
        rows.sort(new RecordTypeRowOrder());
        return rows;
    }

    private static List<Wizard_Field__mdt> fieldRows(String objectApiName, String recordTypeDeveloperName) {
        List<Wizard_Field__mdt> source = fieldRows != null ? fieldRows : Wizard_Field__mdt.getAll().values();
        List<Wizard_Field__mdt> rows = new List<Wizard_Field__mdt>();
        for (Wizard_Field__mdt row : source) {
            if (row.Active__c != true
                || !objectApiName.equalsIgnoreCase(row.Object_Api_Name__c?.trim())
                || String.isBlank(row.Field_Api_Name__c)) {
                continue;
            }
            Set<String> recordTypes = splitNames(row.Record_Types__c);
            if (recordTypes.isEmpty()
                || (recordTypeDeveloperName != null && recordTypes.contains(recordTypeDeveloperName.toLowerCase()))) {
                rows.add(row);
            }
        }
        rows.sort(new FieldRowOrder());
        return rows;
    }

    private static List<Wizard_Match_Rule__mdt> matchRuleRows() {
        List<Wizard_Match_Rule__mdt> source = matchRuleRows != null
            ? matchRuleRows
            : Wizard_Match_Rule__mdt.getAll().values();
        List<Wizard_Match_Rule__mdt> rows = new List<Wizard_Match_Rule__mdt>();
        for (Wizard_Match_Rule__mdt row : source) {
            if (row.Active__c == true) rows.add(row);
        }
        return rows;
    }

    private static List<Id> lookupRecordTypeIds(Schema.DescribeFieldResult fieldDescribe, String configured) {
        List<Id> ids = new List<Id>();
        Set<String> names = splitNames(configured);
        if (names.isEmpty() || fieldDescribe.getType() != Schema.DisplayType.REFERENCE
            || fieldDescribe.getReferenceTo().isEmpty()) {
            return ids;
        }
        Schema.DescribeSObjectResult target = fieldDescribe.getReferenceTo()[0].getDescribe();
        for (Schema.RecordTypeInfo info : target.getRecordTypeInfos()) {
            if (names.contains(info.getDeveloperName().toLowerCase())) {
                ids.add(info.getRecordTypeId());
            }
        }
        if (ids.isEmpty()) {
            throw new WizardException(
                'None of the record types configured for ' + fieldDescribe.getName() +
                ' (' + configured + ') exist on ' + target.getName() + '.'
            );
        }
        return ids;
    }

    public static Set<String> splitNames(String value) {
        Set<String> names = new Set<String>();
        if (String.isBlank(value)) return names;
        for (String part : value.split(',')) {
            if (!String.isBlank(part)) names.add(part.trim().toLowerCase());
        }
        return names;
    }

    private static String name(String developerName) {
        return developerName == null ? '' : developerName;
    }

    private static Integer orNull(Decimal value) {
        return value == null ? 999 : value.intValue();
    }

    private class RecordTypeRowOrder implements Comparator<Wizard_Record_Type__mdt> {
        public Integer compare(Wizard_Record_Type__mdt a, Wizard_Record_Type__mdt b) {
            Integer byOrder = orNull(a.Sort_Order__c) - orNull(b.Sort_Order__c);
            return byOrder != 0 ? byOrder : name(a.DeveloperName).compareTo(name(b.DeveloperName));
        }
    }

    private class FieldRowOrder implements Comparator<Wizard_Field__mdt> {
        public Integer compare(Wizard_Field__mdt a, Wizard_Field__mdt b) {
            Integer result = (a.Page__c == null ? 1 : a.Page__c.intValue()) - (b.Page__c == null ? 1 : b.Page__c.intValue());
            if (result == 0) result = orNull(a.Section_Order__c) - orNull(b.Section_Order__c);
            if (result == 0) result = orNull(a.Sort_Order__c) - orNull(b.Sort_Order__c);
            return result != 0 ? result : name(a.DeveloperName).compareTo(name(b.DeveloperName));
        }
    }

    private class MatchRuleOrder implements Comparator<MatchRule> {
        public Integer compare(MatchRule a, MatchRule b) {
            return a.sortOrder - b.sortOrder;
        }
    }
}
