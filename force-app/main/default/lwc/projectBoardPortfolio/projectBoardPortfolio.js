/**
 * Project Board portfolio: every project the user can see, with the health of each one.
 *
 * Health (computed in ProjectPlanController): Off track when a milestone is late or the sprint is far behind its
 * calendar; At risk when work is overdue, blocked or behind; otherwise On track. The reasons are listed under the
 * status, so the colour is never the only signal.
 * Selecting a project opens its board.
 */
import { LightningElement, api } from 'lwc';
import getPortfolio from '@salesforce/apex/ProjectPlanController.getPortfolio';
import { avatarStyle, formatShortDate, reduceErrors } from 'c/projectBoardUtils';

const HEALTH = {
    'On track': { cls: 'health health-ok', icon: '✓', order: 2 },
    'At risk': { cls: 'health health-risk', icon: '!', order: 1 },
    'Off track': { cls: 'health health-off', icon: '✕', order: 0 }
};

export default class ProjectBoardPortfolio extends LightningElement {
    @api currentProjectId;

    rows = [];
    loading = true;
    error;

    connectedCallback() {
        this.load();
    }

    /** Reloads the figures (the app calls it after changes in a project). */
    @api
    async load() {
        this.loading = true;
        this.error = null;
        try {
            this.rows = await getPortfolio();
        } catch (e) {
            this.error = reduceErrors(e);
        } finally {
            this.loading = false;
        }
    }

    get projects() {
        return [...this.rows]
            .sort((a, b) => HEALTH[a.health].order - HEALTH[b.health].order || a.name.localeCompare(b.name))
            .map((r) => {
                const health = HEALTH[r.health];
                const hasSprint = !!r.sprintName;
                return {
                    ...r,
                    avatarStyle: avatarStyle(r.id),
                    initial: (r.key || '?').charAt(0),
                    healthClass: health.cls,
                    healthIcon: health.icon,
                    leadsText: r.leads.length ? r.leads.join(', ') : 'No lead',
                    roleText: r.myRole || 'Admin',
                    membersText: `${r.members} member${r.members === 1 ? '' : 's'}`,
                    hasSprint,
                    sprintDates:
                        hasSprint && r.sprintStart
                            ? `${formatShortDate(r.sprintStart)} – ${formatShortDate(r.sprintEnd)}`
                            : '',
                    progressText: hasSprint ? `${r.progress || 0}%` : '',
                    progressStyle: `width:${Math.min(100, r.progress || 0)}%`,
                    timeStyle: `left:${Math.min(100, r.timeElapsed || 0)}%`,
                    progressLabel: hasSprint
                        ? `${r.progress || 0}% of the points done, ${r.timeElapsed || 0}% of the sprint time elapsed`
                        : '',
                    pointsText: hasSprint ? `${r.sprintDone} / ${r.sprintPoints} pts` : '',
                    hasMilestone: !!r.milestoneDate,
                    milestoneText: r.milestoneDate ? `${formatShortDate(r.milestoneDate)} · ${r.milestoneKey}` : '',
                    milestoneClass: 'cell-value' + (r.milestoneLate ? ' late' : ''),
                    overdueClass: 'num' + (r.overdue ? ' num-bad' : ''),
                    blockedClass: 'num' + (r.blocked ? ' num-bad' : ''),
                    requestsClass: 'num' + (r.requests ? ' num-info' : ''),
                    signOffClass: 'num' + (r.signOffsPending ? ' num-info' : ''),
                    hasReasons: r.reasons && r.reasons.length > 0,
                    cardClass: 'card glass' + (r.id === this.currentProjectId ? ' card-current' : ''),
                    openLabel: `Open ${r.name}`
                };
            });
    }

    get hasProjects() {
        return this.rows.length > 0;
    }

    get totals() {
        const count = (h) => this.rows.filter((r) => r.health === h).length;
        const sum = (f) => this.rows.reduce((t, r) => t + (r[f] || 0), 0);
        return {
            projects: this.rows.length,
            onTrack: count('On track'),
            atRisk: count('At risk'),
            offTrack: count('Off track'),
            overdue: sum('overdue'),
            blocked: sum('blocked'),
            requests: sum('requests'),
            signOffs: sum('signOffsPending')
        };
    }

    get showEmpty() {
        return !this.loading && !this.error && !this.hasProjects;
    }

    openProject(event) {
        this.dispatchEvent(
            new CustomEvent('openproject', {
                detail: { id: event.currentTarget.dataset.id }
            })
        );
    }
}
