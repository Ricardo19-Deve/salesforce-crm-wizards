import {
    addDaysIso,
    daysBetween,
    decorateIssue,
    exportUrl,
    fileDownloadUrl,
    formatBytes,
    initials,
    keyNumber,
    matchesSearch,
    midRank,
    reduceErrors,
    sumPoints
} from 'c/projectBoardUtils';

const RECORD = {
    Id: 'a01000000000001',
    Name: 'NW-12',
    Summary__c: 'Offline visit reports',
    Type__c: 'Story',
    Status__c: 'Done',
    Priority__c: 'High',
    Story_Points__c: 5,
    Rank__c: 3.5,
    Assignee__c: '005000000000001',
    Assignee__r: { Name: 'Maria Santos' },
    Labels__c: 'mobile, offline',
    Epic__c: 'a01000000000009',
    Epic__r: { Name: 'NW-1', Summary__c: 'Mobile app' }
};

describe('midRank', () => {
    it('places an item between, before or after its neighbours', () => {
        expect(midRank(1, 2)).toBe(1.5);
        expect(midRank(undefined, 4)).toBe(3);
        expect(midRank(7, null)).toBe(8);
        expect(midRank(null, null)).toBe(1);
    });
});

describe('decorateIssue', () => {
    it('builds the view model used by the templates', () => {
        const issue = decorateIssue(RECORD, { attachments: 2, tests: 3, testsPassed: 3, hasBrd: true });
        expect(issue.key).toBe('NW-12');
        expect(issue.isDone).toBe(true);
        expect(issue.keyClass).toContain('done');
        expect(issue.assigneeInitials).toBe('MS');
        expect(issue.labels).toEqual(['mobile', 'offline']);
        expect(issue.epicName).toBe('Mobile app');
        expect(issue.hasAttachments).toBe(true);
        expect(issue.testsLabel).toBe('3/3');
        expect(issue.testsClass).toContain('badge-pass');
        expect(issue.hasBrd).toBe(true);
    });

    it('flags failed tests and works without stats', () => {
        expect(decorateIssue(RECORD, { tests: 2, testsPassed: 1, testsFailed: 1 }).testsClass).toContain('badge-fail');
        const plain = decorateIssue({ Id: 'x', Name: 'NW-2', Summary__c: 'Task' });
        expect(plain.type).toBe('Task');
        expect(plain.status).toBe('To Do');
        expect(plain.hasTests).toBe(false);
        expect(plain.assigneeName).toBe('Unassigned');
    });
});

describe('small helpers', () => {
    it('formats and compares values', () => {
        expect(initials('Tomas Novak')).toBe('TN');
        expect(initials('')).toBe('?');
        expect(keyNumber('NW-42')).toBe(42);
        expect(addDaysIso('2026-01-30', 3)).toBe('2026-02-02');
        expect(daysBetween('2026-01-01', '2026-01-15')).toBe(14);
        expect(sumPoints([{ points: 3 }, { points: null }, { points: 2.5 }])).toBe(5.5);
        expect(formatBytes(2048)).toBe('2 KB');
        expect(formatBytes(3 * 1024 * 1024)).toBe('3.0 MB');
        expect(matchesSearch(decorateIssue(RECORD), 'offline')).toBe(true);
        expect(matchesSearch(decorateIssue(RECORD), 'nw-12')).toBe(true);
        expect(matchesSearch(decorateIssue(RECORD), 'zzz')).toBe(false);
        expect(reduceErrors({ body: { message: 'Boom' } })).toBe('Boom');
    });

    it('builds Lightning Experience URLs outside an Experience Cloud site', () => {
        expect(exportUrl('ProjectSprintReport', 'a02', 'word')).toBe('/apex/ProjectSprintReport?id=a02&format=word');
        expect(fileDownloadUrl('069x')).toBe('/sfc/servlet.shepherd/document/download/069x');
    });
});
