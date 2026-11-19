/**
 * Kanban board of the active sprint (or all open work when no sprint is active), with HTML5 drag & drop and a
 * full keyboard alternative: arrows move the focus between cards, Space picks a card up, arrows choose the target
 * column and position, Space drops it and Escape cancels. A live region announces every step.
 * Gotchas: ranks are fractional (midRank), so a move updates a single record; filters only change what is shown.
 * Only one card is in the Tab order at a time (roving tabindex). Viewers (readOnly) can browse but not move.
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
    @api readOnly = false;

    searchTerm = '';
    onlyMine = false;
    selectedAssignees = [];

    dragId;
    dropStatus;
    dropIndex;
    keyboardLift = false;

    focusId;
    pendingFocusId;
    announcement = '';

    /** Puts the keyboard focus back on a card (e.g. after its issue modal closes). */
    @api
    focusIssue(id) {
        this.focusId = id;
        this.pendingFocusId = id;
        // The parent may still be re-rendering (e.g. removing a modal): focus once that has settled
        Promise.resolve()
            .then(() => Promise.resolve())
            .then(() => this.applyPendingFocus());
    }

    applyPendingFocus() {
        if (!this.pendingFocusId) return;
        const el = this.template.querySelector(`.card[data-id="${this.pendingFocusId}"]`);
        if (el) {
            el.focus();
            this.pendingFocusId = null;
        }
    }

    renderedCallback() {
        this.applyPendingFocus();
    }

    // ---------------------------------------------------------------- Sprint header

    get activeSprint() {
        return (this.sprints || []).find((s) => s.Status__c === 'Active');
    }

    get hasActiveSprint() {
        return !!this.activeSprint;
    }

    get canCompleteSprint() {
        return this.hasActiveSprint && !this.readOnly;
    }

    get showKanbanHint() {
        return !this.activeSprint;
    }

    get canEdit() {
        return !this.readOnly;
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
        return [...seen.entries()].map(([id, name]) => {
            const selected = this.selectedAssignees.includes(id);
            return {
                id,
                name,
                initials: initials(name),
                style: avatarStyle(id),
                label: `Show only issues assigned to ${name}`,
                pressed: selected ? 'true' : 'false',
                cls: 'avatar avatar-filter' + (selected ? ' selected' : '')
            };
        });
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

    get onlyMinePressed() {
        return this.onlyMine ? 'true' : 'false';
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

    /** Card that owns the Tab stop: the last focused card, or the first card of the board. */
    get tabStopId() {
        const visible = this.filteredIssues;
        if (this.focusId && visible.some((i) => i.id === this.focusId)) return this.focusId;
        for (const status of STATUSES) {
            const first = this.columnIssues(status)[0];
            if (first) return first.id;
        }
        return null;
    }

    get columns() {
        const tabStop = this.tabStopId;
        return STATUSES.map((status) => {
            const items = this.columnIssues(status);
            const isTarget = !!this.dragId && this.dropStatus === status;
            let index = 0;
            const cards = items.map((issue) => {
                let cardClass = 'card';
                if (issue.id === this.dragId) {
                    cardClass += this.keyboardLift ? ' lifted' : ' dragging';
                } else {
                    if (isTarget && index === this.dropIndex) cardClass += ' drop-before';
                    index++;
                }
                const points = issue.hasPoints ? `, ${issue.points} points` : '';
                return {
                    ...issue,
                    cardClass,
                    tabIndex: issue.id === tabStop ? '0' : '-1',
                    ariaLabel:
                        `${issue.key}: ${issue.summary}. ${issue.type}, ${issue.priority} priority${points}, ` +
                        `${issue.assigneeId ? 'assigned to ' + issue.assigneeName : 'unassigned'}.`
                };
            });
            const points = sumPoints(items);
            return {
                status,
                cards,
                count: items.length,
                points,
                hasPoints: points > 0,
                isDone: status === 'Done',
                ariaLabel: `${status}, ${items.length} issue${items.length === 1 ? '' : 's'}`,
                dotClass: 'dot dot-' + status.toLowerCase().replace(/\s+/g, '-'),
                isEmpty: items.length === 0,
                columnClass: 'column' + (isTarget ? ' column-over' : ''),
                endClass: 'drop-end' + (isTarget && this.dropIndex >= index ? ' active' : '')
            };
        });
    }

    get draggableValue() {
        return this.readOnly ? 'false' : 'true';
    }

    // ---------------------------------------------------------------- Mouse drag & drop

    handleDragStart(event) {
        if (this.readOnly) {
            event.preventDefault();
            return;
        }
        this.keyboardLift = false;
        this.dragId = event.currentTarget.dataset.id;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this.dragId);
    }

    handleDragOver(event) {
        if (!this.dragId || this.keyboardLift) return;
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
            !this.keyboardLift &&
            !event.currentTarget.contains(event.relatedTarget) &&
            this.dropStatus === event.currentTarget.dataset.status
        ) {
            this.dropStatus = null;
        }
    }

    handleDrop(event) {
        event.preventDefault();
        if (this.keyboardLift) return;
        const id = this.dragId;
        const status = this.dropStatus;
        const index = this.dropIndex;
        this.resetDrag();
        if (id && status) this.commitMove(id, status, index);
    }

    handleDragEnd() {
        if (!this.keyboardLift) this.resetDrag();
    }

    resetDrag() {
        this.dragId = null;
        this.dropStatus = null;
        this.dropIndex = null;
        this.keyboardLift = false;
    }

    /** Moves an issue to a column and a position among the other cards of that column. */
    commitMove(id, status, index) {
        const dragged = this.issues.find((i) => i.id === id);
        const target = this.columnIssues(status);
        if (dragged.status === status && target.findIndex((i) => i.id === id) === index) return false;
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
        return true;
    }

    // ---------------------------------------------------------------- Keyboard

    /** Card ids per column, in display order. */
    get grid() {
        return STATUSES.map((status) => this.columnIssues(status).map((i) => i.id));
    }

    position(id) {
        const grid = this.grid;
        for (let c = 0; c < grid.length; c++) {
            const r = grid[c].indexOf(id);
            if (r >= 0) return { c, r };
        }
        return null;
    }

    handleCardFocus(event) {
        this.focusId = event.currentTarget.dataset.id;
    }

    handleCardKeydown(event) {
        const id = event.currentTarget.dataset.id;
        if (this.keyboardLift) {
            this.handleLiftedKey(event);
            return;
        }
        const pos = this.position(id);
        if (!pos) return;
        const grid = this.grid;
        let targetId = null;
        switch (event.key) {
            case 'Enter':
                event.preventDefault();
                this.open(id);
                return;
            case ' ':
            case 'Spacebar':
                event.preventDefault();
                this.lift(id, pos);
                return;
            case 'ArrowUp':
                targetId = grid[pos.c][Math.max(0, pos.r - 1)];
                break;
            case 'ArrowDown':
                targetId = grid[pos.c][Math.min(grid[pos.c].length - 1, pos.r + 1)];
                break;
            case 'Home':
                targetId = grid[pos.c][0];
                break;
            case 'End':
                targetId = grid[pos.c][grid[pos.c].length - 1];
                break;
            case 'ArrowLeft':
            case 'ArrowRight': {
                const step = event.key === 'ArrowLeft' ? -1 : 1;
                for (let c = pos.c + step; c >= 0 && c < grid.length; c += step) {
                    if (grid[c].length) {
                        targetId = grid[c][Math.min(pos.r, grid[c].length - 1)];
                        break;
                    }
                }
                break;
            }
            default:
                return;
        }
        event.preventDefault();
        if (targetId && targetId !== id) this.focusIssue(targetId);
    }

    lift(id, pos) {
        const issue = this.issues.find((i) => i.id === id);
        if (this.readOnly) {
            this.announce('You can view this board but not move issues. Ask a project lead for the Member role.');
            return;
        }
        this.keyboardLift = true;
        this.dragId = id;
        this.dropStatus = STATUSES[pos.c];
        this.dropIndex = pos.r;
        this.announce(
            `Picked up ${issue.key}. ${this.targetText()}. Use the arrow keys to move, Space to drop, Escape to cancel.`
        );
    }

    handleLiftedKey(event) {
        const id = this.dragId;
        const c = STATUSES.indexOf(this.dropStatus);
        const othersIn = (status) => this.columnIssues(status).filter((i) => i.id !== id).length;
        switch (event.key) {
            case 'ArrowUp':
                this.dropIndex = Math.max(0, this.dropIndex - 1);
                break;
            case 'ArrowDown':
                this.dropIndex = Math.min(othersIn(this.dropStatus), this.dropIndex + 1);
                break;
            case 'ArrowLeft':
            case 'ArrowRight': {
                const nextC = c + (event.key === 'ArrowLeft' ? -1 : 1);
                if (nextC < 0 || nextC >= STATUSES.length) break;
                this.dropStatus = STATUSES[nextC];
                this.dropIndex = Math.min(this.dropIndex, othersIn(this.dropStatus));
                break;
            }
            case ' ':
            case 'Spacebar':
            case 'Enter': {
                event.preventDefault();
                const issue = this.issues.find((i) => i.id === id);
                const status = this.dropStatus;
                const index = this.dropIndex;
                const text = this.targetText();
                this.resetDrag();
                const moved = this.commitMove(id, status, index);
                this.focusIssue(id);
                this.announce(moved ? `Dropped ${issue.key}. ${text}.` : `${issue.key} stays where it was.`);
                return;
            }
            case 'Escape':
            case 'Tab': {
                if (event.key === 'Escape') event.preventDefault();
                const issue = this.issues.find((i) => i.id === id);
                this.resetDrag();
                this.announce(`Move cancelled. ${issue.key} stays where it was.`);
                return;
            }
            default:
                return;
        }
        event.preventDefault();
        this.announce(this.targetText());
    }

    targetText() {
        const total = this.columnIssues(this.dropStatus).filter((i) => i.id !== this.dragId).length + 1;
        return `${this.dropStatus}, position ${this.dropIndex + 1} of ${total}`;
    }

    announce(text) {
        // A trailing non-breaking space forces screen readers to repeat identical messages
        this.announcement = this.announcement === text ? text + '\u00a0' : text;
    }

    // ---------------------------------------------------------------- Actions

    open(id) {
        this.dispatchEvent(new CustomEvent('openissue', { detail: { id } }));
    }

    handleCardClick(event) {
        this.open(event.currentTarget.dataset.id);
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
