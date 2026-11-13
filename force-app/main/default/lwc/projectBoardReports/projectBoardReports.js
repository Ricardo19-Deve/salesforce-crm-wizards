import { LightningElement, api } from 'lwc';
import { exportUrl, formatShortDate, sumPoints } from 'c/projectBoardUtils';

function parseCarried(json) {
    try {
        const rows = JSON.parse(json || '[]');
        return Array.isArray(rows) ? rows : [];
    } catch {
        return [];
    }
}

function round1(n) {
    return Math.round(n * 10) / 10;
}

/**
 * Sprint reports: velocity chart + one card per active/completed sprint with KPIs and PDF/Word exports.
 * The figures mirror ProjectExportController so the screen and the exported report agree.
 */
export default class ProjectBoardReports extends LightningElement {
    @api issues = [];
    @api sprints = [];
    @api project;

    hoverIndex = null;

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    get reportSprints() {
        return (this.sprints || [])
            .filter((s) => s.Status__c !== 'Planned')
            .map((s) => this.metrics(s))
            .sort((a, b) => (a.sequence || 0) - (b.sequence || 0));
    }

    metrics(sprint) {
        const inSprint = (this.issues || []).filter((i) => i.sprintId === sprint.Id && !i.isEpic);
        const delivered = inSprint.filter((i) => i.isDone);
        const open = inSprint.filter((i) => !i.isDone);
        const carried = sprint.Status__c === 'Completed' ? parseCarried(sprint.Carried_Over__c) : [];
        const carriedPoints = carried.reduce((t, c) => t + (Number(c.points) || 0), 0);
        const deliveredPoints = sumPoints(delivered);
        const notDoneCount = open.length + carried.length;
        const committedIssues =
            sprint.Committed_Issues__c != null ? sprint.Committed_Issues__c : delivered.length + notDoneCount;
        const committedPoints =
            sprint.Committed_Points__c != null
                ? sprint.Committed_Points__c
                : deliveredPoints + sumPoints(open) + carriedPoints;
        const completion = committedPoints
            ? Math.min(100, Math.round((deliveredPoints / committedPoints) * 100))
            : committedIssues
              ? Math.min(100, Math.round((delivered.length / committedIssues) * 100))
              : 0;
        const tests = inSprint.reduce((t, i) => t + (i.tests || 0), 0);
        const passed = inSprint.reduce((t, i) => t + ((i.stats && i.stats.testsPassed) || 0), 0);
        const isActive = sprint.Status__c === 'Active';
        return {
            id: sprint.Id,
            name: sprint.Name,
            sequence: sprint.Sequence__c,
            goal: sprint.Goal__c,
            isActive,
            statusLabel: isActive ? 'Active' : 'Completed',
            statusClass: isActive ? 'lozenge lozenge-progress' : 'lozenge lozenge-done',
            dates: `${formatShortDate(sprint.Start_Date__c)} – ${formatShortDate(sprint.End_Date__c)}`,
            completion,
            ringStyle: `--pct:${completion}`,
            deliveredIssues: delivered.length,
            committedIssues,
            deliveredPoints: round1(deliveredPoints),
            committedPoints: round1(committedPoints),
            bugsFixed: delivered.filter((i) => i.type === 'Bug').length,
            notDone: notDoneCount,
            notDoneLabel: isActive ? 'Still open' : 'Carried over',
            testsLabel: tests ? `${passed}/${tests}` : '—',
            pdfUrl: exportUrl('ProjectSprintReport', sprint.Id, 'pdf'),
            wordUrl: exportUrl('ProjectSprintReport', sprint.Id, 'word')
        };
    }

    get hasReports() {
        return this.reportSprints.length > 0;
    }

    get cards() {
        return [...this.reportSprints].reverse();
    }

    // ---------------------------------------------------------------- Velocity chart

    get chartMax() {
        const max = Math.max(0, ...this.reportSprints.map((s) => Math.max(s.committedPoints, s.deliveredPoints)));
        if (max <= 0) return 10;
        const step = max > 50 ? 20 : max > 20 ? 10 : 5;
        return Math.ceil(max / step) * step;
    }

    get gridLines() {
        const max = this.chartMax;
        return [1, 0.5, 0].map((f) => ({
            key: `g${f}`,
            label: round1(max * f),
            style: `bottom:${f * 100}%`
        }));
    }

    get bars() {
        const max = this.chartMax;
        const avg = this.velocity;
        return this.reportSprints.map((s, index) => ({
            ...s,
            index,
            groupClass: 'bar-group' + (this.hoverIndex === index ? ' hover' : ''),
            committedStyle: `height:${(s.committedPoints / max) * 100}%`,
            deliveredStyle: `height:${(s.deliveredPoints / max) * 100}%`,
            shortName: s.name.replace(/^.*?sprint\s*/i, 'S'),
            showTip: this.hoverIndex === index,
            vsAvg: avg ? Math.round(((s.deliveredPoints - avg) / avg) * 100) : 0
        }));
    }

    get hasChart() {
        return this.reportSprints.length > 0;
    }

    /** Average delivered points of completed sprints. */
    get velocity() {
        const done = this.reportSprints.filter((s) => !s.isActive);
        if (!done.length) return 0;
        return round1(done.reduce((t, s) => t + s.deliveredPoints, 0) / done.length);
    }

    get velocityLabel() {
        return this.velocity ? `${this.velocity} pts / sprint` : '—';
    }

    handleBarEnter(event) {
        this.hoverIndex = Number(event.currentTarget.dataset.index);
    }

    handleBarLeave() {
        this.hoverIndex = null;
    }
}
