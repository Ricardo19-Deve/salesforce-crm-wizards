/**
 * Pure helpers shared by the projectBoard* components: issue view model, ranks, dates, colours and the URLs of
 * files and PDF / Word exports (Lightning Experience vs Experience Cloud site).
 */

export const STATUSES = ['To Do', 'In Progress', 'In Review', 'Done'];
export const TYPES = ['Story', 'Task', 'Bug', 'Epic'];
export const PRIORITIES = ['Highest', 'High', 'Medium', 'Low', 'Lowest'];

const TYPE_META = {
    Story: { icon: 'utility:bookmark', cls: 'type-icon type-story' },
    Task: { icon: 'utility:check', cls: 'type-icon type-task' },
    Bug: { icon: 'utility:bug', cls: 'type-icon type-bug' },
    Epic: { icon: 'utility:flash', cls: 'type-icon type-epic' }
};

const PRIORITY_META = {
    Highest: { glyph: '⇈', cls: 'prio prio-highest' },
    High: { glyph: '↑', cls: 'prio prio-high' },
    Medium: { glyph: '=', cls: 'prio prio-medium' },
    Low: { glyph: '↓', cls: 'prio prio-low' },
    Lowest: { glyph: '⇊', cls: 'prio prio-lowest' }
};

const STATUS_CLASS = {
    'To Do': 'lozenge lozenge-todo',
    'In Progress': 'lozenge lozenge-progress',
    'In Review': 'lozenge lozenge-review',
    Done: 'lozenge lozenge-done'
};

// Hues (0-360) - the glass theme turns them into gradients that work in light and dark mode
const AVATAR_HUES = [218, 160, 12, 262, 32, 190, 290, 340];
const EPIC_HUES = [262, 218, 152, 44, 8, 188, 320];

function hash(value) {
    const str = value || '';
    let h = 0;
    for (let i = 0; i < str.length; i++) {
        h = (h * 31 + str.charCodeAt(i)) | 0;
    }
    return Math.abs(h);
}

export function initials(name) {
    if (!name) return '?';
    const parts = name.trim().split(/\s+/);
    const last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : '';
    return (parts[0].charAt(0) + last).toUpperCase();
}

export function avatarStyle(seed) {
    return `--av-hue:${AVATAR_HUES[hash(seed) % AVATAR_HUES.length]}`;
}

export function epicStyle(seed) {
    return `--epic-hue:${EPIC_HUES[hash(seed) % EPIC_HUES.length]}`;
}

export function typeMeta(type) {
    return TYPE_META[type] || TYPE_META.Task;
}

export function priorityMeta(priority) {
    return PRIORITY_META[priority] || PRIORITY_META.Medium;
}

export function statusClass(status) {
    return STATUS_CLASS[status] || STATUS_CLASS['To Do'];
}

export function toOptions(values) {
    return values.map((v) => ({ label: v, value: v }));
}

export function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function addDaysIso(iso, days) {
    const [y, m, d] = iso.split('-').map(Number);
    const date = new Date(y, m - 1, d + days);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function formatShortDate(iso) {
    if (!iso) return '';
    const [y, m, d] = iso.split('-').map(Number);
    return new Date(y, m - 1, d).toLocaleDateString(undefined, {
        day: 'numeric',
        month: 'short'
    });
}

export function daysBetween(fromIso, toIso) {
    const [y1, m1, d1] = fromIso.split('-').map(Number);
    const [y2, m2, d2] = toIso.split('-').map(Number);
    return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / 86400000);
}

/** Rank between two neighbours (fractional ranking, so a move updates a single record). */
export function midRank(prev, next) {
    const p = prev === undefined || prev === null ? null : Number(prev);
    const n = next === undefined || next === null ? null : Number(next);
    if (p === null && n === null) return 1;
    if (p === null) return n - 1;
    if (n === null) return p + 1;
    return Math.round(((p + n) / 2) * 1e6) / 1e6;
}

export function sumPoints(issues) {
    return issues.reduce((total, i) => total + (Number(i.points) || 0), 0);
}

export function matchesSearch(issue, term) {
    if (!term) return true;
    const t = term.toLowerCase();
    return (
        (issue.summary || '').toLowerCase().includes(t) ||
        (issue.key || '').toLowerCase().includes(t) ||
        (issue.labelsText || '').toLowerCase().includes(t)
    );
}

export function keyNumber(key) {
    const n = parseInt((key || '').split('-').pop(), 10);
    return Number.isNaN(n) ? 0 : n;
}

/** Experience site base path (e.g. "/projects") when running in the portal, null inside Lightning Experience. */
export function siteBase() {
    if (!/\.site\.com$/.test(window.location.hostname)) return null;
    const prefix = window.location.pathname.split('/')[1];
    return prefix ? `/${prefix}` : '';
}

export function fileDownloadUrl(documentId) {
    const base = siteBase();
    return base === null
        ? `/sfc/servlet.shepherd/document/download/${documentId}`
        : `${base}/sfsites/c/sfc/servlet.shepherd/document/download/${documentId}`;
}

/** URL of a Visualforce export page (PDF / Word) - the portal serves them from its "{prefix}vforcesite" path. */
export function exportUrl(page, recordId, format) {
    const base = siteBase();
    const query = `id=${encodeURIComponent(recordId)}&format=${format}`;
    return base === null ? `/apex/${page}?${query}` : `${base}vforcesite/apex/${page}?${query}`;
}

export function formatBytes(bytes) {
    if (!bytes) return '0 KB';
    if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Turns an PM_Issue__c record into the view model used by every template. */
export function decorateIssue(r, stats) {
    const st = stats || {};
    const tests = st.tests || 0;
    const testsPassed = st.testsPassed || 0;
    const type = typeMeta(r.Type__c);
    const prio = priorityMeta(r.Priority__c);
    const assigneeName = r.Assignee__r ? r.Assignee__r.Name : null;
    const reporterName = r.Reporter__r ? r.Reporter__r.Name : null;
    const isDone = r.Status__c === 'Done';
    const hasPoints = r.Story_Points__c !== undefined && r.Story_Points__c !== null;
    return {
        id: r.Id,
        key: r.Name,
        keyClass: isDone ? 'issue-key done' : 'issue-key',
        summary: r.Summary__c,
        description: r.Description__c || '',
        type: r.Type__c || 'Task',
        typeIcon: type.icon,
        typeClass: type.cls,
        status: r.Status__c || 'To Do',
        statusClass: statusClass(r.Status__c),
        isDone,
        isEpic: r.Type__c === 'Epic',
        priority: r.Priority__c || 'Medium',
        prioGlyph: prio.glyph,
        prioClass: prio.cls,
        points: hasPoints ? r.Story_Points__c : null,
        hasPoints,
        rank: r.Rank__c || 0,
        sprintId: r.Sprint__c || null,
        sprintName: r.Sprint__r ? r.Sprint__r.Name : '',
        epicId: r.Epic__c || null,
        epicKey: r.Epic__r ? r.Epic__r.Name : '',
        epicName: r.Epic__r ? r.Epic__r.Summary__c : '',
        epicStyle: r.Epic__c ? epicStyle(r.Epic__c) : '',
        assigneeId: r.Assignee__c || null,
        assigneeName: assigneeName || 'Unassigned',
        assigneeInitials: initials(assigneeName),
        assigneeStyle: r.Assignee__c ? avatarStyle(r.Assignee__c) : '',
        reporterId: r.Reporter__c || null,
        reporterName: reporterName || '—',
        reporterInitials: initials(reporterName),
        reporterStyle: r.Reporter__c ? avatarStyle(r.Reporter__c) : '',
        dueDate: r.Due_Date__c || null,
        overdue: !!r.Due_Date__c && !isDone && r.Due_Date__c < todayIso(),
        labels: (r.Labels__c || '')
            .split(',')
            .map((l) => l.trim())
            .filter((l) => l),
        labelsText: r.Labels__c || '',
        createdDate: toTime(r.CreatedDate),
        lastModifiedDate: toTime(r.LastModifiedDate),
        attachments: st.attachments || 0,
        hasAttachments: (st.attachments || 0) > 0,
        hasBrd: !!st.hasBrd,
        tests,
        hasTests: tests > 0,
        testsLabel: `${testsPassed}/${tests}`,
        testsClass:
            'badge badge-tests' +
            (st.testsFailed ? ' badge-fail' : tests > 0 && testsPassed === tests ? ' badge-pass' : ''),
        stats: st,
        raw: r
    };
}

/** lightning-relative-date-time / formatted-date-time need a timestamp: ISO strings from Apex render as "Invalid date". */
export function toTime(value) {
    if (!value) return null;
    const time = Date.parse(value);
    return Number.isNaN(time) ? null : time;
}

/**
 * Templates bind textarea content with data-text={..} because value={..} does not render the initial text.
 * Call from renderedCallback: copies data-text into each textarea that is not being edited.
 */
export function syncTextareas(root) {
    root.querySelectorAll('textarea[data-text], textarea[data-sync]').forEach((el) => {
        if (el === el.getRootNode().activeElement) return;
        const text = el.dataset.text || '';
        if (el.value !== text) el.value = text;
    });
}

export function reduceErrors(error) {
    if (!error) return 'Unknown error';
    if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
    if (error.body && error.body.message) return error.body.message;
    if (error.body && error.body.pageErrors && error.body.pageErrors.length) return error.body.pageErrors[0].message;
    return error.message || String(error);
}
