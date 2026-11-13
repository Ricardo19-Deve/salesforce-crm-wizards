import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import Toast from 'lightning/toast';
import getTestCases from '@salesforce/apex/ProjectDocsController.getTestCases';
import saveTestCase from '@salesforce/apex/ProjectDocsController.saveTestCase';
import deleteTestCase from '@salesforce/apex/ProjectDocsController.deleteTestCase';
import generateTestCasesFromBrd from '@salesforce/apex/ProjectDocsController.generateTestCasesFromBrd';
import getBrd from '@salesforce/apex/ProjectDocsController.getBrd';
import { exportUrl, reduceErrors, syncTextareas } from 'c/projectBoardUtils';

const RESULTS = [
    { value: 'Not Run', cls: 'notrun' },
    { value: 'Pass', cls: 'pass' },
    { value: 'Fail', cls: 'fail' },
    { value: 'Blocked', cls: 'blocked' }
];

function parseSteps(json) {
    try {
        const steps = JSON.parse(json || '[]');
        return Array.isArray(steps) ? steps : [];
    } catch {
        return [];
    }
}

/**
 * UAT test scripts of an issue: test cases with steps, execution result and evidence.
 */
export default class ProjectBoardTestScripts extends LightningElement {
    testCases = [];
    requirements = [];
    expanded = {};
    loading = true;
    busy = false;
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
            const [cases, brd] = await Promise.all([
                getTestCases({ issueId: this._issueId }),
                getBrd({ issueId: this._issueId })
            ]);
            this.testCases = cases.map((tc) => ({
                ...tc,
                steps: parseSteps(tc.Steps__c)
            }));
            this.requirements = brd && brd.Requirements__r ? brd.Requirements__r : [];
        } catch (e) {
            this.toast('Could not load test scripts', reduceErrors(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    // ---------------------------------------------------------------- Getters

    get hasTests() {
        return this.testCases.length > 0;
    }

    get hasRequirements() {
        return this.requirements.length > 0;
    }

    get summary() {
        const count = (status) => this.testCases.filter((t) => (t.Status__c || 'Not Run') === status).length;
        const total = this.testCases.length || 1;
        const pass = count('Pass');
        const fail = count('Fail');
        const blocked = count('Blocked');
        const notRun = count('Not Run');
        return {
            total: this.testCases.length,
            pass,
            fail,
            blocked,
            notRun,
            passStyle: `width:${(pass / total) * 100}%`,
            failStyle: `width:${(fail / total) * 100}%`,
            blockedStyle: `width:${(blocked / total) * 100}%`
        };
    }

    get rows() {
        return this.testCases.map((tc) => {
            const status = tc.Status__c || 'Not Run';
            const open = !!this.expanded[tc.Id];
            return {
                ...tc,
                open,
                chevron: open ? 'utility:chevrondown' : 'utility:chevronright',
                cardClass: `tc tc-${RESULTS.find((r) => r.value === status).cls}`,
                results: RESULTS.map((r) => ({
                    ...r,
                    cls: `seg seg-${r.cls}` + (r.value === status ? ' active' : '')
                })),
                reqLabel: tc.Requirement__r ? tc.Requirement__r.Name : null,
                reqOptions: [
                    { value: '', label: '— Not linked —', selected: !tc.Requirement__c },
                    ...this.requirements.map((r) => ({
                        value: r.Id,
                        label: r.Name,
                        selected: r.Id === tc.Requirement__c
                    }))
                ],
                testedBy: tc.Tested_By__r ? tc.Tested_By__r.Name : null,
                stepRows: tc.steps.map((s, i) => ({
                    ...s,
                    index: i,
                    num: i + 1,
                    key: `${tc.Id}-${i}`
                })),
                hasSteps: tc.steps.length > 0
            };
        });
    }

    get pdfUrl() {
        return exportUrl('ProjectTestScriptExport', this._issueId, 'pdf');
    }

    get wordUrl() {
        return exportUrl('ProjectTestScriptExport', this._issueId, 'word');
    }

    // ---------------------------------------------------------------- Actions

    toggle(event) {
        const id = event.currentTarget.dataset.id;
        this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
    }

    stop(event) {
        event.stopPropagation();
    }

    async handleAdd() {
        this.busy = true;
        try {
            const tc = await saveTestCase({
                fields: {
                    Issue__c: this._issueId,
                    Title__c: 'New test case',
                    Steps__c: '[{"action":"","expected":"","actual":""}]'
                }
            });
            this.testCases = [...this.testCases, { ...tc, steps: parseSteps(tc.Steps__c) }];
            this.expanded = { ...this.expanded, [tc.Id]: true };
            this.changed();
        } catch (e) {
            this.toast('Could not add the test case', reduceErrors(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleGenerate() {
        this.busy = true;
        try {
            const n = await generateTestCasesFromBrd({ issueId: this._issueId });
            this.toast(
                `${n} test case${n === 1 ? '' : 's'} generated`,
                'One per acceptance criterion of the BRD.',
                'success'
            );
            await this.load();
            this.changed();
        } catch (e) {
            this.toast('Nothing generated', reduceErrors(e), 'warning');
        } finally {
            this.busy = false;
        }
    }

    async handleResult(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const status = event.currentTarget.dataset.value;
        await this.save(id, { Status__c: status });
        this.changed();
    }

    async handleField(event) {
        const id = event.target.dataset.id;
        const field = event.target.dataset.field;
        const value = event.target.value;
        const tc = this.testCases.find((t) => t.Id === id);
        if ((tc[field] || '') === (value || '')) return;
        await this.save(id, { [field]: value });
    }

    handleStepInput(event) {
        const { id, index, field } = event.target.dataset;
        const value = event.target.value;
        this.testCases = this.testCases.map((tc) => {
            if (tc.Id !== id) return tc;
            const steps = tc.steps.map((s, i) => (i === Number(index) ? { ...s, [field]: value } : s));
            return { ...tc, steps, stepsDirty: true };
        });
    }

    async handleStepBlur(event) {
        const id = event.target.dataset.id;
        const tc = this.testCases.find((t) => t.Id === id);
        if (!tc.stepsDirty) return;
        await this.saveSteps(tc);
    }

    async handleAddStep(event) {
        const id = event.currentTarget.dataset.id;
        const tc = this.testCases.find((t) => t.Id === id);
        await this.saveSteps({
            ...tc,
            steps: [...tc.steps, { action: '', expected: '', actual: '' }]
        });
    }

    async handleRemoveStep(event) {
        const { id, index } = event.currentTarget.dataset;
        const tc = this.testCases.find((t) => t.Id === id);
        await this.saveSteps({
            ...tc,
            steps: tc.steps.filter((s, i) => i !== Number(index))
        });
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        const tc = this.testCases.find((t) => t.Id === id);
        const ok = await LightningConfirm.open({
            message: `${tc.Name} and its evidence links will be deleted.`,
            label: `Delete ${tc.Name}?`,
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteTestCase({ testCaseId: id });
            this.testCases = this.testCases.filter((t) => t.Id !== id);
            this.changed();
        } catch (e) {
            this.toast('Could not delete the test case', reduceErrors(e), 'error');
        }
    }

    // ---------------------------------------------------------------- Helpers

    async saveSteps(tc) {
        const clean = tc.steps.map((s) => ({
            action: s.action || '',
            expected: s.expected || '',
            actual: s.actual || ''
        }));
        await this.save(tc.Id, { Steps__c: JSON.stringify(clean) });
    }

    async save(id, fields) {
        try {
            const updated = await saveTestCase({ fields: { Id: id, ...fields } });
            const fresh = { ...updated, steps: parseSteps(updated.Steps__c) };
            this.testCases = this.testCases.map((t) => (t.Id === id ? fresh : t));
        } catch (e) {
            this.toast('Could not save', reduceErrors(e), 'error');
            this.load();
        }
    }

    changed() {
        this.dispatchEvent(new CustomEvent('changed'));
    }

    toast(label, message, variant) {
        Toast.show({ label, message, variant, mode: 'dismissible' }, this);
    }
}
