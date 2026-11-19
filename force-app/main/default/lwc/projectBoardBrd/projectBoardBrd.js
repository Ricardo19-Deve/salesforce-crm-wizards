/**
 * BRD & Solution Design editor - mirrors the BRD template section by section.
 * Every field saves on blur; PDF / Word exports are rendered by the ProjectBrdExport page.
 *
 * Sign-off: each role names a project member. "Request sign-off" locks the document and notifies the approvers;
 * the named approver approves or rejects here with their own login (name and date are recorded by the system).
 * Gotchas: editing is only possible while the BRD is Draft or Changes Requested and the user can edit the
 * project (readOnly = Viewer). "Reopen" unlocks it; an approved BRD gets a new minor version.
 */
import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import Toast from 'lightning/toast';
import getBrdView from '@salesforce/apex/ProjectDocsController.getBrdView';
import createBrd from '@salesforce/apex/ProjectDocsController.createBrd';
import saveBrd from '@salesforce/apex/ProjectDocsController.saveBrd';
import deleteBrd from '@salesforce/apex/ProjectDocsController.deleteBrd';
import addRequirement from '@salesforce/apex/ProjectDocsController.addRequirement';
import saveRequirement from '@salesforce/apex/ProjectDocsController.saveRequirement';
import deleteRequirement from '@salesforce/apex/ProjectDocsController.deleteRequirement';
import assignSignOff from '@salesforce/apex/ProjectDocsController.assignSignOff';
import requestSignOff from '@salesforce/apex/ProjectDocsController.requestSignOff';
import decideSignOff from '@salesforce/apex/ProjectDocsController.decideSignOff';
import reopenBrd from '@salesforce/apex/ProjectDocsController.reopenBrd';
import { exportUrl, reduceErrors, syncTextareas, toTime, initials, avatarStyle } from 'c/projectBoardUtils';

// Native inputs show the text "undefined" for missing values, so blank text fields become "".
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

const STATUS_PILL = {
    Draft: 'status-pill status-draft',
    'Sent for Approval': 'status-pill status-sent',
    Approved: 'status-pill status-approved',
    'Changes Requested': 'status-pill status-changes'
};

const SIGN_PILL = {
    Pending: 'sign-pill sign-pending',
    Approved: 'sign-pill sign-approved',
    Rejected: 'sign-pill sign-rejected',
    'Not Required': 'sign-pill sign-na'
};

function withBlanks(record, fields) {
    const copy = { ...record };
    fields.forEach((f) => {
        if (copy[f] === undefined || copy[f] === null) copy[f] = '';
    });
    return copy;
}

export default class ProjectBoardBrd extends LightningElement {
    @api issue;
    /** Project role is Viewer: the document can be read and exported, not changed. */
    @api readOnly = false;

    view;
    brd;
    requirements = [];
    signOffs = [];
    decisionComments = {};
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
            this.setView(await getBrdView({ issueId: this._issueId }));
        } catch (e) {
            this.toast('Could not load the BRD', reduceErrors(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    setView(view) {
        this.view = view;
        const brd = view ? view.brd : null;
        this.brd = brd ? withBlanks(brd, BRD_TEXT_FIELDS) : null;
        this.requirements =
            brd && brd.Requirements__r ? brd.Requirements__r.map((r) => withBlanks(r, REQUIREMENT_TEXT_FIELDS)) : [];
        this.signOffs = brd && brd.Sign_Offs__r ? brd.Sign_Offs__r : [];
        this.decisionComments = {};
    }

    // ---------------------------------------------------------------- Getters

    get hasBrd() {
        return !!this.brd;
    }

    /** Content can change: open document and a user who may edit the project. */
    get editable() {
        return !this.readOnly && !!this.view && this.view.canEdit;
    }

    get locked() {
        return !this.editable;
    }

    get canCreate() {
        return !this.readOnly;
    }

    get canRequest() {
        return this.editable && this.view.canRequest;
    }

    get canReopen() {
        return !this.readOnly && !!this.view && this.view.canReopen;
    }

    get canDelete() {
        return !this.readOnly;
    }

    get status() {
        return this.brd ? this.brd.Status__c || 'Draft' : '';
    }

    get statusClass() {
        return STATUS_PILL[this.status] || STATUS_PILL.Draft;
    }

    get reopenLabel() {
        return this.status === 'Approved' ? 'Start new version' : 'Reopen for changes';
    }

    /** Banner explaining the lock and what happens next. */
    get banner() {
        const rows = this.signOffs.filter((s) => s.Status__c !== 'Not Required');
        const approved = rows.filter((s) => s.Status__c === 'Approved').length;
        switch (this.status) {
            case 'Sent for Approval':
                return {
                    cls: 'banner banner-sent',
                    icon: 'utility:lock',
                    text: `Waiting for sign-off: ${approved} of ${rows.length} approvals received. The document is locked until every approver has decided.`
                };
            case 'Approved':
                return {
                    cls: 'banner banner-approved',
                    icon: 'utility:success',
                    text: `Approved by every approver. Version ${this.brd.Version__c} is locked; start a new version to change it.`
                };
            case 'Changes Requested': {
                const rejected = this.signOffs.find((s) => s.Status__c === 'Rejected');
                const who = rejected && rejected.Approver__r ? rejected.Approver__r.Name : 'An approver';
                return {
                    cls: 'banner banner-changes',
                    icon: 'utility:edit',
                    text: `${who} asked for changes${rejected && rejected.Comments__c ? ': "' + rejected.Comments__c + '"' : ''}. Update the document and request sign-off again.`
                };
            }
            default:
                return null;
        }
    }

    get systemChips() {
        const raw = this.brd && this.brd.Systems_Impacted__c ? this.brd.Systems_Impacted__c : '';
        return raw
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s);
    }

    /** Project members, plus the current approver if they have left the project. */
    approverOptions(currentId, currentName) {
        const members = (this.view && this.view.members) || [];
        const options = [{ value: '', label: 'Choose an approver…' }].concat(
            members.map((m) => ({ value: m.id, label: m.name }))
        );
        if (currentId && !members.some((m) => m.id === currentId)) {
            options.push({ value: currentId, label: currentName || 'Former member' });
        }
        return options.map((o) => ({
            ...o,
            selected: o.value === (currentId || '')
        }));
    }

    get brdSignOffRows() {
        return this.signOffRows('BRD');
    }

    get solutionSignOffRows() {
        return this.signOffRows('Solution Design');
    }

    signOffRows(section) {
        const me = this.view ? this.view.currentUserId : null;
        return this.signOffs
            .filter((s) => (s.Section__c || 'BRD') === section)
            .map((s) => {
                const notRequired = s.Status__c === 'Not Required';
                const approverName = s.Approver__r ? s.Approver__r.Name : null;
                const isMine = this.status === 'Sent for Approval' && s.Status__c === 'Pending' && s.Approver__c === me;
                return {
                    ...s,
                    notRequired,
                    approverName: notRequired ? 'Not required' : approverName || 'Not assigned',
                    hasApprover: !!approverName && !notRequired,
                    approverInitials: initials(approverName),
                    approverStyle: avatarStyle(s.Approver__c || 'none'),
                    pillClass: SIGN_PILL[s.Status__c] || SIGN_PILL.Pending,
                    decidedAt: toTime(s.Decision_Date__c),
                    showPicker: this.editable && !notRequired,
                    approverOptions: this.approverOptions(s.Approver__c, approverName),
                    isMine,
                    rowClass: 'signoff-row' + (isMine ? ' mine' : ''),
                    commentLabel: `Comment for ${s.Role__c}`
                };
            });
    }

    get myPendingCount() {
        return [...this.brdSignOffRows, ...this.solutionSignOffRows].filter((s) => s.isMine).length;
    }

    get myPendingLabel() {
        const n = this.myPendingCount;
        return n === 1 ? '1 sign-off is waiting for you below' : `${n} sign-offs are waiting for you below`;
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
            await createBrd({ issueId: this._issueId });
            await this.load();
            this.toast(
                'BRD created from the template',
                'Pre-filled from the issue. Name the approvers before requesting sign-off.',
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
            message: 'The BRD, its requirements, solution design and sign-offs will be deleted. Test cases are kept.',
            label: 'Delete BRD?',
            theme: 'error'
        });
        if (!ok) return;
        try {
            await deleteBrd({ brdId: this.brd.Id });
            this.setView(null);
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

    // ---------------------------------------------------------------- Sign-off

    async handleApprover(event) {
        const id = event.target.dataset.id;
        const approverId = event.detail.value || null;
        await this.persist(async () => {
            await assignSignOff({ signOffId: id, approverId, notRequired: false });
            await this.load();
        });
    }

    async handleNotRequired(event) {
        const id = event.target.dataset.id;
        const notRequired = event.target.checked;
        await this.persist(async () => {
            await assignSignOff({ signOffId: id, approverId: null, notRequired });
            await this.load();
        });
    }

    async handleRequest() {
        const approvers = new Set(
            this.signOffs.filter((s) => s.Status__c !== 'Not Required' && s.Approver__c).map((s) => s.Approver__c)
        ).size;
        const ok = await LightningConfirm.open({
            message: `The document will be locked and ${approvers} approver${approvers === 1 ? '' : 's'} will be notified. You can reopen it later if something needs to change.`,
            label: 'Request sign-off?',
            theme: 'info'
        });
        if (!ok) return;
        await this.persist(async () => {
            await requestSignOff({ brdId: this.brd.Id });
            await this.load();
            this.toast('Sign-off requested', 'The approvers have been notified.', 'success');
        });
    }

    handleDecisionComment(event) {
        this.decisionComments = {
            ...this.decisionComments,
            [event.target.dataset.id]: event.target.value
        };
    }

    handleApprove(event) {
        this.decide(event.currentTarget.dataset.id, 'Approved');
    }

    handleReject(event) {
        const id = event.currentTarget.dataset.id;
        if (!(this.decisionComments[id] || '').trim()) {
            this.toast('Add a comment', 'Explain what needs to change before rejecting.', 'warning');
            const box = this.template.querySelector(`textarea[data-id="${id}"]`);
            if (box) box.focus();
            return;
        }
        this.decide(id, 'Rejected');
    }

    async decide(signOffId, decision) {
        await this.persist(async () => {
            await decideSignOff({
                signOffId,
                decision,
                comments: this.decisionComments[signOffId] || null
            });
            await this.load();
            this.toast(
                decision === 'Approved' ? 'Signed off' : 'Changes requested',
                decision === 'Approved'
                    ? "Your approval is recorded with today's date."
                    : 'The author has been notified.',
                'success'
            );
            this.dispatchEvent(new CustomEvent('changed'));
        });
    }

    async handleReopen() {
        const approved = this.status === 'Approved';
        const ok = await LightningConfirm.open({
            message: approved
                ? 'A new minor version is created and every approver will need to sign off again.'
                : 'The document is unlocked and the pending decisions are cleared.',
            label: approved ? 'Start a new version?' : 'Reopen for changes?',
            theme: 'warning'
        });
        if (!ok) return;
        await this.persist(async () => {
            await reopenBrd({ brdId: this.brd.Id });
            await this.load();
        });
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
