/**
 * Project Board requests: a form to ask a project team for something, and the list of my requests.
 *
 * Anyone with the app can file a request in a project that accepts them, without being a member. The request
 * lands in the project's backlog (with a "Request" badge), the Leads are notified, and the requester is told when
 * its status changes. Leads open or close the current project to requests here.
 */
import { LightningElement, api } from 'lwc';
import Toast from 'lightning/toast';
import getRequestContext from '@salesforce/apex/ProjectPlanController.getRequestContext';
import submitRequest from '@salesforce/apex/ProjectPlanController.submitRequest';
import setAcceptsRequests from '@salesforce/apex/ProjectPlanController.setAcceptsRequests';
import { reduceErrors, statusClass, toTime, syncTextareas } from 'c/projectBoardUtils';

const TYPES = [
    { value: 'Story', label: 'New feature or change' },
    { value: 'Bug', label: 'Something is broken' },
    { value: 'Task', label: 'Other request' }
];
const PRIORITIES = ['Highest', 'High', 'Medium', 'Low', 'Lowest'];

export default class ProjectBoardRequests extends LightningElement {
    /** Current project of the app, when the user can manage it (Leads switch requests on and off). */
    @api project;
    @api canManage = false;

    context = { projects: [], mine: [] };
    loading = true;
    busy = false;
    error;
    form = {
        projectId: '',
        summary: '',
        description: '',
        type: 'Story',
        priority: 'Medium'
    };

    connectedCallback() {
        this.load();
    }

    renderedCallback() {
        syncTextareas(this.template);
    }

    async load() {
        this.loading = true;
        try {
            this.context = await getRequestContext();
            const ids = this.context.projects.map((p) => p.id);
            if (!ids.includes(this.form.projectId)) {
                const preferred = this.project && ids.includes(this.project.Id) ? this.project.Id : ids[0];
                this.form = { ...this.form, projectId: preferred || '' };
            }
        } catch (e) {
            this.error = reduceErrors(e);
        } finally {
            this.loading = false;
        }
    }

    // ---------------------------------------------------------------- Form

    get hasProjects() {
        return this.context.projects.length > 0;
    }

    get projectOptions() {
        return this.context.projects.map((p) => ({
            value: p.id,
            label: `${p.name} (${p.key})`,
            selected: p.id === this.form.projectId
        }));
    }

    get typeOptions() {
        return TYPES.map((t) => ({ ...t, selected: t.value === this.form.type }));
    }

    get priorityOptions() {
        return PRIORITIES.map((p) => ({
            value: p,
            label: p,
            selected: p === this.form.priority
        }));
    }

    get submitDisabled() {
        return this.busy || !this.form.projectId || !this.form.summary.trim();
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.form = { ...this.form, [field]: value };
    }

    async handleSubmit(event) {
        event.preventDefault();
        if (this.submitDisabled) return;
        this.busy = true;
        this.error = null;
        try {
            const filed = await submitRequest({
                projectId: this.form.projectId,
                summary: this.form.summary,
                description: this.form.description,
                type: this.form.type,
                priority: this.form.priority
            });
            Toast.show(
                {
                    label: `Request ${filed ? filed.key : ''} sent`,
                    message: 'The project leads have been notified. You will be told when its status changes.',
                    variant: 'success'
                },
                this
            );
            this.form = { ...this.form, summary: '', description: '' };
            await this.load();
            this.dispatchEvent(new CustomEvent('submitted'));
        } catch (e) {
            this.error = reduceErrors(e);
        } finally {
            this.busy = false;
        }
    }

    // ---------------------------------------------------------------- My requests

    get hasMine() {
        return this.context.mine.length > 0;
    }

    get mine() {
        return this.context.mine.map((r) => ({
            ...r,
            statusClass: statusClass(r.status),
            created: toTime(r.createdDate),
            updated: toTime(r.lastModifiedDate),
            plan: r.sprintName ? `Planned in ${r.sprintName}` : 'In the backlog',
            who: r.assigneeName ? `Assigned to ${r.assigneeName}` : 'Not assigned yet'
        }));
    }

    // ---------------------------------------------------------------- Leads

    get showIntakeSwitch() {
        return !!this.project && this.canManage;
    }

    get accepts() {
        return !!(this.project && this.project.Accepts_Requests__c);
    }

    get intakeText() {
        return this.accepts
            ? 'Anyone with the app can send requests to this project. They arrive in the backlog and you are notified.'
            : 'Closed: this project does not appear in the request form.';
    }

    async toggleIntake(event) {
        const accepts = event.target.checked;
        try {
            await setAcceptsRequests({ projectId: this.project.Id, accepts });
            this.dispatchEvent(new CustomEvent('projectchanged'));
            await this.load();
        } catch (e) {
            event.target.checked = !accepts;
            this.error = reduceErrors(e);
        }
    }
}
