/**
 * Issue modal: create form, or detail view with inline editing and tabs for Details (description, comments,
 * history), BRD, Test scripts and Attachments.
 * Gotchas: every field saves on its own; the parent reloads the board on "changed" so badges stay in sync.
 */
import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import Toast from 'lightning/toast';
import saveIssue from '@salesforce/apex/ProjectBoardController.saveIssue';
import deleteIssue from '@salesforce/apex/ProjectBoardController.deleteIssue';
import getIssueDetail from '@salesforce/apex/ProjectBoardController.getIssueDetail';
import addComment from '@salesforce/apex/ProjectBoardController.addComment';
import deleteComment from '@salesforce/apex/ProjectBoardController.deleteComment';
import {
    STATUSES,
    TYPES,
    PRIORITIES,
    reduceErrors,
    typeMeta,
    initials,
    avatarStyle,
    epicStyle,
    sumPoints,
    toTime
} from 'c/projectBoardUtils';

const STATUS_SELECT_CLASS = {
    'To Do': 'status-select status-todo',
    'In Progress': 'status-select status-progress',
    'In Review': 'status-select status-review',
    Done: 'status-select status-done'
};

function selectOptions(values, current) {
    return values.map((v) => ({ value: v, label: v, selected: v === current }));
}

export default class ProjectBoardIssueDetail extends LightningElement {
    @api issues = [];
    @api sprints = [];
    @api project;
    @api currentUserId;
    @api mode = 'view';
    @api defaults;

    _issueId;
    _connected = false;
    focusSelector;

    // create mode
    form = {};
    error;
    busy = false;

    // view mode
    editingSummary = false;
    summaryDraft = '';
    editingDescription = false;
    descriptionDraft = '';
    commentEditing = false;
    commentDraft = '';
    comments = [];
    history = [];
    activityTab = 'comments';
    activeTab = 'details';

    userFilter = {
        criteria: [
            { fieldPath: 'IsActive', operator: 'eq', value: true },
            { fieldPath: 'UserType', operator: 'eq', value: 'Standard' }
        ],
        filterLogic: '1 AND 2'
    };
    userDisplayInfo = { primaryField: 'Name', additionalFields: ['Title'] };
    userMatchingInfo = {
        primaryField: { fieldPath: 'Name' },
        additionalFields: [{ fieldPath: 'Email' }]
    };

    @api
    get issueId() {
        return this._issueId;
    }
    set issueId(value) {
        const changed = value !== this._issueId;
        this._issueId = value;
        if (changed && this._connected && value) {
            this.activeTab = 'details';
            this.resetEditing();
            this.loadDetail();
        }
    }

    connectedCallback() {
        this._connected = true;
        if (this.isCreate) {
            this.initForm();
        } else if (this._issueId) {
            this.loadDetail();
        }
        this._onKeydown = (event) => this.handleKeydown(event);
        window.addEventListener('keydown', this._onKeydown);
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this._onKeydown);
    }

    renderedCallback() {
        if (this.focusSelector) {
            const el = this.template.querySelector(this.focusSelector);
            if (el) {
                el.focus();
                this.focusSelector = null;
            }
        }
    }

    handleKeydown(event) {
        if (event.key !== 'Escape') return;
        if (this.editingSummary || this.editingDescription || this.commentEditing) {
            this.resetEditing();
            return;
        }
        this.close();
    }

    resetEditing() {
        this.editingSummary = false;
        this.editingDescription = false;
        this.commentEditing = false;
        this.commentDraft = '';
    }

    // ---------------------------------------------------------------- Common getters

    get isCreate() {
        return this.mode === 'create';
    }

    get issue() {
        return (this.issues || []).find((i) => i.id === this._issueId);
    }

    get hasIssue() {
        return !!this.issue;
    }

    get projectKey() {
        return this.project ? this.project.Key__c : '';
    }

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    get openSprints() {
        const current = this.isCreate ? this.form.Sprint__c : this.issue && this.issue.sprintId;
        return (this.sprints || []).filter((s) => s.Status__c !== 'Completed' || s.Id === current);
    }

    sprintOptionsFor(current) {
        return [
            { value: '', label: 'Backlog (no sprint)', selected: !current },
            ...this.openSprints.map((s) => ({
                value: s.Id,
                label: s.Status__c === 'Active' ? `${s.Name} (active)` : s.Name,
                selected: s.Id === current
            }))
        ];
    }

    epicOptionsFor(current, selfId) {
        return [
            { value: '', label: 'None', selected: !current },
            ...(this.issues || [])
                .filter((i) => i.isEpic && i.id !== selfId)
                .map((e) => ({
                    value: e.id,
                    label: `${e.key} · ${e.summary}`,
                    selected: e.id === current
                }))
        ];
    }

    toast(title, message, variant) {
        Toast.show({ label: title, message, variant, mode: 'dismissible' }, this);
    }

    close() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    // ---------------------------------------------------------------- Create mode

    initForm() {
        const d = this.defaults || {};
        this.form = {
            Type__c: d.type || 'Story',
            Status__c: d.status || 'To Do',
            Priority__c: 'Medium',
            Summary__c: '',
            Description__c: '',
            Assignee__c: null,
            Sprint__c: d.sprintId || '',
            Epic__c: d.epicId || '',
            Story_Points__c: null,
            Due_Date__c: null,
            Labels__c: ''
        };
        this.focusSelector = '.create-summary';
    }

    get formTypeOptions() {
        return selectOptions(TYPES, this.form.Type__c);
    }

    get formStatusOptions() {
        return selectOptions(STATUSES, this.form.Status__c);
    }

    get formPriorityOptions() {
        return selectOptions(PRIORITIES, this.form.Priority__c);
    }

    get formSprintOptions() {
        return this.sprintOptionsFor(this.form.Sprint__c);
    }

    get formEpicOptions() {
        return this.epicOptionsFor(this.form.Epic__c, null);
    }

    get formCanHaveEpic() {
        return this.form.Type__c !== 'Epic';
    }

    get formTypeClass() {
        return typeMeta(this.form.Type__c).cls;
    }

    get formTypeIcon() {
        return typeMeta(this.form.Type__c).icon;
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.form = { ...this.form, [field]: value };
    }

    handleFormAssignee(event) {
        this.form = { ...this.form, Assignee__c: event.detail.recordId || null };
    }

    assignFormToMe() {
        this.form = { ...this.form, Assignee__c: this.currentUserId };
    }

    handleCreateKeydown(event) {
        if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
            this.handleCreate();
        }
    }

    async handleCreate() {
        const summary = (this.form.Summary__c || '').trim();
        if (!summary) {
            this.error = 'Summary is required.';
            return;
        }
        const fields = { Project__c: this.project.Id };
        Object.keys(this.form).forEach((key) => {
            const v = this.form[key];
            if (v !== '' && v !== null && v !== undefined) fields[key] = v;
        });
        fields.Summary__c = summary;
        if (fields.Type__c === 'Epic') delete fields.Epic__c;

        this.busy = true;
        this.error = null;
        try {
            const rec = await saveIssue({ fields });
            this.dispatchEvent(new CustomEvent('created', { detail: { id: rec.Id, key: rec.Name } }));
        } catch (e) {
            this.error = reduceErrors(e);
        } finally {
            this.busy = false;
        }
    }

    // ---------------------------------------------------------------- View mode: data

    async loadDetail() {
        const issueId = this._issueId;
        try {
            const detail = await getIssueDetail({ issueId });
            if (issueId !== this._issueId) return;
            this.comments = detail.comments || [];
            this.history = detail.history || [];
        } catch (e) {
            this.toast('Could not load activity', reduceErrors(e), 'error');
        }
    }

    get statusSelectClass() {
        return STATUS_SELECT_CLASS[this.issue.status] || STATUS_SELECT_CLASS['To Do'];
    }

    get statusOptions() {
        return selectOptions(STATUSES, this.issue.status);
    }

    get typeOptions() {
        return selectOptions(TYPES, this.issue.type);
    }

    get priorityOptions() {
        return selectOptions(PRIORITIES, this.issue.priority);
    }

    get sprintOptions() {
        return this.sprintOptionsFor(this.issue.sprintId);
    }

    get epicOptions() {
        return this.epicOptionsFor(this.issue.epicId, this.issue.id);
    }

    get canHaveEpic() {
        return !this.issue.isEpic;
    }

    get parentEpic() {
        const issue = this.issue;
        if (!issue || !issue.epicId) return null;
        return {
            id: issue.epicId,
            label: issue.epicKey,
            style: epicStyle(issue.epicId)
        };
    }

    get children() {
        const issue = this.issue;
        if (!issue || !issue.isEpic) return [];
        return (this.issues || []).filter((i) => i.epicId === issue.id).sort((a, b) => a.rank - b.rank);
    }

    get hasChildren() {
        return this.children.length > 0;
    }

    get childSummary() {
        const children = this.children;
        const done = children.filter((c) => c.isDone).length;
        const pct = children.length ? Math.round((done / children.length) * 100) : 0;
        return {
            text: `${pct}% done · ${done}/${children.length} issues · ${sumPoints(children)} points`,
            style: `width:${pct}%`
        };
    }

    get pointsValue() {
        return this.issue.hasPoints ? this.issue.points : '';
    }

    get commentRows() {
        return this.comments.map((c) => {
            const name = c.CreatedBy ? c.CreatedBy.Name : '';
            return {
                id: c.Id,
                author: name,
                initials: initials(name),
                style: avatarStyle(c.CreatedById),
                body: c.Body__c,
                createdDate: toTime(c.CreatedDate),
                canDelete: c.CreatedById === this.currentUserId
            };
        });
    }

    get hasComments() {
        return this.comments.length > 0;
    }

    get historyRows() {
        return this.history.map((h) => ({
            ...h,
            createdDate: toTime(h.createdDate),
            initials: initials(h.userName),
            style: avatarStyle(h.userName),
            isCreated: h.field === 'created',
            isChange: h.field !== 'created',
            oldText: h.oldValue || 'None',
            newText: h.newValue || 'None'
        }));
    }

    get hasHistory() {
        return this.history.length > 0;
    }

    // ---------------------------------------------------------------- Document tabs

    get tabs() {
        const issue = this.issue;
        const defs = [
            { value: 'details', label: 'Details', icon: 'utility:info', badge: null },
            {
                value: 'brd',
                label: 'BRD',
                icon: 'utility:richtextbulletedlist',
                badge: issue.hasBrd ? '✓' : null
            },
            {
                value: 'tests',
                label: 'Test scripts',
                icon: 'utility:check',
                badge: issue.hasTests ? issue.testsLabel : null
            },
            {
                value: 'files',
                label: 'Attachments',
                icon: 'utility:attach',
                badge: issue.attachments || null
            }
        ];
        return defs.map((t) => ({
            ...t,
            cls: 'doc-tab' + (t.value === this.activeTab ? ' active' : '')
        }));
    }

    get isDetailsTab() {
        return this.activeTab === 'details';
    }

    get isBrdTab() {
        return this.activeTab === 'brd';
    }

    get isTestsTab() {
        return this.activeTab === 'tests';
    }

    get bodyClass() {
        return this.isDetailsTab ? 'detail-body' : 'detail-body wide';
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    /** BRD / test / file changes only affect the board badges - ask the app to refresh. */
    handleDocsChanged() {
        this.dispatchEvent(new CustomEvent('changed'));
    }

    get isCommentsTab() {
        return this.activityTab === 'comments';
    }

    get commentsTabClass() {
        return this.activityTab === 'comments' ? 'tab active' : 'tab';
    }

    get historyTabClass() {
        return this.activityTab === 'history' ? 'tab active' : 'tab';
    }

    get myAvatarStyle() {
        return avatarStyle(this.currentUserId);
    }

    // ---------------------------------------------------------------- View mode: saving

    async saveFields(fields) {
        this.busy = true;
        try {
            await saveIssue({ fields: { Id: this._issueId, ...fields } });
            this.dispatchEvent(new CustomEvent('changed'));
            this.loadDetail();
        } catch (e) {
            this.toast('Could not save', reduceErrors(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    handleSelectChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this.saveFields({ [field]: value === '' ? null : value });
    }

    handleDateChange(event) {
        const value = event.target.value || null;
        if (value === this.issue.dueDate) return;
        this.saveFields({ Due_Date__c: value });
    }

    handleCommitField(event) {
        const field = event.target.dataset.field;
        const value = event.target.value === '' ? null : event.target.value;
        const current = field === 'Story_Points__c' ? this.issue.points : this.issue.labelsText || null;
        if (String(value === null ? '' : value) === String(current === null ? '' : current)) return;
        this.saveFields({ [field]: value });
    }

    handleAssigneeChange(event) {
        const id = event.detail.recordId || null;
        if (id === (this.issue.assigneeId || null)) return;
        this.saveFields({ Assignee__c: id });
    }

    assignToMe() {
        this.saveFields({ Assignee__c: this.currentUserId });
    }

    // Summary
    startEditSummary() {
        this.summaryDraft = this.issue.summary;
        this.editingSummary = true;
        this.focusSelector = '.summary-input';
    }

    handleSummaryInput(event) {
        this.summaryDraft = event.target.value;
    }

    handleSummaryKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.commitSummary();
        }
    }

    commitSummary() {
        if (!this.editingSummary) return;
        this.editingSummary = false;
        const value = (this.summaryDraft || '').trim();
        if (value && value !== this.issue.summary) {
            this.saveFields({ Summary__c: value });
        }
    }

    // Description
    startEditDescription() {
        this.descriptionDraft = this.issue.description;
        this.editingDescription = true;
    }

    handleDescriptionInput(event) {
        this.descriptionDraft = event.target.value;
    }

    saveDescription() {
        this.editingDescription = false;
        if ((this.descriptionDraft || '') !== (this.issue.description || '')) {
            this.saveFields({ Description__c: this.descriptionDraft });
        }
    }

    cancelDescription() {
        this.editingDescription = false;
    }

    // Comments
    showComments() {
        this.activityTab = 'comments';
    }

    showHistory() {
        this.activityTab = 'history';
    }

    startComment() {
        this.commentEditing = true;
        this.commentDraft = '';
    }

    handleCommentInput(event) {
        this.commentDraft = event.target.value;
    }

    cancelComment() {
        this.commentEditing = false;
        this.commentDraft = '';
    }

    async saveComment() {
        if (!this.commentDraft) return;
        this.busy = true;
        try {
            const comment = await addComment({
                issueId: this._issueId,
                body: this.commentDraft
            });
            this.comments = [comment, ...this.comments];
            this.cancelComment();
        } catch (e) {
            this.toast('Could not add comment', reduceErrors(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleDeleteComment(event) {
        const commentId = event.currentTarget.dataset.id;
        const ok = await LightningConfirm.open({
            message: 'Once you delete, it is gone for good.',
            label: 'Delete this comment?',
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteComment({ commentId });
            this.comments = this.comments.filter((c) => c.Id !== commentId);
        } catch (e) {
            this.toast('Could not delete comment', reduceErrors(e), 'error');
        }
    }

    // Navigation & delete
    openRelated(event) {
        this.dispatchEvent(
            new CustomEvent('openissue', {
                detail: { id: event.currentTarget.dataset.id }
            })
        );
    }

    createChild() {
        this.dispatchEvent(new CustomEvent('createchild', { detail: { epicId: this.issue.id } }));
    }

    async handleDelete() {
        const issue = this.issue;
        const ok = await LightningConfirm.open({
            message: `You're about to permanently delete ${issue.key}, its comments and history. Child issues will be unlinked.`,
            label: `Delete ${issue.key}?`,
            theme: 'error'
        });
        if (!ok) return;
        try {
            await deleteIssue({ issueId: issue.id });
            this.dispatchEvent(new CustomEvent('deleted', { detail: { key: issue.key } }));
        } catch (e) {
            this.toast('Could not delete issue', reduceErrors(e), 'error');
        }
    }
}
