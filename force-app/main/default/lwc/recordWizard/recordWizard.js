/**
 * Record wizard UI (Contact and Campaign out of the box, any object configured in Wizard_Record_Type__mdt).
 * Open it with /lightning/cmp/c__recordWizard?c__object=Contact&c__session=<anything unique>
 * (list buttons Wizard_New_Contact / Wizard_New_Campaign do this).
 *
 * Steps: record type -> identify (Contact: search as you type, tick up to 3 Contacts to merge and Leads to
 * convert) -> review values (pick the value to keep per field) -> form pages -> done.
 * Server: RecordWizardController. Field rendering is generic: picklists (incl. dependent), multi-select, lookups
 * with record type filters, checkboxes, dates, numbers. Wire results are kept on reset for the same object:
 * wires do not provision again with unchanged parameters, clearing them would leave an endless spinner.
 */
import { LightningElement, wire } from 'lwc';
import { getObjectInfo, getPicklistValuesByRecordType } from 'lightning/uiObjectInfoApi';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { buildSections, hasValue, payload, recordTypeFilter, reduceError, resolveField } from 'c/wizardFieldUtils';
import hasWizardAccess from '@salesforce/apex/RecordWizardController.hasWizardAccess';
import getRecordTypes from '@salesforce/apex/RecordWizardController.getRecordTypes';
import getFields from '@salesforce/apex/RecordWizardController.getFields';
import getMatchRules from '@salesforce/apex/RecordWizardController.getMatchRules';
import findMatches from '@salesforce/apex/RecordWizardController.findMatches';
import suggestAccounts from '@salesforce/apex/RecordWizardController.suggestAccounts';
import createRecord from '@salesforce/apex/RecordWizardController.createRecord';
import getMergeData from '@salesforce/apex/RecordWizardController.getMergeData';
import mergeContacts from '@salesforce/apex/RecordWizardController.mergeContacts';
import supportsRelatedAccounts from '@salesforce/apex/RecordWizardController.supportsRelatedAccounts';

const STEP_RECORD_TYPE = 'recordType';
const STEP_IDENTIFY = 'identify';
const STEP_REVIEW = 'review';
const STEP_FORM = 'form';
const STEP_DONE = 'done';
const MAX_MERGE = 3;

export default class RecordWizard extends NavigationMixin(LightningElement) {
    objectApiName;
    lastSessionToken;

    step = STEP_RECORD_TYPE;
    objectInfo;
    recordTypes;
    selectedRecordType;
    picklistValues = {};
    fieldConfigs;
    allFields = [];
    sections = [];
    fieldValues = {};
    clearedFields = [];
    currentPage = 1;

    // Identify step
    matchRules;
    identifyValues = {};
    matchResult;
    isSearching = false;
    identifyError;
    searchTimer;
    searchRequest = 0;
    selectedContactIds = [];
    selectedLeadIds = [];

    // Review step
    masterId;
    reviewData;
    reviewChoices = {};
    reviewError;
    isLoadingReview = false;

    // Accounts
    accountSuggestions = [];
    relatedAccounts = [];

    duplicateOutcome;
    wasMerged = false;
    accessChecked = false;
    accessDenied = false;
    loadError;
    isLoadingFields = false;
    isSaving = false;
    saveError;
    createdRecordId;

    @wire(CurrentPageReference)
    wiredPageReference(pageRef) {
        if (!pageRef) return;
        const objectApiName = pageRef.state?.c__object || undefined;
        const sessionToken = String(pageRef.state?.c__session || '');
        const isNewSession = sessionToken && sessionToken !== this.lastSessionToken;

        if (objectApiName !== this.objectApiName || isNewSession) {
            const sameObject = objectApiName === this.objectApiName;
            this.lastSessionToken = sessionToken;
            this.objectApiName = objectApiName;
            this.resetWizard(sameObject);
            if (!objectApiName) {
                this.loadError = 'No object was specified for the wizard (c__object).';
            }
        }
    }

    @wire(supportsRelatedAccounts)
    relatedAccountsSupport;

    @wire(hasWizardAccess)
    wiredAccess({ data, error }) {
        if (data === false) {
            this.accessDenied = true;
            this.loadError =
                'You do not have access to this wizard. Contact your Salesforce administrator to request the Record Wizard User permission set.';
        } else if (error) {
            this.loadError = `Could not verify your access permissions. ${this.reduceError(error)}`;
        }
        this.accessChecked = data !== undefined || Boolean(error);
    }

    @wire(getObjectInfo, { objectApiName: '$objectApiName' })
    wiredObjectInfo({ data, error }) {
        if (data) {
            this.objectInfo = data;
            this.buildForm();
        } else if (error) {
            this.loadError = this.reduceError(error);
        }
    }

    @wire(getRecordTypes, { objectApiName: '$objectApiName' })
    wiredRecordTypes({ data, error }) {
        if (data) {
            this.recordTypes = data;
            if (!data.length) {
                this.loadError = 'No wizard record type of this object is available for your user. Contact your Salesforce administrator.';
            } else if (data.length === 1 && !this.selectedRecordType) {
                this.selectRecordType(data[0]);
            }
        } else if (error) {
            this.loadError = this.reduceError(error);
        }
    }

    @wire(getMatchRules, { objectApiName: '$objectApiName' })
    wiredMatchRules({ data, error }) {
        if (data) {
            this.matchRules = data;
            if (!data.length && this.step === STEP_IDENTIFY) this.step = STEP_FORM;
        } else if (error) {
            this.matchRules = [];
            if (this.step === STEP_IDENTIFY) this.step = STEP_FORM;
        }
    }

    @wire(getPicklistValuesByRecordType, {
        objectApiName: '$objectApiName',
        recordTypeId: '$selectedRecordTypeId'
    })
    wiredPicklists({ data, error }) {
        if (data) {
            this.picklistValues = data.picklistFieldValues || {};
            this.rebuildSections();
        } else if (error) {
            this.loadError = `Could not load picklist values. ${this.reduceError(error)}`;
        }
    }

    // Wire results (objectInfo, recordTypes, criteria) are kept for the same object: the wires do not
    // provision again when their parameters are unchanged, so clearing them would hang the spinner.
    resetWizard(keepObjectData = false) {
        this.step = STEP_RECORD_TYPE;
        if (!keepObjectData) {
            this.objectInfo = undefined;
            this.recordTypes = undefined;
            this.matchRules = undefined;
        }
        this.selectedRecordType = undefined;
        this.fieldConfigs = undefined;
        this.allFields = [];
        this.sections = [];
        this.fieldValues = {};
        this.clearedFields = [];
        this.currentPage = 1;
        this.identifyValues = {};
        this.matchResult = undefined;
        this.identifyError = undefined;
        this.selectedContactIds = [];
        this.selectedLeadIds = [];
        this.masterId = undefined;
        this.reviewData = undefined;
        this.reviewChoices = {};
        this.reviewError = undefined;
        this.accountSuggestions = [];
        this.relatedAccounts = [];
        this.duplicateOutcome = undefined;
        this.wasMerged = false;
        if (!this.accessDenied) this.loadError = undefined;
        this.saveError = undefined;
        this.isSaving = false;
        this.createdRecordId = undefined;
        if (this.recordTypes?.length === 1) {
            this.selectRecordType(this.recordTypes[0]);
        }
    }

    // ------------------------------------------------------------- step 1: record type

    handleRecordTypeClick(event) {
        const id = event.currentTarget.dataset.id;
        const option = (this.recordTypes || []).find((item) => item.recordTypeId === id);
        if (option) this.selectRecordType(option);
    }

    async selectRecordType(option) {
        this.selectedRecordType = option;
        this.fieldValues = {};
        this.currentPage = 1;
        this.saveError = undefined;
        this.step = this.matchRules && !this.matchRules.length ? STEP_FORM : STEP_IDENTIFY;
        this.isLoadingFields = true;
        try {
            this.fieldConfigs = await getFields({
                objectApiName: this.objectApiName,
                recordTypeDeveloperName: option.developerName
            });
            this.buildForm();
        } catch (error) {
            this.loadError = this.reduceError(error);
        } finally {
            this.isLoadingFields = false;
        }
    }

    handleChangeRecordType() {
        const keep = { objectInfo: this.objectInfo, recordTypes: this.recordTypes, criteria: this.matchRules };
        this.resetWizard(true);
        this.objectInfo = keep.objectInfo;
        this.recordTypes = keep.recordTypes;
        this.matchRules = keep.criteria;
        this.step = STEP_RECORD_TYPE;
        this.selectedRecordType = undefined;
    }

    // ------------------------------------------------------------- step 2: identify

    get hasIdentifyStep() {
        return (this.matchRules || []).length > 0;
    }

    get identifyInputs() {
        return (this.matchRules || []).map((criterion) => {
            const info = this.objectInfo?.fields?.[criterion.fieldApiName] || {};
            const config = (this.fieldConfigs || []).find((row) => row.fieldApiName === criterion.fieldApiName);
            const isLookup = info.dataType === 'Reference';
            const value = this.identifyValues[criterion.fieldApiName];
            return {
                apiName: criterion.fieldApiName,
                label: config?.useCustomLabel
                    ? config.fieldLabel
                    : String(info.label || criterion.fieldApiName).replace(/ ID$/, ''),
                isLookup,
                isInput: !isLookup,
                inputType: info.dataType === 'Email' ? 'email' : info.dataType === 'Phone' ? 'tel' : 'text',
                lookupObject: isLookup ? info.referenceToInfos?.[0]?.apiName : undefined,
                lookupFilter: recordTypeFilter(config?.lookupRecordTypeIds),
                value: value ?? null
            };
        });
    }

    handleIdentifyChange(event) {
        const apiName = event.target.dataset.identifyField;
        const value = event.detail?.recordId !== undefined ? event.detail.recordId : event.detail?.value ?? event.target.value;
        this.identifyValues = { ...this.identifyValues, [apiName]: value };
        this.scheduleSearch();
    }

    // Results refresh by themselves while the user types (short pause so not every key press searches).
    scheduleSearch() {
        window.clearTimeout(this.searchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation -- debounce of the search-as-you-type input
        this.searchTimer = window.setTimeout(() => this.runSearch(), 500);
    }

    async runSearch() {
        const inputs = {};
        Object.entries(this.identifyValues).forEach(([key, value]) => {
            if (value !== undefined && value !== null && String(value).trim() !== '') inputs[key] = String(value).trim();
        });
        if (!inputs.Email && !inputs.LastName) {
            this.matchResult = undefined;
            this.selectedContactIds = [];
            this.selectedLeadIds = [];
            return;
        }
        const requestId = ++this.searchRequest;
        this.isSearching = true;
        this.identifyError = undefined;
        try {
            const result = await findMatches({
                recordTypeId: this.selectedRecordType.recordTypeId,
                inputsJson: JSON.stringify(inputs)
            });
            if (requestId !== this.searchRequest) return; // a newer search is running
            this.matchResult = result;
            // Keep the ticks of records that are still in the results.
            const ids = new Set((result.candidates || []).map((c) => c.recordId));
            this.selectedContactIds = this.selectedContactIds.filter((id) => ids.has(id));
            this.selectedLeadIds = this.selectedLeadIds.filter((id) => ids.has(id));
        } catch (error) {
            if (requestId === this.searchRequest) this.identifyError = this.reduceError(error);
        } finally {
            if (requestId === this.searchRequest) this.isSearching = false;
        }
    }

    get candidateRows() {
        return (this.matchResult?.candidates || []).map((c) => {
            const isContact = c.recordType === 'Contact';
            const selected = isContact ? this.selectedContactIds.includes(c.recordId) : this.selectedLeadIds.includes(c.recordId);
            return {
                ...c,
                isContact,
                selected,
                disabled: isContact && !selected && this.selectedContactIds.length >= MAX_MERGE,
                icon: isContact ? 'standard:contact' : 'standard:lead',
                action: isContact ? 'Merge' : 'Convert',
                url: `/lightning/r/${c.recordType}/${c.recordId}/view`,
                scoreClass: c.score >= 80 ? 'score score-high' : c.score >= 50 ? 'score score-medium' : 'score score-low',
                matchedText: (c.matched || []).join(', '),
                notMatchedText: (c.notMatched || []).join(', '),
                rowClass: selected ? 'candidate candidate-selected' : 'candidate'
            };
        });
    }

    get hasSearched() {
        return Boolean(this.matchResult);
    }

    get canContinueFromIdentify() {
        return this.hasSearched && !this.isSearching;
    }

    get hasCandidates() {
        return (this.matchResult?.candidates || []).length > 0;
    }

    get minimumScore() {
        return this.matchResult?.minimumScore ?? 30;
    }

    get hasSelection() {
        return this.selectedContactIds.length > 0 || this.selectedLeadIds.length > 0;
    }

    get identifyContinueLabel() {
        if (!this.hasSelection) return 'Create new Contact';
        return 'Review values';
    }

    handleCandidateToggle(event) {
        const { id, type } = event.target.dataset;
        const checked = event.target.checked;
        if (type === 'Contact') {
            const next = this.selectedContactIds.filter((item) => item !== id);
            if (checked) next.push(id);
            this.selectedContactIds = next.slice(0, MAX_MERGE);
        } else {
            const next = this.selectedLeadIds.filter((item) => item !== id);
            if (checked) next.push(id);
            this.selectedLeadIds = next;
        }
    }

    // The Identify values become the first values of the form.
    seedFromIdentify() {
        const next = { ...this.fieldValues };
        Object.entries(this.identifyValues).forEach(([key, value]) => {
            if (value !== undefined && value !== null && String(value).trim() !== '') next[key] = value;
        });
        this.fieldValues = next;
    }

    async handleIdentifyContinue() {
        this.seedFromIdentify();
        if (!this.hasSelection) {
            this.goToForm();
            return;
        }
        this.masterId = this.selectedContactIds[0];
        this.step = STEP_REVIEW;
        await this.loadReview();
    }

    // ------------------------------------------------------------- step 3: review values

    async loadReview() {
        this.isLoadingReview = true;
        this.reviewError = undefined;
        try {
            const data = await getMergeData({
                recordTypeId: this.selectedRecordType.recordTypeId,
                contactIds: this.selectedContactIds,
                leadIds: this.selectedLeadIds,
                fieldsJson: JSON.stringify(this.formPayload())
            });
            // Default: the value typed in the wizard; else the Contact kept; else the first record with a value.
            const choices = {};
            (data.rows || []).forEach((row) => {
                const form = row.cells.find((c) => c.source === 'form');
                const master = row.cells.find((c) => c.source === this.masterId);
                const firstWithValue = row.cells.find((c) => c.display);
                choices[row.apiName] = form?.display ? 'form' : master?.display ? master.source : firstWithValue?.source || 'form';
            });
            this.reviewChoices = choices;
            this.reviewData = data;
        } catch (error) {
            this.reviewError = this.reduceError(error);
        } finally {
            this.isLoadingReview = false;
        }
    }

    get masterOptions() {
        return (this.reviewData?.records || [])
            .filter((r) => r.recordType === 'Contact')
            .map((r) => ({ label: r.detail ? `${r.name} · ${r.detail}` : r.name, value: r.recordId }));
    }

    get isMergeMode() {
        return this.selectedContactIds.length > 0;
    }

    handleMasterChange(event) {
        this.masterId = event.detail.value;
    }

    get reviewColumns() {
        const records = new Map((this.reviewData?.records || []).map((r) => [r.recordId, r]));
        const ids = [...this.selectedContactIds, ...this.selectedLeadIds];
        return [
            { key: 'form', label: 'Entered in search', tag: 'Your values' },
            ...ids.map((id) => {
                const r = records.get(id) || {};
                const kept = id === this.masterId ? ' · kept' : '';
                return { key: id, label: r.name || id, tag: `${r.recordType || ''}${kept}` };
            })
        ];
    }

    get reviewRows() {
        return (this.reviewData?.rows || []).map((row) => ({
            apiName: row.apiName,
            label: row.label,
            cells: row.cells.map((c) => {
                const selected = this.reviewChoices[row.apiName] === c.source;
                return {
                    key: `${row.apiName}-${c.source}`,
                    source: c.source,
                    selected: String(selected),
                    display: c.display || 'No value',
                    textClass: c.display ? 'merge-value' : 'merge-value merge-value-empty',
                    cssClass: selected ? 'merge-cell merge-cell-selected' : 'merge-cell'
                };
            })
        }));
    }

    get hasReviewRows() {
        return (this.reviewData?.rows || []).length > 0;
    }

    get reviewIdenticalCount() {
        return this.reviewData?.identicalCount || 0;
    }

    handleReviewCellClick(event) {
        const { field, source } = event.currentTarget.dataset;
        this.reviewChoices = { ...this.reviewChoices, [field]: source };
    }

    // Chosen values go to the form; the Accounts not chosen as principal become Related Accounts.
    handleReviewContinue() {
        const next = { ...this.fieldValues };
        const cleared = [];
        const accounts = new Map();
        (this.reviewData?.rows || []).forEach((row) => {
            const chosen = row.cells.find((c) => c.source === this.reviewChoices[row.apiName]) || row.cells[0];
            const field = (this.allFields || []).find((f) => f.apiName === row.apiName);
            if (chosen.value === undefined || chosen.value === null || chosen.value === '') {
                delete next[row.apiName];
                cleared.push(row.apiName);
            } else if (field?.isMultiPicklist) {
                next[row.apiName] = String(chosen.value).split(';').filter(Boolean);
            } else {
                next[row.apiName] = chosen.value;
            }
            if (row.apiName === 'AccountId') {
                row.cells.forEach((c) => {
                    if (c.value) accounts.set(c.value, c.display);
                });
            }
        });
        this.fieldValues = next;
        this.clearedFields = cleared;
        this.relatedAccounts = [...accounts.entries()].map(([id, name]) => ({ id, name, checked: true }));
        this.goToForm();
    }

    handleBackToIdentify() {
        this.step = STEP_IDENTIFY;
        this.reviewError = undefined;
        this.saveError = undefined;
    }

    // ------------------------------------------------------------- step 4: form

    goToForm() {
        this.step = STEP_FORM;
        this.currentPage = this.pageNumbers[0] || 1;
        this.rebuildSections();
        this.loadAccountSuggestions();
    }

    async loadAccountSuggestions() {
        const companies = [...new Set((this.matchResult?.candidates || [])
            .filter((c) => c.recordType === 'Lead' && this.selectedLeadIds.includes(c.recordId) && c.company)
            .map((c) => c.company))];
        if (!companies.length) {
            this.accountSuggestions = [];
            return;
        }
        try {
            this.accountSuggestions = await suggestAccounts({
                recordTypeId: this.selectedRecordType.recordTypeId,
                companies
            });
        } catch (error) {
            this.accountSuggestions = [];
        }
    }

    get suggestionRows() {
        const current = this.fieldValues.AccountId;
        return (this.accountSuggestions || []).map((s) => ({
            ...s,
            cssClass: s.accountId === current ? 'suggestion suggestion-selected' : 'suggestion',
            badge: s.exact ? 'Exact match' : ''
        }));
    }

    get hasSuggestions() {
        return (this.accountSuggestions || []).length > 0;
    }

    handleSuggestionClick(event) {
        const id = event.currentTarget.dataset.id;
        const suggestion = this.accountSuggestions.find((s) => s.accountId === id);
        const previous = this.fieldValues.AccountId;
        if (previous && previous !== id && !this.relatedAccounts.some((a) => a.id === previous)) {
            const known = this.relatedAccounts.find((a) => a.id === previous);
            this.relatedAccounts = [...this.relatedAccounts, { id: previous, name: known?.name || 'Previous Account', checked: true }];
        }
        if (suggestion && !this.relatedAccounts.some((a) => a.id === id)) {
            this.relatedAccounts = [...this.relatedAccounts, { id, name: suggestion.name, checked: false }];
        }
        this.fieldValues = { ...this.fieldValues, AccountId: id };
        this.rebuildSections();
    }

    get relatedAccountRows() {
        const principal = this.fieldValues.AccountId;
        return this.relatedAccounts
            .filter((a) => a.id !== principal)
            .map((a) => ({ ...a, url: `/lightning/r/Account/${a.id}/view` }));
    }

    get hasRelatedAccounts() {
        return this.relatedAccountsSupport?.data === true && this.relatedAccountRows.length > 0;
    }

    handleRelatedToggle(event) {
        const id = event.target.dataset.id;
        this.relatedAccounts = this.relatedAccounts.map((a) => (a.id === id ? { ...a, checked: event.target.checked } : a));
    }

    get selectionSummary() {
        const parts = [];
        if (this.selectedContactIds.length) parts.push(`${this.selectedContactIds.length} Contact(s) merged`);
        if (this.selectedLeadIds.length) parts.push(`${this.selectedLeadIds.length} Lead(s) converted`);
        return parts.join(' · ');
    }

    buildForm() {
        if (!this.objectInfo || !this.fieldConfigs) return;
        this.allFields = this.fieldConfigs.map((row) => resolveField(row, this.objectInfo)).filter(Boolean);
        this.rebuildSections();
    }

    rebuildSections() {
        this.sections = buildSections(this.allFields || [], this.currentPage, {
            picklistValues: this.picklistValues,
            fieldValues: this.fieldValues,
            objectInfo: this.objectInfo
        });
    }

    handleFieldChange(event) {
        const { apiName, value } = event.detail;
        const next = { ...this.fieldValues, [apiName]: value };
        // Dependent picklists keep only values still valid for the new controlling value.
        (this.allFields || [])
            .filter((item) => item.controllerName === apiName)
            .forEach((dependent) => {
                next[dependent.apiName] = dependent.isMultiPicklist ? [] : null;
            });
        this.fieldValues = next;
        this.clearedFields = this.clearedFields.filter((name) => name !== apiName);
        this.rebuildSections();
    }

    // Validates the current page: rendered inputs plus required values.
    validateCurrentPage() {
        const inputs = [...this.template.querySelectorAll('c-wizard-field-input')];
        const valid = inputs.reduce((ok, input) => input.reportValidity() && ok, true);
        if (!valid) return false;
        const missing = this.allFields.find(
            (field) => field.pageNumber === this.currentPage && field.required && !hasValue(this.fieldValues[field.apiName])
        );
        if (missing) {
            this.template.querySelector(`c-wizard-field-input[data-field-api="${missing.apiName}"]`)?.reportValidity();
            return false;
        }
        return true;
    }

    handleNext() {
        if (!this.validateCurrentPage()) return;
        const next = this.pageNumbers.find((page) => page > this.currentPage);
        if (next !== undefined) {
            this.currentPage = next;
            this.saveError = undefined;
            this.rebuildSections();
        }
    }

    handleBack() {
        const previous = [...this.pageNumbers].reverse().find((page) => page < this.currentPage);
        if (previous !== undefined) {
            this.currentPage = previous;
            this.saveError = undefined;
            this.rebuildSections();
        } else if (this.hasSelection && this.reviewData) {
            this.step = STEP_REVIEW;
        } else if (this.hasIdentifyStep) {
            this.handleBackToIdentify();
        } else if (this.canChangeRecordType) {
            this.handleChangeRecordType();
        }
    }

    formPayload() {
        return payload(this.allFields, this.fieldValues);
    }

    handleSaveAnyway() {
        this.handleSave(true);
    }

    async handleSave(allowDuplicates = false) {
        allowDuplicates = allowDuplicates === true;
        if (!this.validateCurrentPage()) return;

        for (const field of this.allFields) {
            if (field.required && !hasValue(this.fieldValues[field.apiName])) {
                this.currentPage = field.pageNumber;
                this.rebuildSections();
                this.saveError = `${field.displayLabel} is required.`;
                return;
            }
        }
        const fields = this.formPayload();
        const relatedAccountIds = this.hasRelatedAccounts
            ? this.relatedAccountRows.filter((a) => a.checked).map((a) => a.id)
            : [];

        this.isSaving = true;
        this.saveError = undefined;
        this.duplicateOutcome = undefined;
        try {
            if (this.isMergeMode) {
                // Values the user chose to leave empty on the kept Contact are sent as blanks.
                this.clearedFields.forEach((name) => {
                    if (!(name in fields)) fields[name] = '';
                });
                this.createdRecordId = await mergeContacts({
                    recordTypeId: this.selectedRecordType.recordTypeId,
                    masterId: this.masterId,
                    mergeIds: this.selectedContactIds,
                    valuesJson: JSON.stringify(fields),
                    leadIds: this.selectedLeadIds,
                    relatedAccountIds
                });
                this.wasMerged = true;
            } else {
                const outcome = await createRecord({
                    objectApiName: this.objectApiName,
                    recordTypeId: this.selectedRecordType.recordTypeId,
                    fieldsJson: JSON.stringify(fields),
                    allowDuplicates,
                    leadIds: this.selectedLeadIds,
                    relatedAccountIds
                });
                if (outcome.duplicates) {
                    this.duplicateOutcome = outcome;
                    return;
                }
                this.createdRecordId = outcome.recordId;
            }
            this.step = STEP_DONE;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: this.wasMerged ? 'Contact updated' : `${this.objectLabel} created`,
                    message: this.selectionSummary || `${this.selectedRecordType.label} created successfully.`,
                    variant: 'success'
                })
            );
        } catch (error) {
            this.saveError = this.reduceError(error);
        } finally {
            this.isSaving = false;
        }
    }

    // A duplicate rule found Contacts the user did not select: add them to the review.
    async handleOpenMerge() {
        const ids = (this.duplicateOutcome?.duplicates || []).map((item) => item.recordId);
        this.selectedContactIds = [...new Set([...this.selectedContactIds, ...ids])].slice(0, MAX_MERGE);
        this.masterId = this.selectedContactIds[0];
        this.duplicateOutcome = undefined;
        this.step = STEP_REVIEW;
        await this.loadReview();
    }

    get canMerge() {
        return this.objectApiName === 'Contact' && (this.duplicateOutcome?.duplicates || []).length > 0;
    }

    // ------------------------------------------------------------- step 5 / navigation

    handleOpenRecord() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.createdRecordId, objectApiName: this.objectApiName, actionName: 'view' }
        });
    }

    handleCancel() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: this.objectApiName, actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    // ------------------------------------------------------------- getters

    get selectedRecordTypeId() {
        return this.selectedRecordType?.recordTypeId;
    }

    get objectLabel() {
        return this.objectInfo?.label || this.objectApiName || '';
    }

    get objectIcon() {
        return `standard:${String(this.objectApiName || 'record').toLowerCase()}`;
    }

    get title() {
        return `New ${this.objectLabel}`;
    }

    get isLoading() {
        return !this.loadError && (!this.accessChecked || !this.objectInfo || !this.recordTypes);
    }

    get ready() {
        return !this.loadError && !this.isLoading;
    }

    get showRecordTypeStep() {
        return this.ready && this.step === STEP_RECORD_TYPE;
    }

    get showIdentifyStep() {
        return this.ready && this.step === STEP_IDENTIFY && this.hasIdentifyStep;
    }

    get showReviewStep() {
        return this.ready && this.step === STEP_REVIEW;
    }

    get showFormStep() {
        return this.ready && (this.step === STEP_FORM || (this.step === STEP_IDENTIFY && this.matchRules && !this.hasIdentifyStep));
    }

    get showDoneStep() {
        return !this.loadError && this.step === STEP_DONE;
    }

    get recordTypeCards() {
        return (this.recordTypes || []).map((item) => ({
            ...item,
            cardClass: item.isDefault ? 'rt-card rt-card-default' : 'rt-card'
        }));
    }

    get canChangeRecordType() {
        return (this.recordTypes || []).length > 1;
    }

    get duplicateRows() {
        return (this.duplicateOutcome?.duplicates || []).map((item) => ({
            ...item,
            url: `/lightning/r/${this.objectApiName}/${item.recordId}/view`
        }));
    }

    get openRecordLabel() {
        return `Open ${this.objectLabel}`;
    }

    get saveLabel() {
        if (this.isSaving) return 'Saving…';
        return this.isMergeMode ? `Update ${this.objectLabel}` : `Create ${this.objectLabel}`;
    }

    get pageNumbers() {
        return [...new Set((this.allFields || []).map((field) => field.pageNumber))].sort((a, b) => a - b);
    }

    get isLastPage() {
        const pages = this.pageNumbers;
        return !pages.length || this.currentPage === pages[pages.length - 1];
    }

    get isNotLastPage() {
        return !this.isLastPage;
    }

    get showBack() {
        return this.pageNumbers.indexOf(this.currentPage) > 0 || this.hasIdentifyStep || this.canChangeRecordType;
    }

    get backLabel() {
        if (this.pageNumbers.indexOf(this.currentPage) > 0) return 'Back';
        if (this.hasSelection && this.reviewData) return 'Back to review';
        if (this.hasIdentifyStep) return 'Back to search';
        return 'Change record type';
    }

    get doneTitle() {
        return this.wasMerged
            ? `The ${this.objectLabel} was updated`
            : `Your ${this.objectLabel} was created`;
    }

    // Journey: record type (when there is a choice), identify, review (when records were chosen), form pages, complete.
    get journeySteps() {
        const order = [STEP_RECORD_TYPE, STEP_IDENTIFY, STEP_REVIEW, STEP_FORM, STEP_DONE];
        const position = order.indexOf(this.step);
        const state = (stepName) => {
            const index = order.indexOf(stepName);
            if (index < position) return 'complete';
            return index === position ? 'active' : '';
        };
        const steps = [];
        if (this.canChangeRecordType) {
            steps.push({ key: 'rt', title: 'Record Type', subtitle: 'Choose the type', state: state(STEP_RECORD_TYPE) });
        }
        if (this.hasIdentifyStep) {
            steps.push({ key: 'identify', title: 'Identify', subtitle: 'Find existing records', state: state(STEP_IDENTIFY) });
        }
        if (this.hasSelection) {
            steps.push({ key: 'review', title: 'Review values', subtitle: 'Choose what to keep', state: state(STEP_REVIEW) });
        }
        const pages = this.pageNumbers.length ? this.pageNumbers : [1];
        pages.forEach((page) => {
            const first = (this.allFields || []).find((field) => field.pageNumber === page);
            let pageState = state(STEP_FORM);
            if (this.step === STEP_FORM) pageState = page < this.currentPage ? 'complete' : page === this.currentPage ? 'active' : '';
            steps.push({ key: `page-${page}`, title: first?.section || 'Details', subtitle: `Page ${page}`, state: pageState });
        });
        steps.push({ key: 'done', title: 'Complete', subtitle: `${this.objectLabel} saved`, state: state(STEP_DONE) });
        return steps.map((item, index) => ({
            ...item,
            number: index + 1,
            showLine: index > 0,
            cssClass: `journey-step${item.state ? ' journey-step-' + item.state : ''}`
        }));
    }

    reduceError(error) {
        return reduceError(error);
    }
}