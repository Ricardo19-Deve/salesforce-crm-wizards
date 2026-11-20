/**
 * Project Board people picker: search field for people to add to a project, in the glass design (light and dark),
 * used instead of lightning-record-picker, whose suggestion list ignores the theme.
 *
 * Suggestions come from ProjectBoardController.searchUsers (active internal users who are not members yet) after two
 * letters. Fires `change` with { userId, name } (userId null when the choice is cleared). clear() resets it.
 * Keyboard (WAI-ARIA combobox): arrows move through the suggestions, Enter chooses, Escape closes the list
 * without closing the dialog.
 */
import { LightningElement, api } from 'lwc';
import searchUsers from '@salesforce/apex/ProjectBoardController.searchUsers';
import { avatarStyle, initials } from 'c/projectBoardUtils';

const DELAY_MS = 250;

export default class ProjectBoardPeoplePicker extends LightningElement {
    @api projectId;
    @api label = 'Add a person';
    @api placeholder = 'Add a person…';

    term = '';
    results = [];
    open = false;
    searching = false;
    activeIndex = -1;
    selected = null;

    @api
    clear() {
        this.term = '';
        this.results = [];
        this.selected = null;
        this.open = false;
        const input = this.template.querySelector('input');
        if (input) input.value = '';
    }

    get options() {
        return this.results.map((r, i) => ({
            ...r,
            domId: `person-${i}`,
            index: i,
            cls: 'option' + (i === this.activeIndex ? ' active' : ''),
            ariaSelected: i === this.activeIndex ? 'true' : 'false',
            initials: initials(r.name),
            style: avatarStyle(r.id)
        }));
    }

    get showList() {
        return this.open && this.term.trim().length >= 2;
    }

    get hasResults() {
        return this.results.length > 0;
    }

    get emptyText() {
        return this.searching ? 'Searching…' : 'No one found';
    }

    get ariaExpanded() {
        return this.showList ? 'true' : 'false';
    }

    get activeDescendant() {
        return this.activeIndex >= 0 ? `person-${this.activeIndex}` : null;
    }

    get wrapClass() {
        return 'wrap' + (this.selected ? ' has-selection' : '');
    }

    get selectedStyle() {
        return this.selected ? avatarStyle(this.selected.id) : '';
    }

    get selectedInitials() {
        return this.selected ? initials(this.selected.name) : '';
    }

    handleInput(event) {
        this.term = event.target.value;
        if (this.selected) {
            this.selected = null;
            this.fire(null);
        }
        this.open = true;
        this.activeIndex = -1;
        clearTimeout(this._timer);
        if (this.term.trim().length < 2) {
            this.results = [];
            return;
        }
        this.searching = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.search(this.term), DELAY_MS);
    }

    async search(term) {
        try {
            const found = await searchUsers({ projectId: this.projectId, term });
            if (term === this.term) {
                this.results = found;
                this.activeIndex = found.length ? 0 : -1;
                this._reveal = true;
            }
        } catch {
            this.results = [];
        } finally {
            this.searching = false;
        }
    }

    renderedCallback() {
        if (this._reveal) {
            this._reveal = false;
            const list = this.template.querySelector('.list');
            if (list && list.scrollIntoView) list.scrollIntoView({ block: 'nearest' });
        }
    }

    handleKeydown(event) {
        if (event.key === 'Escape' && this.showList) {
            event.stopPropagation();
            this.open = false;
            return;
        }
        if (!this.showList || !this.results.length) return;
        const last = this.results.length - 1;
        if (event.key === 'ArrowDown') {
            this.activeIndex = this.activeIndex >= last ? 0 : this.activeIndex + 1;
        } else if (event.key === 'ArrowUp') {
            this.activeIndex = this.activeIndex <= 0 ? last : this.activeIndex - 1;
        } else if (event.key === 'Enter') {
            if (this.activeIndex >= 0) this.choose(this.results[this.activeIndex]);
        } else {
            return;
        }
        event.preventDefault();
    }

    handleOptionDown(event) {
        // Keeps the focus in the field while the mouse chooses
        event.preventDefault();
    }

    handleOptionClick(event) {
        this.choose(this.results[Number(event.currentTarget.dataset.index)]);
    }

    handleHover(event) {
        this.activeIndex = Number(event.currentTarget.dataset.index);
    }

    handleBlur() {
        this.open = false;
    }

    choose(person) {
        if (!person) return;
        this.selected = person;
        this.term = person.name;
        this.open = false;
        const input = this.template.querySelector('input');
        if (input) input.value = person.name;
        this.fire(person);
    }

    clearChoice() {
        this.clear();
        this.fire(null);
        const input = this.template.querySelector('input');
        if (input) input.focus();
    }

    fire(person) {
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: {
                    userId: person ? person.id : null,
                    name: person ? person.name : null
                }
            })
        );
    }
}
