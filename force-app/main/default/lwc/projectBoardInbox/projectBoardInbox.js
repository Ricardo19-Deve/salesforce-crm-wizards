/**
 * Project Board inbox: the bell in the top bar, with the unread count and the latest notifications.
 *
 * It polls every minute while the app is open and whenever the app calls refresh(). Selecting a notification
 * marks it read and fires `openitem` ({ issueId, projectId, type }); the app opens the issue, or the Requests
 * view for requests the user cannot open.
 * Keyboard: the bell is a button; Escape closes the panel and returns the focus to the bell.
 */
import { LightningElement, api } from 'lwc';
import getInbox from '@salesforce/apex/ProjectActivityController.getInbox';
import markRead from '@salesforce/apex/ProjectActivityController.markRead';
import { avatarStyle, initials, toTime } from 'c/projectBoardUtils';

const POLL_MS = 60000;
const TYPE_ICON = {
    Assigned: 'utility:user',
    Mentioned: 'utility:comments',
    Commented: 'utility:comments',
    Status: 'utility:sync',
    Request: 'utility:new',
    'Sign-off': 'utility:approval'
};

export default class ProjectBoardInbox extends LightningElement {
    open = false;
    unread = 0;
    items = [];

    connectedCallback() {
        this.refresh();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => this.refresh(), POLL_MS);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    @api
    async refresh() {
        try {
            const inbox = await getInbox();
            this.unread = inbox.unread;
            this.items = inbox.items;
        } catch {
            // The bell stays as it was; the next poll tries again
        }
    }

    get hasUnread() {
        return this.unread > 0;
    }

    get badge() {
        return this.unread > 99 ? '99+' : String(this.unread);
    }

    get bellLabel() {
        return this.unread ? `Notifications, ${this.unread} unread` : 'Notifications';
    }

    get ariaExpanded() {
        return this.open ? 'true' : 'false';
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get rows() {
        return this.items.map((n) => ({
            ...n,
            cls: 'item' + (n.read ? '' : ' unread'),
            isUnread: !n.read,
            icon: TYPE_ICON[n.type] || 'utility:notification',
            hasActor: !!n.actorId,
            actorInitials: initials(n.actorName),
            actorStyle: n.actorId ? avatarStyle(n.actorId) : '',
            created: toTime(n.createdDate)
        }));
    }

    toggle() {
        this.open = !this.open;
        if (this.open) this.refresh();
    }

    close() {
        this.open = false;
    }

    handleKeydown(event) {
        if (event.key === 'Escape' && this.open) {
            event.stopPropagation();
            this.open = false;
            const bell = this.template.querySelector('.bell');
            if (bell) bell.focus();
        }
    }

    async handleOpen(event) {
        const item = this.items.find((n) => n.id === event.currentTarget.dataset.id);
        if (!item) return;
        this.open = false;
        if (!item.read) {
            this.items = this.items.map((n) => (n.id === item.id ? { ...n, read: true } : n));
            this.unread = Math.max(0, this.unread - 1);
            markRead({ notificationIds: [item.id] }).catch(() => {});
        }
        this.dispatchEvent(
            new CustomEvent('openitem', {
                detail: {
                    issueId: item.issueId,
                    projectId: item.projectId,
                    type: item.type
                }
            })
        );
    }

    async markAll() {
        this.items = this.items.map((n) => ({ ...n, read: true }));
        this.unread = 0;
        try {
            await markRead({ notificationIds: [] });
        } finally {
            this.refresh();
        }
    }
}
