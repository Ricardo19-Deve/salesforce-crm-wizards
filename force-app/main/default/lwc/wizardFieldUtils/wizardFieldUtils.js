/**
 * Pure helpers shared by recordWizard and opportunityWizard: turn a Wizard_Field__mdt row (FieldConfig from Apex)
 * plus the UI API object info into a field descriptor that c-wizard-field-input can render.
 */

// Fields the user cannot read are not returned by the UI API and are skipped (null).
export function resolveField(row, objectInfo) {
    const info = objectInfo?.fields?.[row.fieldApiName];
    if (!info) return null;

    const dataType = String(info.dataType || '');
    const isPicklist = dataType === 'Picklist';
    const isMultiPicklist = dataType === 'MultiPicklist';
    const isLookup = dataType === 'Reference';
    const isCheckbox = dataType === 'Boolean';
    const isTextarea = dataType === 'TextArea';
    const isInput = !isPicklist && !isMultiPicklist && !isLookup && !isCheckbox && !isTextarea;

    return {
        key: row.key,
        apiName: row.fieldApiName,
        pageNumber: row.pageNumber || 1,
        displayLabel: row.useCustomLabel ? row.fieldLabel : isLookup ? String(info.label).replace(/ ID$/, '') : info.label,
        section: row.section,
        sectionOrder: row.sectionOrder,
        columnNumber: row.columnNumber,
        sortOrder: row.sortOrder,
        required: Boolean(row.required || (info.required && !isCheckbox)),
        disabled: Boolean(row.readOnly || info.calculated),
        isPicklist,
        isMultiPicklist,
        isLookup,
        isCheckbox,
        isTextarea,
        isInput,
        controllerName: info.controllerName || null,
        lookupObject: isLookup ? info.referenceToInfos?.[0]?.apiName : undefined,
        lookupFilter: recordTypeFilter(row.lookupRecordTypeIds),
        maxLength: info.length || undefined,
        ...inputPresentation(dataType, info)
    };
}

// lightning-record-picker filter limiting a lookup to some record types (checked again in Apex).
export function recordTypeFilter(recordTypeIds) {
    return recordTypeIds?.length
        ? { criteria: [{ fieldPath: 'RecordTypeId', operator: 'in', value: recordTypeIds }] }
        : undefined;
}

export function inputPresentation(dataType, info) {
    switch (dataType) {
        case 'Date':
            return { inputType: 'date' };
        case 'DateTime':
            return { inputType: 'datetime' };
        case 'Email':
            return { inputType: 'email' };
        case 'Phone':
            return { inputType: 'tel' };
        case 'Url':
            return { inputType: 'url' };
        case 'Int':
            return { inputType: 'number', inputStep: '1' };
        case 'Double':
        case 'Currency':
        case 'Percent': {
            const scale = Number(info?.scale || 0);
            return {
                inputType: 'number',
                inputStep: scale > 0 ? `0.${'0'.repeat(scale - 1)}1` : '1',
                inputFormatter: dataType === 'Percent' ? 'percent-fixed' : undefined
            };
        }
        default:
            return { inputType: 'text' };
    }
}

// Options of a (dependent) picklist for the current values. blocked = the controlling field is still empty.
export function picklistOptions(field, picklistValues, fieldValues) {
    const picklist = picklistValues?.[field.apiName];
    if (!picklist) return { options: [], blocked: false };
    let values = picklist.values || [];
    let blocked = false;
    if (field.controllerName && Object.keys(picklist.controllerValues || {}).length) {
        const controllerValue = fieldValues[field.controllerName];
        const index = controllerValue === undefined || controllerValue === null
            ? undefined
            : picklist.controllerValues[String(controllerValue)];
        if (index === undefined) {
            values = [];
            blocked = true;
        } else {
            values = values.filter((item) => (item.validFor || []).includes(index));
        }
    }
    return { options: values.map((item) => ({ label: item.label, value: item.value })), blocked };
}

// Field descriptor + current value, ready for c-wizard-field-input.
export function decorateField(field, { picklistValues, fieldValues, objectInfo }) {
    const raw = fieldValues[field.apiName];
    const decorated = { ...field, value: raw ?? null, checked: raw === true };
    if (field.isPicklist || field.isMultiPicklist) {
        const { options, blocked } = picklistOptions(field, picklistValues, fieldValues);
        decorated.options = options;
        decorated.disabled = field.disabled || blocked;
        const controllerLabel = objectInfo?.fields?.[field.controllerName]?.label || field.controllerName;
        decorated.placeholder = blocked ? `Select ${controllerLabel} first` : '--None--';
        decorated.value = field.isMultiPicklist
            ? (Array.isArray(raw) ? raw : String(raw || '').split(';').filter(Boolean))
            : (raw ?? '');
    }
    return decorated;
}

// Groups the fields of one page into sections with a left and a right column.
export function buildSections(fields, page, context) {
    const groups = new Map();
    fields.forEach((field) => {
        if (page !== undefined && field.pageNumber !== page) return;
        if (!groups.has(field.section)) {
            groups.set(field.section, { name: field.section, order: field.sectionOrder, left: [], right: [] });
        }
        const group = groups.get(field.section);
        const decorated = decorateField(field, context);
        if (field.columnNumber === 2) group.right.push(decorated);
        else group.left.push(decorated);
    });
    return Array.from(groups.values())
        .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name))
        .map((group) => ({
            name: group.name,
            columns: [
                { key: 'left', fields: group.left.sort((a, b) => a.sortOrder - b.sortOrder) },
                { key: 'right', fields: group.right.sort((a, b) => a.sortOrder - b.sortOrder) }
            ]
        }));
}

export function hasValue(raw) {
    return Array.isArray(raw) ? raw.length > 0 : raw !== undefined && raw !== null && raw !== '';
}

// Values to send to Apex: only filled fields, multi-select joined with ';'.
export function payload(fields, fieldValues) {
    const result = {};
    for (const field of fields) {
        const raw = fieldValues[field.apiName];
        if (hasValue(raw)) {
            result[field.apiName] = Array.isArray(raw) ? raw.join(';') : raw;
        }
    }
    return result;
}

export function reduceError(error) {
    if (!error) return 'An unexpected error occurred.';
    if (typeof error === 'string') return error;
    if (error.body?.message) return error.body.message;
    if (Array.isArray(error.body)) return error.body.map((item) => item.message).join(' ');
    if (error.message) return error.message;
    return 'An unexpected error occurred.';
}
