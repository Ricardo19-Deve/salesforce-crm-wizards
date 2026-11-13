import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import Toast from 'lightning/toast';
import getBrd from '@salesforce/apex/ProjectDocsController.getBrd';
import createBrd from '@salesforce/apex/ProjectDocsController.createBrd';
import saveBrd from '@salesforce/apex/ProjectDocsController.saveBrd';
import deleteBrd from '@salesforce/apex/ProjectDocsController.deleteBrd';
import addRequirement from '@salesforce/apex/ProjectDocsController.addRequirement';
import saveRequirement from '@salesforce/apex/ProjectDocsController.saveRequirement';
import deleteRequirement from '@salesforce/apex/ProjectDocsController.deleteRequirement';
import { exportUrl, reduceErrors, syncTextareas } from 'c/projectBoardUtils';

const STATUSES = ['Draft', 'Sent for Approval', 'Approved'];

// Native inputs show the text "undefined" for missing values, so blank text fields become ''.
const BRD_TEXT_FIELDS = [
    'Name',
    'PBI_ID__c',
    'Business_Area__c',
    'Version__c',
    'Business_Analyst__c',
    'Business_Requestor__c',
    'Impacted_Users__c',
    'Systems_Impacted__c'
];
const REQUIREMENT_TEXT_FIELDS = [
    'Requirement__c',
    'Acceptance_Criteria__c',
    'Systems_Impacted__c',
    'Additional_Info__c',
    'Solution__c',
    'Solution_Systems__c'
];

function withBlanks(record, fields) {
    const copy = { ...record };
    fields.forEach((f) => {
        if (copy[f] === undefined || copy[f] === null) copy[f] = '';
    });
    return copy;
}

const SIGN_OFF = [
    { key: 'Initiator', label: 'Business Change Initiator' },
    { key: 'IT_Approver', label: 'IT Delivery BRD Approver' },
    { key: 'Architect_Approver', label: 'IT Architect Approver' }
];

const SOLUTION_SIGN_OFF = [
    { key: 'Solution_Designer', label: 'Solution Designer' },
    { key: 'Solution_Reviewer', label: 'Solution Reviewer' }
];

/**
 * BRD & Solution Design editor - mirrors the Contoso BRD template section by section.
 * Every field saves on blur; PDF / Word exports are rendered by the ProjectBrdExport page.
 */
export default class ProjectBoardBrd extends LightningElement {
    @api issue;

    brd;
    requirements = [];
    loading = true;
    saving = false;
    _issueId;

    @api
    get issueId() {
        return this._issueId;
    }
    set issueId(value) {
        const changed = value !== this._issueId;
        this._issueId = value;
        if (changed && value) {
            this.load();
        }
    }

    renderedCallback() {
        syncTextareas(this.template);
    }

    async load() {
        this.loading = true;
        try {
            this.setBrd(await getBrd({ issueId: this._issueId }));
        } catch (e) {
            this.toast('Could not load the BRD', reduceErrors(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    setBrd(brd) {
        this.brd = brd ? withBlanks(brd, BRD_TEXT_FIELDS) : null;
        this.requirements =
            brd && brd.Requirements__r ? brd.Requirements__r.map((r) => withBlanks(r, REQUIREMENT_TEXT_FIELDS)) : [];
    }

    // ---------------------------------------------------------------- Getters

    get hasBrd() {
        return !!this.brd;
    }

    get statusOptions() {
        const current = this.brd ? this.brd.Status__c : null;
        return STATUSES.map((s) => ({
            value: s,
            label: s,
            selected: s === current
        }));
    }

    get statusClass() {
        const s = this.brd ? this.brd.Status__c : '';
        if (s === 'Approved') return 'status-pill status-approved';
        if (s === 'Sent for Approval') return 'status-pill status-sent';
        return 'status-pill status-draft';
    }

    get systemChips() {
        const raw = this.brd && this.brd.Systems_Impacted__c ? this.brd.Systems_Impacted__c : '';
        return raw
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s);
    }

    get signOffRows() {
        return this.buildSignOff(SIGN_OFF);
    }

    get solutionSignOffRows() {
        return this.buildSignOff(SOLUTION_SIGN_OFF);
    }

    buildSignOff(defs) {
        return defs.map((d) => ({
            ...d,
            nameField: `${d.key}_Name__c`,
            dateField: `${d.key}_Date__c`,
            name: this.brd[`${d.key}_Name__c`] || '',
            date: this.brd[`${d.key}_Date__c`] || ''
        }));
    }

    get requirementCount() {
        return this.requirements.length;
    }

    get pdfUrl() {
        return exportUrl('ProjectBrdExport', this.brd.Id, 'pdf');
    }

    get wordUrl() {
        return exportUrl('ProjectBrdExport', this.brd.Id, 'word');
    }

    // ---------------------------------------------------------------- BRD actions

    async handleCreate() {
        this.saving = true;
        try {
            this.setBrd(await createBrd({ issueId: this._issueId }));
            this.toast(
                'BRD created from the Contoso template',
                'Pre-filled from the issue - review each section.',
                'success'
            );
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (e) {
            this.toast('Could not create the BRD', reduceErrors(e), 'error');
        } finally {
            this.saving = false;
        }
    }

    async handleDeleteBrd() {
        const ok = await LightningConfirm.open({
            message: 'The BRD, its requirements and solution design will be deleted. Test cases are kept.',
            label: 'Delete BRD?',
            theme: 'error'
        });
        if (!ok) return;
        try {
            await deleteBrd({ brdId: this.brd.Id });
            this.setBrd(null);
            this.dispatchEvent(new CustomEvent('changed'));
        } catch (e) {
            this.toast('Could not delete the BRD', reduceErrors(e), 'error');
        }
    }

    async handleBrdField(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        if ((this.brd[field] || '') === (value || '')) return;
        this.brd = { ...this.brd, [field]: value };
        await this.persist(() => saveBrd({ fields: { Id: this.brd.Id, [field]: value } }));
    }

    // ---------------------------------------------------------------- Requirements

    async handleAddRequirement() {
        try {
            const req = await addRequirement({ brdId: this.brd.Id });
            this.requirements = [...this.requirements, withBlanks(req, REQUIREMENT_TEXT_FIELDS)];
        } catch (e) {
            this.toast('Could not add the requirement', reduceErrors(e), 'error');
        }
    }

    async handleRequirementField(event) {
        const id = event.target.dataset.id;
        const field = event.target.dataset.field;
        const value = event.target.value;
        const req = this.requirements.find((r) => r.Id === id);
        if ((req[field] || '') === (value || '')) return;
        this.requirements = this.requirements.map((r) => (r.Id === id ? { ...r, [field]: value } : r));
        await this.persist(() => saveRequirement({ fields: { Id: id, [field]: value } }));
    }

    async handleDeleteRequirement(event) {
        const id = event.currentTarget.dataset.id;
        const req = this.requirements.find((r) => r.Id === id);
        const ok = await LightningConfirm.open({
            message: `${req.Name} and its solution will be removed from the BRD.`,
            label: `Delete ${req.Name}?`,
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteRequirement({ requirementId: id });
            this.requirements = this.requirements.filter((r) => r.Id !== id);
        } catch (e) {
            this.toast('Could not delete the requirement', reduceErrors(e), 'error');
        }
    }

    // ---------------------------------------------------------------- Helpers

    async persist(fn) {
        this.saving = true;
        try {
            await fn();
        } catch (e) {
            this.toast('Could not save', reduceErrors(e), 'error');
            this.load();
        } finally {
            this.saving = false;
        }
    }

    toast(label, message, variant) {
        Toast.show({ label, message, variant, mode: 'dismissible' }, this);
    }
}
