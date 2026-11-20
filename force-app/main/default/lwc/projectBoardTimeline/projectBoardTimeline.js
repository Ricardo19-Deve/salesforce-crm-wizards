/**
 * Project Board timeline: issues as bars from their start to their due date, grouped by epic, with milestones,
 * dependency arrows, sprint bands and a line for today.
 *
 * Dates: start and due date of the issue. An issue with only one of them shows as a one-day bar; an issue with
 * neither uses the dates of its sprint (dashed bar) or is listed under "Not on the timeline".
 * Dependencies: an arrow goes from the end of the blocking issue to the start of the blocked one. It turns red
 * (a conflict) when the blocked issue starts before the blocking one ends and the blocking one is not done.
 * Keyboard: the issue names in the left column are the tab stops; Enter opens the issue.
 */
import { LightningElement, api } from 'lwc';
import { todayIso, addDaysIso, daysBetween, formatShortDate } from 'c/projectBoardUtils';

const ROW = 40;
const DAY_WIDTH = { week: 30, month: 9 };
const STATUS_TONE = {
    'To Do': 'todo',
    'In Progress': 'progress',
    'In Review': 'review',
    Done: 'done'
};
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Last chart per component (kept outside the component so caching does not trigger a re-render). */
const CHART_CACHE = new WeakMap();

function minIso(a, b) {
    if (!a) return b;
    if (!b) return a;
    return a < b ? a : b;
}

function maxIso(a, b) {
    if (!a) return b;
    if (!b) return a;
    return a > b ? a : b;
}

/** Monday on or before the date. */
function mondayOf(iso) {
    const [y, m, d] = iso.split('-').map(Number);
    const day = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
    return addDaysIso(iso, -((day + 6) % 7));
}

export default class ProjectBoardTimeline extends LightningElement {
    @api issues = [];
    @api sprints = [];
    @api project;

    zoom = 'week';
    hideDone = false;
    _scrolled = false;

    // ---------------------------------------------------------------- Model

    get dayWidth() {
        return DAY_WIDTH[this.zoom];
    }

    /** Bar dates of an issue: its own dates, else its sprint's, else none. */
    spanOf(issue, sprintsById) {
        if (issue.startDate || issue.dueDate) {
            const start = issue.startDate || issue.dueDate;
            const end = issue.dueDate || issue.startDate;
            return { start, end, fromSprint: false };
        }
        const sprint = issue.sprintId ? sprintsById.get(issue.sprintId) : null;
        if (sprint && sprint.Start_Date__c && sprint.End_Date__c) {
            return {
                start: sprint.Start_Date__c,
                end: sprint.End_Date__c,
                fromSprint: true
            };
        }
        return null;
    }

    get model() {
        const sprintsById = new Map((this.sprints || []).map((s) => [s.Id, s]));
        const visible = (this.issues || []).filter((i) => !(this.hideDone && i.isDone));
        const epics = visible.filter((i) => i.isEpic);
        const work = visible.filter((i) => !i.isEpic);

        const spans = new Map();
        const unscheduled = [];
        work.forEach((i) => {
            const span = this.spanOf(i, sprintsById);
            if (span) spans.set(i.id, span);
            else unscheduled.push(i);
        });

        // Groups: each epic (with its own dates or the span of its children), then work without an epic
        const groups = [];
        const byEpic = new Map();
        work.filter((i) => spans.has(i.id)).forEach((i) => {
            const key = i.epicId || 'none';
            if (!byEpic.has(key)) byEpic.set(key, []);
            byEpic.get(key).push(i);
        });
        epics.forEach((epic) => {
            const children = byEpic.get(epic.id) || [];
            let span = this.spanOf(epic, sprintsById);
            if (!span && children.length) {
                span = children.reduce(
                    (acc, c) => ({
                        start: minIso(acc.start, spans.get(c.id).start),
                        end: maxIso(acc.end, spans.get(c.id).end),
                        fromSprint: true
                    }),
                    { start: null, end: null }
                );
            }
            if (span) spans.set(epic.id, span);
            if (span || children.length) groups.push({ epic, children });
        });
        if (byEpic.has('none')) groups.push({ epic: null, children: byEpic.get('none') });

        // Date range: everything on the chart plus today, padded, from a Monday
        const today = todayIso();
        let start = today;
        let end = addDaysIso(today, 28);
        spans.forEach((s) => {
            start = minIso(start, s.start);
            end = maxIso(end, s.end);
        });
        (this.sprints || []).forEach((s) => {
            if (s.Status__c !== 'Completed' && s.Start_Date__c && s.End_Date__c) {
                start = minIso(start, s.Start_Date__c);
                end = maxIso(end, s.End_Date__c);
            }
        });
        start = mondayOf(addDaysIso(start, -7));
        end = addDaysIso(end, 14);
        const days = Math.max(42, daysBetween(start, end) + 1);

        return { groups, spans, unscheduled, start, days, today, sprintsById };
    }

    x(iso, start) {
        return daysBetween(start, iso) * this.dayWidth;
    }

    /** The chart is rebuilt only when the issues, the sprints or the view options change. */
    get chart() {
        const inputs = [this.issues, this.sprints, this.zoom, this.hideDone];
        const cached = CHART_CACHE.get(this);
        if (cached && cached.inputs.every((value, index) => value === inputs[index])) {
            return cached.chart;
        }
        const chart = this.buildChart();
        CHART_CACHE.set(this, { inputs, chart });
        return chart;
    }

    buildChart() {
        const m = this.model;
        const dw = this.dayWidth;
        const width = m.days * dw;
        const rows = [];
        const positions = new Map();

        const addRow = (issue, isEpic) => {
            const span = m.spans.get(issue.id);
            const top = rows.length * ROW;
            const row = {
                key: issue.id,
                id: issue.id,
                issueKey: issue.key,
                summary: issue.summary,
                isEpic,
                rowClass: 'row' + (isEpic ? ' row-epic' : ''),
                labelClass: 'row-label' + (isEpic ? ' label-epic' : ''),
                epicStyle: isEpic ? issue.epicStyle || '' : '',
                hasBar: !!span,
                isMilestone: !!span && issue.isMilestone,
                isBlocked: issue.isBlocked,
                ariaLabel: '',
                barStyle: '',
                barClass: '',
                diamondStyle: '',
                barText: issue.key
            };
            if (span) {
                const x1 = this.x(span.start, m.start);
                const x2 = this.x(span.end, m.start) + dw;
                const tone = STATUS_TONE[issue.status] || 'todo';
                if (row.isMilestone) {
                    row.diamondStyle = `left:${x2 - dw / 2 - 8}px`;
                    row.milestoneLabelStyle = `left:${x2 - dw / 2 + 12}px`;
                    positions.set(issue.id, {
                        x1: x2 - dw / 2,
                        x2: x2 - dw / 2,
                        y: top + ROW / 2
                    });
                } else {
                    row.barStyle = `left:${x1}px;width:${Math.max(dw, x2 - x1)}px`;
                    positions.set(issue.id, { x1, x2, y: top + ROW / 2 });
                }
                row.barClass =
                    `bar tone-${tone}` +
                    (isEpic ? ' bar-epic' : '') +
                    (span.fromSprint ? ' bar-sprint' : '') +
                    (issue.isDone ? ' bar-done' : '');
                row.diamondClass = `diamond tone-${tone}` + (issue.isDone ? ' bar-done' : '');
                const dates =
                    span.start === span.end
                        ? formatShortDate(span.start)
                        : `${formatShortDate(span.start)} – ${formatShortDate(span.end)}`;
                row.ariaLabel =
                    `${issue.key} ${issue.summary}, ${issue.status}, ${dates}` +
                    (span.fromSprint ? ' (sprint dates)' : '') +
                    (row.isMilestone ? ', milestone' : '') +
                    (issue.isBlocked ? ', blocked' : '');
                row.title = row.ariaLabel;
            }
            rows.push(row);
        };

        m.groups.forEach((g) => {
            if (g.epic) addRow(g.epic, true);
            else
                rows.push({
                    key: 'no-epic',
                    isGroup: true,
                    rowClass: 'row row-group',
                    summary: 'No epic'
                });
            [...g.children]
                .sort((a, b) => (m.spans.get(a.id).start || '').localeCompare(m.spans.get(b.id).start || ''))
                .forEach((c) => addRow(c, false));
        });

        // Dependency arrows between issues that are both on the chart
        const issuesById = new Map((this.issues || []).map((i) => [i.id, i]));
        const arrows = [];
        const conflicts = [];
        positions.forEach((to, blockedId) => {
            const blocked = issuesById.get(blockedId);
            (blocked.blockedBy || []).forEach((link) => {
                const from = positions.get(link.issueId);
                if (!from) return;
                const blocking = issuesById.get(link.issueId);
                const conflict = !blocking.isDone && m.spans.get(blockedId).start <= m.spans.get(link.issueId).end;
                if (conflict) {
                    conflicts.push({
                        key: link.dependencyId,
                        text: `${blocked.key} starts before ${blocking.key} is due`,
                        id: blockedId
                    });
                }
                const sx = from.x2;
                const ex = to.x1;
                const midY = from.y + (to.y > from.y ? ROW / 2 : -ROW / 2);
                const d =
                    ex - sx >= 16
                        ? `M${sx} ${from.y} H${sx + 8} V${to.y} H${ex}`
                        : `M${sx} ${from.y} H${sx + 8} V${midY} H${ex - 8} V${to.y} H${ex}`;
                arrows.push({
                    key: link.dependencyId,
                    d,
                    head: `M${ex} ${to.y} l-6 -4 v8 z`,
                    cls: conflict ? 'arrow arrow-conflict' : 'arrow'
                });
            });
        });

        // Header: months, week or day ticks, sprint bands, weekend shading
        const months = [];
        const ticks = [];
        const weekends = [];
        for (let i = 0; i < m.days; i++) {
            const iso = addDaysIso(m.start, i);
            const [y, mo, d] = iso.split('-').map(Number);
            const dow = new Date(Date.UTC(y, mo - 1, d)).getUTCDay();
            if (d === 1 || i === 0) {
                months.push({
                    key: iso,
                    label: `${MONTHS[mo - 1]} ${y}`,
                    style: `left:${i * dw}px`
                });
            }
            if (this.zoom === 'week') {
                ticks.push({
                    key: iso,
                    label: String(d),
                    cls: 'tick' + (dow === 1 ? ' tick-week' : '') + (iso === m.today ? ' tick-today' : ''),
                    style: `left:${i * dw}px;width:${dw}px`
                });
                if (dow === 0 || dow === 6) {
                    weekends.push({ key: iso, style: `left:${i * dw}px;width:${dw}px` });
                }
            } else if (dow === 1) {
                ticks.push({
                    key: iso,
                    label: formatShortDate(iso),
                    cls: 'tick tick-week',
                    style: `left:${i * dw}px;width:${7 * dw}px`
                });
            }
        }
        const sprintBands = (this.sprints || [])
            .filter((s) => s.Start_Date__c && s.End_Date__c)
            .map((s) => {
                const x1 = Math.max(0, this.x(s.Start_Date__c, m.start));
                const x2 = this.x(s.End_Date__c, m.start) + dw;
                return {
                    key: s.Id,
                    label: s.Name,
                    cls: 'sprint-band' + (s.Status__c === 'Active' ? ' sprint-active' : ''),
                    style: `left:${x1}px;width:${Math.max(dw, x2 - x1)}px`
                };
            });

        return {
            rows,
            arrows,
            conflicts,
            months,
            ticks,
            weekends,
            sprintBands,
            width,
            height: rows.length * ROW,
            todayStyle: `left:${this.x(m.today, m.start) + dw / 2}px`,
            todayX: this.x(m.today, m.start),
            unscheduled: m.unscheduled.map((i) => ({
                id: i.id,
                key: i.key,
                summary: i.summary
            }))
        };
    }

    // ---------------------------------------------------------------- Template helpers

    get trackStyle() {
        return `width:${this.chart.width}px`;
    }

    get canvasStyle() {
        return `width:${this.chart.width}px;height:${this.chart.height}px`;
    }

    get svgWidth() {
        return this.chart.width;
    }

    get svgHeight() {
        return Math.max(1, this.chart.height);
    }

    get hasRows() {
        return this.chart.rows.length > 0;
    }

    get hasConflicts() {
        return this.chart.conflicts.length > 0;
    }

    get conflictLabel() {
        const n = this.chart.conflicts.length;
        return `${n} dependency conflict${n === 1 ? '' : 's'}`;
    }

    get hasUnscheduled() {
        return this.chart.unscheduled.length > 0;
    }

    get weekClass() {
        return 'seg' + (this.zoom === 'week' ? ' seg-active' : '');
    }

    get monthClass() {
        return 'seg' + (this.zoom === 'month' ? ' seg-active' : '');
    }

    get weekPressed() {
        return this.zoom === 'week' ? 'true' : 'false';
    }

    get monthPressed() {
        return this.zoom === 'month' ? 'true' : 'false';
    }

    get projectName() {
        return this.project ? this.project.Name : '';
    }

    // ---------------------------------------------------------------- Events

    renderedCallback() {
        if (!this._scrolled && this.hasRows) {
            this._scrolled = true;
            this.scrollToToday();
        }
    }

    scrollToToday() {
        const scroller = this.template.querySelector('.scroller');
        if (scroller) scroller.scrollLeft = Math.max(0, this.chart.todayX - 160);
    }

    setWeek() {
        this.zoom = 'week';
        this._scrolled = false;
    }

    setMonth() {
        this.zoom = 'month';
        this._scrolled = false;
    }

    toggleDone(event) {
        this.hideDone = event.target.checked;
    }

    open(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this.dispatchEvent(new CustomEvent('openissue', { detail: { id } }));
        }
    }
}
