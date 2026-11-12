/**
 * Opportunity + products wizard UI. Open with /lightning/cmp/c__opportunityWizard?c__session=<anything unique>
 * (list button Wizard_New_Opportunity).
 *
 * Step 1 details: fields from Wizard_Field__mdt (Object = Opportunity), rendered by c-wizard-field-input.
 * Step 2 products: catalog of the price book chosen for the Account (country rule, see PriceBookResolver), with
 *        quantity, sales price, discount and a required Line Type per product.
 * Step 3 done. Server: OpportunityWizardController.createOpportunity saves everything in one transaction.
 */
import { LightningElement, wire } from 'lwc';
import { getObjectInfo, getPicklistValuesByRecordType, getPicklistValues } from 'lightning/uiObjectInfoApi';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LINE_TYPE_FIELD from '@salesforce/schema/OpportunityLineItem.Line_Type__c';
import hasWizardAccess from '@salesforce/apex/OpportunityWizardController.hasWizardAccess';
import getFields from '@salesforce/apex/OpportunityWizardController.getFields';
import getCatalog from '@salesforce/apex/OpportunityWizardController.getCatalog';
import createOpportunity from '@salesforce/apex/OpportunityWizardController.createOpportunity';
import { buildSections, hasValue, payload, reduceError, resolveField } from 'c/wizardFieldUtils';

const STEP_DETAILS = 'details';
const STEP_PRODUCTS = 'products';
const STEP_DONE = 'done';
const MASTER_RECORD_TYPE = '012000000000000AAA';

export default class OpportunityWizard extends NavigationMixin(LightningElement) {
    step = STEP_DETAILS;
    lastSessionToken;
    accessChecked = false;
    loadError;

    objectInfo;
    fieldConfigs;
    picklistValues = {};
    allFields = [];
    sections = [];
    fieldValues = {};

    catalog;
    catalogAccountId;
    isLoadingCatalog = false;
    searchTerm = '';
    familyFilter = '';
    lines = {};
    lineTypeOptions = [];

    isSaving = false;
    saveError;
    createdRecordId;

    @wire(CurrentPageReference)
    wiredPageReference(pageRef) {
        const token = String(pageRef?.state?.c__session || '');
        if (token && token !== this.lastSessionToken) {
            this.lastSessionToken = token;
            this.reset();
        }
    }

    @wire(hasWizardAccess)
    wiredAccess({ data, error }) {
        if (data === false) {
            this.loadError = 'You do not have access to this wizard. Ask your administrator for the Opportunity Wizard User permission set.';
        } else if (error) {
            this.loadError = reduceError(error);
        }
        this.accessChecked = data !== undefined || Boolean(error);
    }

    @wire(getObjectInfo, { objectApiName: 'Opportunity' })
    wiredObjectInfo({ data, error }) {
        if (data) {
            this.objectInfo = data;
            this.buildForm();
        } else if (error) {
            this.loadError = reduceError(error);
        }
    }

    @wire(getPicklistValuesByRecordType, { objectApiName: 'Opportunity', recordTypeId: '$defaultRecordTypeId' })
    wiredPicklists({ data }) {
        if (data) {
            this.picklistValues = data.picklistFieldValues || {};
            this.rebuildSections();
        }
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE, fieldApiName: LINE_TYPE_FIELD })
    wiredLineTypes({ data }) {
        if (data) {
            this.lineTypeOptions = data.values.map((item) => ({ label: item.label, value: item.value }));
        }
    }

    @wire(getFields)
    wiredFields({ data, error }) {
        if (data) {
            this.fieldConfigs = data;
            this.buildForm();
        } else if (error) {
            this.loadError = reduceError(error);
        }
    }

    // Wire results stay (they would not provision again); only the user's input is cleared.
    reset() {
        this.step = STEP_DETAILS;
        this.fieldValues = {};
        this.catalog = undefined;
        this.catalogAccountId = undefined;
        this.searchTerm = '';
        this.familyFilter = '';
        this.lines = {};
        this.saveError = undefined;
        this.createdRecordId = undefined;
        this.isSaving = false;
        this.rebuildSections();
    }

    // ------------------------------------------------------------- step 1: details

    get defaultRecordTypeId() {
        return this.objectInfo?.defaultRecordTypeId;
    }

    buildForm() {
        if (!this.objectInfo || !this.fieldConfigs) return;
        this.allFields = this.fieldConfigs.map((row) => resolveField(row, this.objectInfo)).filter(Boolean);
        this.rebuildSections();
    }

    rebuildSections() {
        this.sections = buildSections(this.allFields, undefined, {
            picklistValues: this.picklistValues,
            fieldValues: this.fieldValues,
            objectInfo: this.objectInfo
        });
    }

    handleFieldChange(event) {
        const { apiName, value } = event.detail;
        this.fieldValues = { ...this.fieldValues, [apiName]: value };
        this.rebuildSections();
    }

    validateDetails() {
        const inputs = [...this.template.querySelectorAll('c-wizard-field-input')];
        const valid = inputs.reduce((ok, input) => input.reportValidity() && ok, true);
        const missing = this.allFields.find((field) => field.required && !hasValue(this.fieldValues[field.apiName]));
        if (missing) {
            this.saveError = `${missing.displayLabel} is required.`;
            return false;
        }
        return valid;
    }

    async handleToProducts() {
        this.saveError = undefined;
        if (!this.validateDetails()) return;
        this.step = STEP_PRODUCTS;
        const accountId = this.fieldValues.AccountId || null;
        if (this.catalog && this.catalogAccountId === accountId) return;
        // A different Account can mean a different price book: previous lines no longer apply.
        this.lines = {};
        this.isLoadingCatalog = true;
        try {
            this.catalog = await getCatalog({ accountId });
            this.catalogAccountId = accountId;
        } catch (error) {
            this.saveError = reduceError(error);
        } finally {
            this.isLoadingCatalog = false;
        }
    }

    // ------------------------------------------------------------- step 2: products

    get priceBookLabel() {
        const book = this.catalog?.priceBook;
        if (!book) return '';
        return book.isCountrySpecific ? `${book.name} (country price book)` : `${book.name} (default price book)`;
    }

    get familyOptions() {
        const families = [...new Set((this.catalog?.products || []).map((p) => p.family).filter(Boolean))].sort();
        return [{ label: 'All families', value: '' }, ...families.map((f) => ({ label: f, value: f }))];
    }

    get productRows() {
        const term = this.searchTerm.trim().toLowerCase();
        return (this.catalog?.products || [])
            .filter((p) => !this.familyFilter || p.family === this.familyFilter)
            .filter((p) => !term || `${p.name} ${p.productCode || ''}`.toLowerCase().includes(term))
            .map((p) => {
                const line = this.lines[p.pricebookEntryId];
                return {
                    ...p,
                    selected: Boolean(line),
                    inputsDisabled: !line,
                    rowClass: line ? 'product-row product-row-selected' : 'product-row',
                    quantity: line?.quantity ?? 1,
                    unitPrice: line?.unitPrice ?? p.unitPrice,
                    discount: line?.discount ?? 0,
                    lineType: line?.lineType ?? '',
                    listPrice: this.formatAmount(p.unitPrice, p.currencyIsoCode)
                };
            });
    }

    get hasProducts() {
        return this.productRows.length > 0;
    }

    get selectedCount() {
        return Object.keys(this.lines).length;
    }

    get totalLabel() {
        const total = Object.values(this.lines).reduce(
            (sum, line) => sum + Number(line.quantity || 0) * Number(line.unitPrice || 0) * (1 - Number(line.discount || 0) / 100),
            0
        );
        const currency = (this.catalog?.products || [])[0]?.currencyIsoCode;
        return this.formatAmount(total, currency);
    }

    formatAmount(value, currency) {
        const options = currency ? { style: 'currency', currency } : { minimumFractionDigits: 2, maximumFractionDigits: 2 };
        return new Intl.NumberFormat(undefined, options).format(Number(value || 0));
    }

    handleSearch(event) {
        this.searchTerm = event.target.value || '';
    }

    handleFamily(event) {
        this.familyFilter = event.detail.value;
    }

    handleProductToggle(event) {
        const id = event.target.dataset.id;
        const next = { ...this.lines };
        if (event.target.checked) {
            const product = this.catalog.products.find((p) => p.pricebookEntryId === id);
            next[id] = { pricebookEntryId: id, quantity: 1, unitPrice: product.unitPrice, discount: 0, lineType: '' };
        } else {
            delete next[id];
        }
        this.lines = next;
    }

    handleLineChange(event) {
        const { id, prop } = event.target.dataset;
        if (!this.lines[id]) return;
        const value = event.detail?.value !== undefined ? event.detail.value : event.target.value;
        this.lines = { ...this.lines, [id]: { ...this.lines[id], [prop]: value } };
    }

    handleBackToDetails() {
        this.step = STEP_DETAILS;
        this.saveError = undefined;
        this.rebuildSections();
    }

    async handleSave() {
        this.saveError = undefined;
        const lines = Object.values(this.lines);
        if (!lines.length) {
            this.saveError = 'Select at least one product.';
            return;
        }
        const inputs = [...this.template.querySelectorAll('[data-line-input]')];
        const valid = inputs.reduce((ok, input) => input.reportValidity() && ok, true);
        if (!valid || lines.some((line) => !line.lineType)) {
            this.saveError = 'Every selected product needs a quantity, a price and a Line Type.';
            return;
        }
        this.isSaving = true;
        try {
            this.createdRecordId = await createOpportunity({
                opportunityJson: JSON.stringify(payload(this.allFields, this.fieldValues)),
                linesJson: JSON.stringify(lines)
            });
            this.step = STEP_DONE;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Opportunity created',
                message: `${lines.length} product(s) added.`,
                variant: 'success'
            }));
        } catch (error) {
            this.saveError = reduceError(error);
        } finally {
            this.isSaving = false;
        }
    }

    // ------------------------------------------------------------- navigation and state

    handleOpenRecord() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.createdRecordId, objectApiName: 'Opportunity', actionName: 'view' }
        });
    }

    handleCancel() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Opportunity', actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    get isLoading() {
        return !this.loadError && (!this.accessChecked || !this.objectInfo || !this.fieldConfigs);
    }

    get ready() {
        return !this.loadError && !this.isLoading;
    }

    get showDetails() {
        return this.ready && this.step === STEP_DETAILS;
    }

    get showProducts() {
        return this.ready && this.step === STEP_PRODUCTS;
    }

    get showDone() {
        return this.step === STEP_DONE;
    }

    get saveLabel() {
        return this.isSaving ? 'Saving…' : 'Create Opportunity';
    }

    get journeySteps() {
        const order = [STEP_DETAILS, STEP_PRODUCTS, STEP_DONE];
        const position = order.indexOf(this.step);
        return [
            { key: STEP_DETAILS, title: 'Details', subtitle: 'Opportunity' },
            { key: STEP_PRODUCTS, title: 'Products', subtitle: 'From the price book' },
            { key: STEP_DONE, title: 'Complete', subtitle: 'Opportunity saved' }
        ].map((item, index) => {
            const state = index < position ? 'complete' : index === position ? 'active' : '';
            return {
                ...item,
                number: index + 1,
                showLine: index > 0,
                cssClass: `journey-step${state ? ' journey-step-' + state : ''}`
            };
        });
    }
}
