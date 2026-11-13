/**
 * Backlog: open sprints + backlog sections, epics panel, quick create and drag & drop between sprints.
 */
import { LightningElement, api } from 'lwc';
import {
    TYPES,
    midRank,
    initials,
    avatarStyle,
    epicStyle,
    matchesSearch,
    sumPoints,
    formatShortDate
} from 'c/projectBoardUtils';

const BACKLOG = '__backlog';

export default class ProjectBoardBacklog extends LightningElement {
    @api issues = [];
    @api sprints = [];
    @api project;
    @api currentUserId;

    searchTerm = '';
    onlyMine = false;
    selectedAssignees = [];
    epicFilter = null;
    showEpics = true;
    collapsed = {};

    quickSection = null;
    quickSummary = '';
    quickType = 'Story';
    focusQuick = false;

    dragId;
    dropSection;
    dropIndex;

    renderedCallback() {
        if (this.focusQuick) {
            const input = this.template.querySelector('.quick-input');
            if (input) {
                input.focus();
                this.focusQuick = false;
            }
        }
    }

    // ---------------------------------------------------------------- Data

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    get openSprints() {
        return (this.sprints || [])
            .filter((s) => s.Status__c !== 'Completed')
            .sort((a, b) => {
                if (a.Status__c === 'Active' && b.Status__c !== 'Active') return -1;
                if (b.Status__c === 'Active' && a.Status__c !== 'Active') return 1;
                return (a.Sequence__c || 0) - (b.Sequence__c || 0);
            });
    }

    get hasActiveSprint() {
        return (this.sprints || []).some((s) => s.Status__c === 'Active');
    }

    get workIssues() {
        return (this.issues || []).filter((i) => !i.isEpic);
    }

    get filteredIssues() {
        return this.workIssues.filter(
            (i) =>
                matchesSearch(i, this.searchTerm) &&
                (!this.onlyMine || i.assigneeId === this.currentUserId) &&
                (!this.selectedAssignees.length || this.selectedAssignees.includes(i.assigneeId)) &&
                (!this.epicFilter || i.epicId === this.epicFilter)
        );
    }

    get assignees() {
        const seen = new Map();
        this.workIssues.forEach((i) => {
            if (i.assigneeId && !seen.has(i.assigneeId)) seen.set(i.assigneeId, i.assigneeName);
        });
        return [...seen.entries()].map(([id, name]) => ({
            id,
            name,
            initials: initials(name),
            style: avatarStyle(id),
            cls: 'avatar avatar-filter' + (this.selectedAssignees.includes(id) ? ' selected' : '')
        }));
    }

    get epics() {
        return (this.issues || [])
            .filter((i) => i.isEpic)
            .map((epic) => {
                const children = this.workIssues.filter((i) => i.epicId === epic.id);
                const done = children.filter((i) => i.isDone).length;
                const pct = children.length ? Math.round((done / children.length) * 100) : 0;
                return {
                    ...epic,
                    chipStyle: epicStyle(epic.id),
                    progressStyle: `width:${pct}%`,
                    progressText: `${done}/${children.length} done`,
                    itemClass: 'epic-item' + (this.epicFilter === epic.id ? ' selected' : '')
                };
            });
    }

    get hasEpics() {
        return this.epics.length > 0;
    }

    get epicToggleClass() {
        return this.showEpics ? 'btn btn-selected' : 'btn btn-subtle';
    }

    get onlyMineClass() {
        return this.onlyMine ? 'btn btn-selected' : 'btn btn-subtle';
    }

    get hasFilters() {
        return !!this.searchTerm || this.onlyMine || this.selectedAssignees.length > 0 || !!this.epicFilter;
    }

    get layoutClass() {
        return this.showEpics ? 'layout with-epics' : 'layout';
    }

    get typeOptions() {
        return TYPES.filter((t) => t !== 'Epic').map((t) => ({
            value: t,
            label: t,
            selected: t === this.quickType
        }));
    }

    get sections() {
        const filtered = this.filteredIssues;
        const result = this.openSprints.map((s) => this.buildSection(s.Id, s, filtered));
        result.push(this.buildSection(BACKLOG, null, filtered));
        return result;
    }

    buildSection(key, sprint, filtered) {
        const items = filtered
            .filter((i) => (sprint ? i.sprintId === sprint.Id : !i.sprintId))
            .sort((a, b) => a.rank - b.rank);
        const isTarget = !!this.dragId && this.dropSection === key;
        let index = 0;
        const rows = items.map((issue) => {
            let rowClass = 'row';
            if (issue.id === this.dragId) {
                rowClass += ' dragging';
            } else {
                if (isTarget && index === this.dropIndex) rowClass += ' drop-before';
                index++;
            }
            return { ...issue, rowClass };
        });
        const isActive = !!sprint && sprint.Status__c === 'Active';
        const isPlanned = !!sprint && sprint.Status__c === 'Planned';
        const collapsed = !!this.collapsed[key];
        let meta = '';
        if (sprint && sprint.Start_Date__c && sprint.End_Date__c) {
            meta = `${formatShortDate(sprint.Start_Date__c)} – ${formatShortDate(sprint.End_Date__c)}`;
        }
        return {
            key,
            sprintId: sprint ? sprint.Id : null,
            title: sprint ? sprint.Name : 'Backlog',
            meta,
            goal: sprint ? sprint.Goal__c : null,
            countText: `(${items.length} issue${items.length === 1 ? '' : 's'})`,
            isActive,
            isPlanned,
            isBacklog: !sprint,
            startDisabled: this.hasActiveSprint,
            expanded: !collapsed,
            chevron: collapsed ? 'utility:chevronright' : 'utility:chevrondown',
            rows,
            isEmpty: items.length === 0,
            emptyText: sprint ? 'Plan a sprint by dragging issues from the backlog here.' : 'Your backlog is empty.',
            todoPts: sumPoints(items.filter((i) => i.status === 'To Do')),
            progressPts: sumPoints(items.filter((i) => i.status === 'In Progress' || i.status === 'In Review')),
            donePts: sumPoints(items.filter((i) => i.status === 'Done')),
            sectionClass: sprint ? 'section section-sprint' : 'section section-backlog',
            bodyClass: 'section-body' + (isTarget ? ' over' : ''),
            endClass: 'drop-end' + (isTarget && this.dropIndex >= index ? ' active' : ''),
            quickOpen: this.quickSection === key
        };
    }

    // ---------------------------------------------------------------- Filters

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    toggleAssignee(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedAssignees = this.selectedAssignees.includes(id)
            ? this.selectedAssignees.filter((a) => a !== id)
            : [...this.selectedAssignees, id];
    }

    toggleOnlyMine() {
        this.onlyMine = !this.onlyMine;
    }

    toggleEpics() {
        this.showEpics = !this.showEpics;
    }

    clearFilters() {
        this.searchTerm = '';
        this.onlyMine = false;
        this.selectedAssignees = [];
        this.epicFilter = null;
    }

    handleEpicClick(event) {
        const id = event.currentTarget.dataset.id;
        this.epicFilter = this.epicFilter === id ? null : id;
    }

    handleEpicOpen(event) {
        event.stopPropagation();
        this.fire('openissue', { id: event.currentTarget.dataset.id });
    }

    handleCreateEpic() {
        this.fire('create', { type: 'Epic' });
    }

    toggleSection(event) {
        const key = event.currentTarget.dataset.key;
        this.collapsed = { ...this.collapsed, [key]: !this.collapsed[key] };
    }

    // ---------------------------------------------------------------- Sprint actions

    handleCreateSprint() {
        this.fire('createsprint', {});
    }

    handleStartSprint(event) {
        this.fire('startsprint', { sprintId: event.currentTarget.dataset.id });
    }

    handleCompleteSprint(event) {
        this.fire('completesprint', { sprintId: event.currentTarget.dataset.id });
    }

    handleDeleteSprint(event) {
        this.fire('deletesprint', { sprintId: event.currentTarget.dataset.id });
    }

    // ---------------------------------------------------------------- Quick create

    openQuickCreate(event) {
        this.quickSection = event.currentTarget.dataset.key;
        this.quickSummary = '';
        this.focusQuick = true;
    }

    handleQuickType(event) {
        this.quickType = event.target.value;
    }

    handleQuickInput(event) {
        this.quickSummary = event.target.value;
    }

    handleQuickKey(event) {
        if (event.key === 'Enter') {
            this.submitQuickCreate();
        } else if (event.key === 'Escape') {
            this.quickSection = null;
        }
    }

    submitQuickCreate() {
        const summary = (this.quickSummary || '').trim();
        if (!summary) return;
        this.fire('quickcreate', {
            summary,
            type: this.quickType,
            sprintId: this.quickSection === BACKLOG ? null : this.quickSection,
            epicId: this.epicFilter
        });
        this.quickSummary = '';
        const input = this.template.querySelector('.quick-input');
        if (input) input.value = '';
    }

    cancelQuickCreate() {
        this.quickSection = null;
    }

    // ---------------------------------------------------------------- Drag & drop

    handleRowClick(event) {
        this.fire('openissue', { id: event.currentTarget.dataset.id });
    }

    handleDragStart(event) {
        this.dragId = event.currentTarget.dataset.id;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this.dragId);
    }

    handleDragOver(event) {
        if (!this.dragId) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        const body = event.currentTarget;
        const rows = [...body.querySelectorAll('.row')].filter((r) => r.dataset.id !== this.dragId);
        let index = rows.length;
        for (let i = 0; i < rows.length; i++) {
            const rect = rows[i].getBoundingClientRect();
            if (event.clientY < rect.top + rect.height / 2) {
                index = i;
                break;
            }
        }
        const key = body.dataset.key;
        if (key !== this.dropSection || index !== this.dropIndex) {
            this.dropSection = key;
            this.dropIndex = index;
        }
    }

    handleDragLeave(event) {
        if (
            !event.currentTarget.contains(event.relatedTarget) &&
            this.dropSection === event.currentTarget.dataset.key
        ) {
            this.dropSection = null;
        }
    }

    handleDrop(event) {
        event.preventDefault();
        const id = this.dragId;
        const key = this.dropSection;
        const index = this.dropIndex;
        this.resetDrag();
        if (!id || !key) return;

        const sprintId = key === BACKLOG ? null : key;
        const dragged = this.issues.find((i) => i.id === id);
        const target = this.filteredIssues
            .filter((i) => (sprintId ? i.sprintId === sprintId : !i.sprintId))
            .sort((a, b) => a.rank - b.rank);
        const sameSection = (dragged.sprintId || null) === sprintId;
        if (sameSection && target.findIndex((i) => i.id === id) === index) return;

        const others = target.filter((i) => i.id !== id);
        const prev = others[index - 1];
        const next = others[index];
        this.fire('move', {
            id,
            status: null,
            changeSprint: !sameSection,
            sprintId,
            rank: midRank(prev && prev.rank, next && next.rank)
        });
    }

    handleDragEnd() {
        this.resetDrag();
    }

    resetDrag() {
        this.dragId = null;
        this.dropSection = null;
        this.dropIndex = null;
    }

    fire(name, detail) {
        this.dispatchEvent(new CustomEvent(name, { detail }));
    }
}
