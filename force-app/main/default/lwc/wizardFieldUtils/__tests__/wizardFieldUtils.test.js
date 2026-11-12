import {
    buildSections,
    hasValue,
    payload,
    picklistOptions,
    recordTypeFilter,
    reduceError,
    resolveField
} from 'c/wizardFieldUtils';

const OBJECT_INFO = {
    fields: {
        LastName: { label: 'Last Name', dataType: 'String', required: true, length: 80 },
        AccountId: { label: 'Account ID', dataType: 'Reference', referenceToInfos: [{ apiName: 'Account' }] },
        Amount: { label: 'Amount', dataType: 'Currency', scale: 2 },
        Region__c: { label: 'Region', dataType: 'Picklist' },
        City__c: { label: 'City', dataType: 'Picklist', controllerName: 'Region__c' },
        HasOptedOutOfEmail: { label: 'Email Opt Out', dataType: 'Boolean', required: true }
    }
};

const row = (fieldApiName, extra = {}) => ({
    key: fieldApiName,
    fieldApiName,
    pageNumber: 1,
    section: 'Main',
    sectionOrder: 10,
    columnNumber: 1,
    sortOrder: 10,
    ...extra
});

describe('resolveField', () => {
    it('skips fields the user cannot read', () => {
        expect(resolveField(row('Secret__c'), OBJECT_INFO)).toBeNull();
    });

    it('uses the custom label and the record type filter of lookups', () => {
        const field = resolveField(row('AccountId', { lookupRecordTypeIds: ['012000000000001'] }), OBJECT_INFO);
        expect(field.isLookup).toBe(true);
        expect(field.displayLabel).toBe('Account');
        expect(field.lookupObject).toBe('Account');
        expect(field.lookupFilter.criteria[0].value).toEqual(['012000000000001']);

        const custom = resolveField(row('LastName', { useCustomLabel: true, fieldLabel: 'Surname' }), OBJECT_INFO);
        expect(custom.displayLabel).toBe('Surname');
        expect(custom.required).toBe(true);
    });

    it('maps numbers and checkboxes', () => {
        const amount = resolveField(row('Amount'), OBJECT_INFO);
        expect(amount.inputType).toBe('number');
        expect(amount.inputStep).toBe('0.01');
        const optOut = resolveField(row('HasOptedOutOfEmail'), OBJECT_INFO);
        expect(optOut.isCheckbox).toBe(true);
        expect(optOut.required).toBe(false);
    });
});

describe('picklistOptions', () => {
    const picklists = {
        City__c: {
            controllerValues: { North: 0, South: 1 },
            values: [
                { label: 'Porto', value: 'Porto', validFor: [0] },
                { label: 'Faro', value: 'Faro', validFor: [1] }
            ]
        }
    };
    const city = resolveField(row('City__c'), OBJECT_INFO);

    it('blocks a dependent picklist until the controller has a value', () => {
        expect(picklistOptions(city, picklists, {})).toEqual({ options: [], blocked: true });
    });

    it('filters the dependent values', () => {
        expect(picklistOptions(city, picklists, { Region__c: 'South' }).options).toEqual([{ label: 'Faro', value: 'Faro' }]);
    });
});

describe('buildSections and payload', () => {
    it('groups by section and column and sends only filled values', () => {
        const fields = [
            resolveField(row('LastName', { sortOrder: 20 }), OBJECT_INFO),
            resolveField(row('Amount', { sortOrder: 10 }), OBJECT_INFO),
            resolveField(row('AccountId', { columnNumber: 2, section: 'Other', sectionOrder: 5 }), OBJECT_INFO)
        ];
        const sections = buildSections(fields, 1, { picklistValues: {}, fieldValues: {}, objectInfo: OBJECT_INFO });
        expect(sections.map((s) => s.name)).toEqual(['Other', 'Main']);
        expect(sections[1].columns[0].fields.map((f) => f.apiName)).toEqual(['Amount', 'LastName']);
        expect(sections[0].columns[1].fields[0].apiName).toBe('AccountId');

        expect(payload(fields, { LastName: 'Silva', Amount: '', AccountId: null })).toEqual({ LastName: 'Silva' });
    });

    it('joins multi-select values', () => {
        expect(payload([{ apiName: 'Tags__c' }], { Tags__c: ['A', 'B'] })).toEqual({ Tags__c: 'A;B' });
        expect(hasValue([])).toBe(false);
        expect(hasValue(0)).toBe(true);
    });
});

describe('helpers', () => {
    it('builds no filter without record types', () => {
        expect(recordTypeFilter([])).toBeUndefined();
    });

    it('reads Apex and UI API errors', () => {
        expect(reduceError({ body: { message: 'Apex says no' } })).toBe('Apex says no');
        expect(reduceError({ body: [{ message: 'a' }, { message: 'b' }] })).toBe('a b');
        expect(reduceError(new Error('plain'))).toBe('plain');
        expect(reduceError(undefined)).toBe('An unexpected error occurred.');
    });
});
