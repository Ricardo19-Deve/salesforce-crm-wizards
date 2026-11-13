/**
 * Shell of the Project Board: sidebar, top bar, theme, routing between Board / Backlog / Issues / Reports, and the
 * project and sprint dialogs. Loads everything with ProjectBoardController.getBoardData and passes it down.
 *
 * Where to configure: App Builder / Experience Builder properties (fullScreen, brandName, appName, logoUrl).
 * Gotchas: design tokens (--jx-*) live on .jx-root here and are inherited by every child component; moves are
 * optimistic (the card moves first, the server call follows and a failure reloads the board).
 */
import { LightningElement, api } from 'lwc';
import Toast from 'lightning/toast';
import LightningConfirm from 'lightning/confirm';
import getProjects from '@salesforce/apex/ProjectBoardController.getProjects';
import getBoardData from '@salesforce/apex/ProjectBoardController.getBoardData';
import createProject from '@salesforce/apex/ProjectBoardController.createProject';
import saveIssue from '@salesforce/apex/ProjectBoardController.saveIssue';
import moveIssue from '@salesforce/apex/ProjectBoardController.moveIssue';
import createSprint from '@salesforce/apex/ProjectBoardController.createSprint';
import startSprint from '@salesforce/apex/ProjectBoardController.startSprint';
import completeSprint from '@salesforce/apex/ProjectBoardController.completeSprint';
import deleteSprint from '@salesforce/apex/ProjectBoardController.deleteSprint';
import {
    decorateIssue,
    reduceErrors,
    avatarStyle,
    initials,
    todayIso,
    addDaysIso,
    syncTextareas
} from 'c/projectBoardUtils';

const STORAGE_KEY = 'projectBoard.projectId';
const THEME_KEY = 'projectBoard.theme';

const NAV = [
    { view: 'board', label: 'Board', icon: 'utility:kanban' },
    { view: 'backlog', label: 'Backlog', icon: 'utility:rows' },
    { view: 'issues', label: 'Issues', icon: 'utility:table' },
    { view: 'reports', label: 'Reports', icon: 'utility:chart' }
];

const DURATIONS = [
    { value: '1', label: '1 week' },
    { value: '2', label: '2 weeks' },
    { value: '3', label: '3 weeks' },
    { value: '4', label: '4 weeks' },
    { value: 'custom', label: 'Custom' }
];

function suggestKey(name) {
    const words = (name || '')
        .toUpperCase()
        .replace(/[^A-Z0-9 ]/g, '')
        .trim()
        .split(/\s+/)
        .filter((w) => w);
    if (!words.length) return '';
    let key = words.length > 1 ? words.map((w) => w.charAt(0)).join('') : words[0].slice(0, 4);
    if (key.length < 2) key = words.join('').slice(0, 3);
    if (!/^[A-Z]/.test(key)) key = 'P' + key;
    return key.slice(0, 10);
}

function readStored(key) {
    try {
        return window.localStorage.getItem(key);
    } catch {
        return null;
    }
}

function store(key, value) {
    try {
        window.localStorage.setItem(key, value);
    } catch {
        // storage unavailable - preference just won't persist
    }
}

function initialTheme() {
    const stored = readStored(THEME_KEY);
    if (stored === 'light' || stored === 'dark') return stored;
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export default class ProjectBoardApp extends LightningElement {
    /** Fill the whole viewport (used by the Project Board Experience site). */
    @api fullScreen = false;
    /** Branding shown in the sidebar (configurable in Experience Builder). */
    @api brandName = 'Contoso';
    @api appName = 'Project Board';
    @api logoUrl;

    projects = [];
    projectId;
    project;
    sprints = [];
    issues = [];
    currentUserId;
    currentUserName = '';
    theme = initialTheme();
    userMenuOpen = false;

    view = 'board';
    loading = true;
    loaded = false;
    globalSearch = '';

    selectedIssueId;
    createOpen = false;
    createDefaults = {};

    projectDialog = null;
    sprintDialog = null;
    completeDialog = null;
    dialogBusy = false;
    dialogError;

    connectedCallback() {
        this.loadProjects();
        this._onKeydown = (event) => {
            if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
                event.preventDefault();
                const input = this.template.querySelector('.global-search-input');
                if (input) input.focus();
            }
        };
        window.addEventListener('keydown', this._onKeydown);
    }

    renderedCallback() {
        syncTextareas(this.template);
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this._onKeydown);
    }

    // ---------------------------------------------------------------- Loading

    async loadProjects(selectId) {
        this.loading = true;
        try {
            this.projects = await getProjects();
            let id = selectId || this.projectId || readStored(STORAGE_KEY);
            if (!this.projects.some((p) => p.Id === id)) {
                id = this.projects.length ? this.projects[0].Id : null;
            }
            this.projectId = id;
            if (id) {
                store(STORAGE_KEY, id);
                await this.loadBoard();
            } else {
                this.project = null;
                this.issues = [];
                this.sprints = [];
            }
        } catch (e) {
            this.toastError('Could not load projects', e);
        } finally {
            this.loading = false;
            this.loaded = true;
        }
    }

    async loadBoard() {
        if (!this.projectId) return;
        try {
            const data = await getBoardData({ projectId: this.projectId });
            this.project = data.project;
            this.sprints = data.sprints || [];
            this.currentUserId = data.currentUserId;
            this.currentUserName = data.currentUserName;
            const stats = data.stats || {};
            this.issues = (data.issues || []).map((r) => decorateIssue(r, stats[r.Id]));
        } catch (e) {
            this.toastError('Could not load project', e);
        }
    }

    // ---------------------------------------------------------------- Getters

    get rootClass() {
        return `jx-root theme-${this.theme} ${this.fullScreen ? 'jx-full' : 'jx-embedded'}`;
    }

    get themeGlyph() {
        return this.theme === 'dark' ? '☀' : '☾';
    }

    get themeToggleTitle() {
        return this.theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode';
    }

    get myInitials() {
        return initials(this.currentUserName);
    }

    get myAvatarStyle() {
        return avatarStyle(this.currentUserId || 'me');
    }

    /** Internal Lightning Experience URL derived from the site domain (*.my.site.com -> *.lightning.force.com). */
    get salesforceUrl() {
        const host = window.location.hostname.replace(/\.my\.site\.com$/, '.lightning.force.com');
        return `https://${host}/lightning/n/Project_Board`;
    }

    get logoutUrl() {
        // Site logout lives on the site's Visualforce path ({prefix}vforcesite)
        const prefix = window.location.pathname.split('/')[1];
        return prefix ? `/${prefix}vforcesite/secur/logout.jsp` : '/secur/logout.jsp';
    }

    get hasProjects() {
        return this.projects.length > 0 && !!this.project;
    }

    get showEmptyState() {
        return this.loaded && !this.projects.length;
    }

    get projectKey() {
        return this.project ? this.project.Key__c : '';
    }

    get projectAvatarStyle() {
        return this.project ? avatarStyle(this.project.Id) : '';
    }

    get projectInitial() {
        return this.projectKey.charAt(0);
    }

    get navItems() {
        const work = this.issues.filter((i) => !i.isEpic);
        const counts = {
            board: work.filter((i) => !i.isDone).length,
            backlog: work.filter((i) => !i.sprintId).length,
            issues: this.issues.length
        };
        return NAV.map((n) => ({
            ...n,
            count: counts[n.view] || null,
            cls: 'nav-item' + (n.view === this.view ? ' active' : '')
        }));
    }

    get projectItems() {
        return this.projects.map((p) => ({
            id: p.Id,
            name: p.Name,
            key: p.Key__c,
            initial: (p.Key__c || '?').charAt(0),
            style: avatarStyle(p.Id),
            cls: 'nav-item project-item' + (p.Id === this.projectId ? ' active' : '')
        }));
    }

    get isBoard() {
        return this.view === 'board';
    }

    get isBacklog() {
        return this.view === 'backlog';
    }

    get isReports() {
        return this.view === 'reports';
    }

    get isIssues() {
        return this.view === 'issues';
    }

    get showDetail() {
        return !this.createOpen && !!this.selectedIssueId;
    }

    get durationOptions() {
        const current = this.sprintDialog ? this.sprintDialog.duration : null;
        return DURATIONS.map((d) => ({ ...d, selected: d.value === current }));
    }

    get completeTargetOptions() {
        const dlg = this.completeDialog;
        if (!dlg) return [];
        return [
            { value: '', label: 'Backlog', selected: !dlg.target },
            ...this.sprints
                .filter((s) => s.Status__c === 'Planned')
                .map((s) => ({
                    value: s.Id,
                    label: s.Name,
                    selected: s.Id === dlg.target
                }))
        ];
    }

    // ---------------------------------------------------------------- Navigation

    handleNav(event) {
        this.view = event.currentTarget.dataset.view;
    }

    handleNavigate(event) {
        this.view = event.detail.view;
    }

    async handleProjectSelect(event) {
        const id = event.currentTarget.dataset.id;
        if (id === this.projectId) return;
        this.projectId = id;
        this.selectedIssueId = null;
        store(STORAGE_KEY, id);
        this.loading = true;
        await this.loadBoard();
        this.loading = false;
    }

    handleGlobalSearch(event) {
        if (event.key === 'Enter') {
            this.globalSearch = event.target.value;
            this.view = 'issues';
        }
    }

    toggleTheme() {
        this.theme = this.theme === 'dark' ? 'light' : 'dark';
        store(THEME_KEY, this.theme);
    }

    toggleUserMenu() {
        this.userMenuOpen = !this.userMenuOpen;
    }

    closeUserMenu() {
        this.userMenuOpen = false;
    }

    handleRefresh() {
        this.loading = true;
        this.loadBoard().then(() => {
            this.loading = false;
        });
    }

    // ---------------------------------------------------------------- Issues

    handleOpenIssue(event) {
        this.createOpen = false;
        this.selectedIssueId = event.detail.id;
    }

    handleCreateClick() {
        this.openCreate({});
    }

    handleCreate(event) {
        this.openCreate(event.detail || {});
    }

    handleCreateChild(event) {
        this.selectedIssueId = null;
        this.openCreate({ epicId: event.detail.epicId });
    }

    openCreate(defaults) {
        if (!this.project) return;
        this.createDefaults = defaults;
        this.createOpen = true;
    }

    handleDetailClose() {
        this.selectedIssueId = null;
        this.createOpen = false;
    }

    handleIssueChanged() {
        this.loadBoard();
    }

    async handleIssueCreated(event) {
        this.createOpen = false;
        this.toast(`${event.detail.key} has been created`, '', 'success');
        await this.loadBoard();
    }

    async handleIssueDeleted(event) {
        this.selectedIssueId = null;
        this.toast(`${event.detail.key} has been deleted`, '', 'success');
        await this.loadBoard();
    }

    async handleQuickCreate(event) {
        const { summary, type, sprintId, epicId } = event.detail;
        const fields = {
            Project__c: this.projectId,
            Summary__c: summary,
            Type__c: type
        };
        if (sprintId) fields.Sprint__c = sprintId;
        if (epicId) fields.Epic__c = epicId;
        try {
            await saveIssue({ fields });
            await this.loadBoard();
        } catch (e) {
            this.toastError('Could not create issue', e);
        }
    }

    async handleMove(event) {
        const { id, status, changeSprint, sprintId, rank } = event.detail;
        // Optimistic update so the card lands immediately
        this.issues = this.issues.map((issue) => {
            if (issue.id !== id) return issue;
            const raw = { ...issue.raw, Rank__c: rank };
            if (status) raw.Status__c = status;
            if (changeSprint) {
                const sprint = this.sprints.find((s) => s.Id === sprintId);
                raw.Sprint__c = sprintId;
                raw.Sprint__r = sprint ? { Name: sprint.Name, Status__c: sprint.Status__c } : undefined;
            }
            return decorateIssue(raw, issue.stats);
        });
        try {
            await moveIssue({
                issueId: id,
                status,
                changeSprint: !!changeSprint,
                sprintId: sprintId || null,
                rank
            });
        } catch (e) {
            this.toastError('Could not move issue', e);
            await this.loadBoard();
        }
    }

    // ---------------------------------------------------------------- Sprints

    async handleCreateSprint() {
        try {
            const sprint = await createSprint({ projectId: this.projectId });
            this.toast(`${sprint.Name} created`, '', 'success');
            await this.loadBoard();
        } catch (e) {
            this.toastError('Could not create sprint', e);
        }
    }

    handleStartSprint(event) {
        const sprint = this.sprints.find((s) => s.Id === event.detail.sprintId);
        const start = todayIso();
        this.dialogError = null;
        this.sprintDialog = {
            id: sprint.Id,
            name: sprint.Name,
            duration: '2',
            startDate: start,
            endDate: addDaysIso(start, 14),
            goal: sprint.Goal__c || '',
            issueCount: this.issues.filter((i) => i.sprintId === sprint.Id).length
        };
    }

    handleSprintDialogChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        const dlg = { ...this.sprintDialog, [field]: value };
        if ((field === 'duration' || field === 'startDate') && dlg.duration !== 'custom' && dlg.startDate) {
            dlg.endDate = addDaysIso(dlg.startDate, Number(dlg.duration) * 7);
        }
        if (field === 'endDate') dlg.duration = 'custom';
        this.sprintDialog = dlg;
    }

    async confirmStartSprint() {
        const dlg = this.sprintDialog;
        this.dialogBusy = true;
        this.dialogError = null;
        try {
            await startSprint({
                sprintId: dlg.id,
                name: dlg.name,
                startDate: dlg.startDate,
                endDate: dlg.endDate,
                goal: dlg.goal
            });
            this.sprintDialog = null;
            this.toast(`${dlg.name} started`, '', 'success');
            await this.loadBoard();
            this.view = 'board';
        } catch (e) {
            this.dialogError = reduceErrors(e);
        } finally {
            this.dialogBusy = false;
        }
    }

    handleCompleteSprint(event) {
        const sprint = this.sprints.find((s) => s.Id === event.detail.sprintId);
        const sprintIssues = this.issues.filter((i) => i.sprintId === sprint.Id);
        const next = this.sprints.find((s) => s.Status__c === 'Planned');
        this.dialogError = null;
        this.completeDialog = {
            id: sprint.Id,
            name: sprint.Name,
            doneCount: sprintIssues.filter((i) => i.isDone).length,
            openCount: sprintIssues.filter((i) => !i.isDone).length,
            hasOpen: sprintIssues.some((i) => !i.isDone),
            target: next ? next.Id : ''
        };
    }

    handleCompleteTarget(event) {
        this.completeDialog = {
            ...this.completeDialog,
            target: event.target.value
        };
    }

    async confirmCompleteSprint() {
        const dlg = this.completeDialog;
        this.dialogBusy = true;
        this.dialogError = null;
        try {
            await completeSprint({
                sprintId: dlg.id,
                moveToSprintId: dlg.target || null
            });
            this.completeDialog = null;
            this.toast(`${dlg.name} completed`, `${dlg.doneCount} issues done, ${dlg.openCount} moved.`, 'success');
            await this.loadBoard();
        } catch (e) {
            this.dialogError = reduceErrors(e);
        } finally {
            this.dialogBusy = false;
        }
    }

    async handleDeleteSprint(event) {
        const sprint = this.sprints.find((s) => s.Id === event.detail.sprintId);
        const ok = await LightningConfirm.open({
            message: 'Issues in this sprint will be moved to the backlog.',
            label: `Delete ${sprint.Name}?`,
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteSprint({ sprintId: sprint.Id });
            await this.loadBoard();
        } catch (e) {
            this.toastError('Could not delete sprint', e);
        }
    }

    closeDialogs() {
        this.sprintDialog = null;
        this.completeDialog = null;
        this.projectDialog = null;
        this.dialogError = null;
    }

    // ---------------------------------------------------------------- Projects

    openProjectDialog() {
        this.dialogError = null;
        this.projectDialog = {
            name: '',
            key: '',
            description: '',
            keyTouched: false
        };
    }

    handleProjectDialogChange(event) {
        const field = event.target.dataset.field;
        const dlg = { ...this.projectDialog, [field]: event.target.value };
        if (field === 'name' && !dlg.keyTouched) dlg.key = suggestKey(dlg.name);
        if (field === 'key') {
            dlg.key = (dlg.key || '').toUpperCase();
            dlg.keyTouched = true;
        }
        this.projectDialog = dlg;
    }

    async confirmCreateProject() {
        const dlg = this.projectDialog;
        this.dialogBusy = true;
        this.dialogError = null;
        try {
            const project = await createProject({
                name: dlg.name,
                projectKey: dlg.key,
                description: dlg.description
            });
            this.projectDialog = null;
            this.view = 'backlog';
            this.toast(
                `Project ${project.Name} created`,
                'Add issues to the backlog and start your first sprint.',
                'success'
            );
            await this.loadProjects(project.Id);
        } catch (e) {
            this.dialogError = reduceErrors(e);
        } finally {
            this.dialogBusy = false;
        }
    }

    // ---------------------------------------------------------------- Toasts

    toast(title, message, variant) {
        Toast.show({ label: title, message, variant, mode: 'dismissible' }, this);
    }

    toastError(title, error) {
        this.toast(title, reduceErrors(error), 'error');
    }
}
