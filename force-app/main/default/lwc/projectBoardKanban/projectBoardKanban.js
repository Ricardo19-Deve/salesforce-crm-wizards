/**
 * Kanban board of the active sprint (or all open work when no sprint is active), with HTML5 drag & drop.
 * Gotchas: ranks are fractional (midRank), so a move updates a single record; filters only change what is shown.
 */
import { LightningElement, api } from 'lwc';
import {
    STATUSES,
    midRank,
    initials,
    avatarStyle,
    matchesSearch,
    sumPoints,
    formatShortDate,
    daysBetween,
    todayIso
} from 'c/projectBoardUtils';

export default class ProjectBoardKanban extends LightningElement {
    @api issues = [];
    @api sprints = [];
    @api project;
    @api currentUserId;

    searchTerm = '';
    onlyMine = false;
    selectedAssignees = [];

    dragId;
    dropStatus;
    dropIndex;

    // ---------------------------------------------------------------- Sprint header

    get activeSprint() {
        return (this.sprints || []).find((s) => s.Status__c === 'Active');
    }

    get hasActiveSprint() {
        return !!this.activeSprint;
    }

    get showKanbanHint() {
        return !this.activeSprint;
    }

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    get boardTitle() {
        if (this.activeSprint) return this.activeSprint.Name;
        return this.project ? `${this.project.Key__c} board` : 'Board';
    }

    get sprintGoal() {
        return this.activeSprint ? this.activeSprint.Goal__c : null;
    }

    get sprintMeta() {
        const s = this.activeSprint;
        if (!s || !s.End_Date__c) return '';
        const dates = `${formatShortDate(s.Start_Date__c)} – ${formatShortDate(s.End_Date__c)}`;
        const left = daysBetween(todayIso(), s.End_Date__c);
        let remaining;
        if (left > 1) remaining = `${left} days remaining`;
        else if (left === 1) remaining = '1 day remaining';
        else if (left === 0) remaining = 'Ends today';
        else remaining = `Overdue by ${-left} day${left === -1 ? '' : 's'}`;
        return `${dates} · ${remaining}`;
    }

    get progress() {
        const issues = this.scopeIssues;
        const done = issues.filter((i) => i.isDone);
        const total = sumPoints(issues);
        const usePoints = total > 0;
        const pct = issues.length
            ? Math.round(((usePoints ? sumPoints(done) : done.length) / (usePoints ? total : issues.length)) * 100)
            : 0;
        const detail = usePoints ? `${sumPoints(done)} / ${total} pts` : `${done.length} / ${issues.length} issues`;
        return {
            pct,
            detail,
            style: `--pct:${pct}`,
            title: `${pct}% done · ${detail}`
        };
    }

    // ---------------------------------------------------------------- Filters

    get scopeIssues() {
        const active = this.activeSprint;
        const completed = new Set((this.sprints || []).filter((s) => s.Status__c === 'Completed').map((s) => s.Id));
        return (this.issues || []).filter(
            (i) => !i.isEpic && (active ? i.sprintId === active.Id : !completed.has(i.sprintId))
        );
    }

    get assignees() {
        const seen = new Map();
        this.scopeIssues.forEach((i) => {
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

    get filteredIssues() {
        return this.scopeIssues.filter(
            (i) =>
                matchesSearch(i, this.searchTerm) &&
                (!this.onlyMine || i.assigneeId === this.currentUserId) &&
                (!this.selectedAssignees.length || this.selectedAssignees.includes(i.assigneeId))
        );
    }

    get hasFilters() {
        return !!this.searchTerm || this.onlyMine || this.selectedAssignees.length > 0;
    }

    get onlyMineClass() {
        return this.onlyMine ? 'btn btn-selected' : 'btn btn-subtle';
    }

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

    clearFilters() {
        this.searchTerm = '';
        this.onlyMine = false;
        this.selectedAssignees = [];
    }

    // ---------------------------------------------------------------- Columns

    columnIssues(status) {
        return this.filteredIssues.filter((i) => i.status === status).sort((a, b) => a.rank - b.rank);
    }

    get columns() {
        return STATUSES.map((status) => {
            const items = this.columnIssues(status);
            const isTarget = !!this.dragId && this.dropStatus === status;
            let index = 0;
            const cards = items.map((issue) => {
                let cardClass = 'card';
                if (issue.id === this.dragId) {
                    cardClass += ' dragging';
                } else {
                    if (isTarget && index === this.dropIndex) cardClass += ' drop-before';
                    index++;
                }
                return { ...issue, cardClass };
            });
            const points = sumPoints(items);
            return {
                status,
                cards,
                count: items.length,
                points,
                hasPoints: points > 0,
                isDone: status === 'Done',
                dotClass: 'dot dot-' + status.toLowerCase().replace(/\s+/g, '-'),
                isEmpty: items.length === 0,
                columnClass: 'column' + (isTarget ? ' column-over' : ''),
                endClass: 'drop-end' + (isTarget && this.dropIndex >= index ? ' active' : '')
            };
        });
    }

    // ---------------------------------------------------------------- Drag & drop

    handleDragStart(event) {
        this.dragId = event.currentTarget.dataset.id;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this.dragId);
    }

    handleDragOver(event) {
        if (!this.dragId) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        const column = event.currentTarget;
        const cards = [...column.querySelectorAll('.card')].filter((c) => c.dataset.id !== this.dragId);
        let index = cards.length;
        for (let i = 0; i < cards.length; i++) {
            const rect = cards[i].getBoundingClientRect();
            if (event.clientY < rect.top + rect.height / 2) {
                index = i;
                break;
            }
        }
        const status = column.dataset.status;
        if (status !== this.dropStatus || index !== this.dropIndex) {
            this.dropStatus = status;
            this.dropIndex = index;
        }
    }

    handleDragLeave(event) {
        if (
            !event.currentTarget.contains(event.relatedTarget) &&
            this.dropStatus === event.currentTarget.dataset.status
        ) {
            this.dropStatus = null;
        }
    }

    handleDrop(event) {
        event.preventDefault();
        const id = this.dragId;
        const status = this.dropStatus;
        const index = this.dropIndex;
        this.resetDrag();
        if (!id || !status) return;

        const dragged = this.issues.find((i) => i.id === id);
        const target = this.columnIssues(status);
        if (dragged.status === status && target.findIndex((i) => i.id === id) === index) return;

        const others = target.filter((i) => i.id !== id);
        const prev = others[index - 1];
        const next = others[index];
        this.dispatchEvent(
            new CustomEvent('move', {
                detail: {
                    id,
                    status: dragged.status !== status ? status : null,
                    changeSprint: false,
                    rank: midRank(prev && prev.rank, next && next.rank)
                }
            })
        );
    }

    handleDragEnd() {
        this.resetDrag();
    }

    resetDrag() {
        this.dragId = null;
        this.dropStatus = null;
        this.dropIndex = null;
    }

    // ---------------------------------------------------------------- Actions

    handleCardClick(event) {
        this.dispatchEvent(
            new CustomEvent('openissue', {
                detail: { id: event.currentTarget.dataset.id }
            })
        );
    }

    handleCreateInColumn(event) {
        this.dispatchEvent(
            new CustomEvent('create', {
                detail: {
                    status: event.currentTarget.dataset.status,
                    sprintId: this.activeSprint ? this.activeSprint.Id : null
                }
            })
        );
    }

    handleCompleteSprint() {
        this.dispatchEvent(
            new CustomEvent('completesprint', {
                detail: { sprintId: this.activeSprint.Id }
            })
        );
    }

    handleGoToBacklog() {
        this.dispatchEvent(new CustomEvent('navigate', { detail: { view: 'backlog' } }));
    }
}
