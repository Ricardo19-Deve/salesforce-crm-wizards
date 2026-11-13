/**
 * Sortable, filterable list of every issue of the project (including epics and done work).
 */
import { LightningElement, api } from 'lwc';
import { STATUSES, TYPES, PRIORITIES, matchesSearch, keyNumber } from 'c/projectBoardUtils';

const ALL = '';

const COLUMNS = [
    { field: 'type', label: 'T', cls: 'col-type' },
    { field: 'key', label: 'Key', cls: 'col-key' },
    { field: 'summary', label: 'Summary', cls: 'col-summary' },
    { field: 'status', label: 'Status', cls: 'col-status' },
    { field: 'priority', label: 'P', cls: 'col-prio' },
    { field: 'assigneeName', label: 'Assignee', cls: 'col-assignee' },
    { field: 'sprintName', label: 'Sprint', cls: 'col-sprint' },
    { field: 'points', label: 'Points', cls: 'col-points' },
    { field: 'dueDate', label: 'Due', cls: 'col-date' },
    { field: 'lastModifiedDate', label: 'Updated', cls: 'col-date' }
];

export default class ProjectBoardIssueList extends LightningElement {
    @api issues = [];
    @api project;

    _search = '';
    statusFilter = ALL;
    typeFilter = ALL;
    priorityFilter = ALL;
    assigneeFilter = ALL;
    hideDone = false;
    sortField = 'lastModifiedDate';
    sortAsc = false;

    @api
    get searchTerm() {
        return this._search;
    }
    set searchTerm(value) {
        this._search = value || '';
    }

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    get statusOptions() {
        return [{ label: 'All statuses', value: ALL }, ...STATUSES.map((s) => ({ label: s, value: s }))];
    }

    get typeOptions() {
        return [{ label: 'All types', value: ALL }, ...TYPES.map((s) => ({ label: s, value: s }))];
    }

    get priorityOptions() {
        return [{ label: 'All priorities', value: ALL }, ...PRIORITIES.map((s) => ({ label: s, value: s }))];
    }

    get assigneeOptions() {
        const seen = new Map();
        (this.issues || []).forEach((i) => {
            if (i.assigneeId) seen.set(i.assigneeId, i.assigneeName);
        });
        const users = [...seen.entries()]
            .sort((a, b) => a[1].localeCompare(b[1]))
            .map(([value, label]) => ({ label, value }));
        return [{ label: 'All assignees', value: ALL }, { label: 'Unassigned', value: 'none' }, ...users];
    }

    get filters() {
        const mark = (options, current) => options.map((o) => ({ ...o, selected: o.value === current }));
        return [
            {
                key: 'statusFilter',
                label: 'Status',
                options: mark(this.statusOptions, this.statusFilter)
            },
            {
                key: 'typeFilter',
                label: 'Type',
                options: mark(this.typeOptions, this.typeFilter)
            },
            {
                key: 'priorityFilter',
                label: 'Priority',
                options: mark(this.priorityOptions, this.priorityFilter)
            },
            {
                key: 'assigneeFilter',
                label: 'Assignee',
                options: mark(this.assigneeOptions, this.assigneeFilter)
            }
        ];
    }

    get columns() {
        return COLUMNS.map((c) => ({
            ...c,
            thClass: `${c.cls} sortable`,
            isSorted: c.field === this.sortField,
            sortIcon: this.sortAsc ? 'utility:arrowup' : 'utility:arrowdown'
        }));
    }

    get rows() {
        const term = this._search;
        const filtered = (this.issues || []).filter(
            (i) =>
                matchesSearch(i, term) &&
                (!this.statusFilter || i.status === this.statusFilter) &&
                (!this.typeFilter || i.type === this.typeFilter) &&
                (!this.priorityFilter || i.priority === this.priorityFilter) &&
                (!this.assigneeFilter ||
                    (this.assigneeFilter === 'none' ? !i.assigneeId : i.assigneeId === this.assigneeFilter)) &&
                (!this.hideDone || !i.isDone)
        );
        const field = this.sortField;
        const dir = this.sortAsc ? 1 : -1;
        const prioOrder = (p) => PRIORITIES.indexOf(p);
        const statusOrder = (s) => STATUSES.indexOf(s);
        return filtered.sort((a, b) => {
            let va = a[field];
            let vb = b[field];
            if (field === 'key') {
                va = keyNumber(a.key);
                vb = keyNumber(b.key);
            } else if (field === 'priority') {
                va = prioOrder(a.priority);
                vb = prioOrder(b.priority);
            } else if (field === 'status') {
                va = statusOrder(a.status);
                vb = statusOrder(b.status);
            }
            if (va === vb) return 0;
            if (va === null || va === undefined || va === '') return 1;
            if (vb === null || vb === undefined || vb === '') return -1;
            return (va > vb ? 1 : -1) * dir;
        });
    }

    get count() {
        return this.rows.length;
    }

    get isEmpty() {
        return this.count === 0;
    }

    handleSearch(event) {
        this._search = event.target.value;
    }

    handleFilter(event) {
        this[event.target.dataset.filter] = event.target.value;
    }

    handleHideDone(event) {
        this.hideDone = event.target.checked;
    }

    handleSort(event) {
        const field = event.currentTarget.dataset.field;
        if (this.sortField === field) {
            this.sortAsc = !this.sortAsc;
        } else {
            this.sortField = field;
            this.sortAsc = field === 'key' || field === 'summary' || field === 'assigneeName';
        }
    }

    handleRowClick(event) {
        this.dispatchEvent(
            new CustomEvent('openissue', {
                detail: { id: event.currentTarget.dataset.id }
            })
        );
    }
}
