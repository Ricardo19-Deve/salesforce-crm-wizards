/**
 * Copies values sent by the browser onto an SObject, but only for the fields configured in Wizard_Field__mdt.
 *
 * This is the security boundary of the wizards: the DML runs in system mode (WizardSystemDml), so a field
 * that is not configured is silently ignored, read-only / formula / auto-number fields are never written and
 * lookups restricted to some record types are checked again on the server (the record picker filter lives in
 * the browser and can be bypassed).
 */
public with sharing class WizardFieldWriter {

    // JSON object from the LWC -> map keyed by lowercase field API name.
    public static Map<String, Object> parse(String fieldsJson) {
        Map<String, Object> raw = String.isBlank(fieldsJson)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(fieldsJson);
        Map<String, Object> byLowerName = new Map<String, Object>();
        for (String key : raw.keySet()) {
            byLowerName.put(key.toLowerCase(), raw.get(key));
        }
        return byLowerName;
    }

    // clearBlanks = blank values are written as null (merge: the user chose an empty value).
    public static void apply(
        SObject record,
        Schema.DescribeSObjectResult objectDescribe,
        List<WizardConfig.FieldConfig> configs,
        Map<String, Object> valuesByLowerName,
        Boolean clearBlanks
    ) {
        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();
        for (WizardConfig.FieldConfig config : configs) {
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(config.fieldApiName.toLowerCase()).getDescribe();
            String key = config.fieldApiName.toLowerCase();
            Object raw = valuesByLowerName.get(key);
            Boolean blank = raw == null || String.isBlank(String.valueOf(raw));

            // On update only the reviewed fields are sent; required values already live on the record.
            if (config.required && blank && (!clearBlanks || valuesByLowerName.containsKey(key))) {
                throw new WizardException(labelOf(config, fieldDescribe) + ' is required.');
            }
            if (config.readOnly || fieldDescribe.isCalculated() || fieldDescribe.isAutoNumber()) {
                continue;
            }
            if (blank) {
                if (clearBlanks && valuesByLowerName.containsKey(key)) {
                    record.put(fieldDescribe.getName(), fieldDescribe.getType() == Schema.DisplayType.BOOLEAN ? (Object) false : null);
                }
                continue;
            }

            Object value = coerce(fieldDescribe, raw);
            if (!config.lookupRecordTypeIds.isEmpty()) {
                assertLookupRecordType(fieldDescribe, (Id) value, config.lookupRecordTypeIds);
            }
            record.put(fieldDescribe.getName(), value);
        }
    }

    // JSON gives strings, numbers and booleans; the SObject needs the field's Apex type.
    public static Object coerce(Schema.DescribeFieldResult fieldDescribe, Object raw) {
        String text = String.valueOf(raw);
        Schema.DisplayType fieldType = fieldDescribe.getType();
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            return Boolean.valueOf(text);
        }
        if (fieldType == Schema.DisplayType.DATE) {
            return Date.valueOf(text);
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            return (Datetime) JSON.deserialize('"' + text + '"', Datetime.class);
        }
        if (fieldType == Schema.DisplayType.CURRENCY || fieldType == Schema.DisplayType.DOUBLE
            || fieldType == Schema.DisplayType.PERCENT) {
            return Decimal.valueOf(text);
        }
        if (fieldType == Schema.DisplayType.INTEGER) {
            return Integer.valueOf(text);
        }
        if (fieldType == Schema.DisplayType.REFERENCE) {
            return Id.valueOf(text);
        }
        return raw;
    }

    public static String labelOf(WizardConfig.FieldConfig config, Schema.DescribeFieldResult fieldDescribe) {
        return config.useCustomLabel ? config.fieldLabel : WizardConfig.displayLabel(fieldDescribe);
    }

    private static void assertLookupRecordType(Schema.DescribeFieldResult fieldDescribe, Id value, List<Id> allowed) {
        String target = fieldDescribe.getReferenceTo()[0].getDescribe().getName();
        Map<String, Object> binds = new Map<String, Object>{ 'value' => value, 'allowed' => allowed };
        Integer matches = new WizardSystemDml().query(
            'SELECT Id FROM ' + String.escapeSingleQuotes(target) + ' WHERE Id = :value AND RecordTypeId IN :allowed',
            binds
        ).size();
        if (matches == 0) {
            throw new WizardException('The selected ' + fieldDescribe.getLabel().removeEnd(' ID') + ' is not allowed in this wizard.');
        }
    }
}
