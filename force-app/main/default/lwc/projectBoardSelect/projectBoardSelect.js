/**
 * Project Board select: a picklist in the glass design system, used instead of the native <select>
 * (whose open list is drawn by the operating system and ignores the theme).
 *
 * Drop-in for the old markup: give it `options` ([{ value, label, selected }]) and listen to `change`.
 * The event is fired by the host, so handlers keep reading `event.target.value` and
 * `event.target.dataset`; `event.detail.value` carries the same value.
 *
 * Keyboard (WAI-ARIA listbox): Enter / Space / Arrow keys open it, the arrows, Home and End
 * move, a letter jumps to the next option starting with it, Enter / Space choose,
 * Escape closes and Tab closes and moves on.
 *
 * Variants: "field" (default, form field), "compact" (inline quick create), "pill" (filters),
 * "status" (coloured status pill; set `tone` to todo / progress / review / done).
 */
import { LightningElement, api } from 'lwc';

const LIST_MAX_HEIGHT = 264;

export default class ProjectBoardSelect extends LightningElement {
    @api label;
    @api disabled = false;
    @api variant = 'field';
    @api tone;

    open = false;
    openUp = false;
    activeIndex = -1;
    _options = [];
    _value;
    _typed = '';
    _typedAt = 0;
    _focusActive = false;

    @api
    get options() {
        return this._options;
    }
    set options(list) {
        this._options = Array.isArray(list) ? list : [];
        const chosen = this._options.find((o) => o.selected);
        if (chosen) this._value = this.str(chosen.value);
    }

    @api
    get value() {
        if (this._value !== undefined) return this._value;
        return this._options.length ? this.str(this._options[0].value) : '';
    }
    set value(v) {
        this._value = this.str(v);
    }

    /** Gives the focus to the button, like focus() on a native select. */
    @api
    focus() {
        const trigger = this.template.querySelector('.trigger');
        if (trigger) trigger.focus();
    }

    str(v) {
        return v === null || v === undefined ? '' : String(v);
    }

    get selectedIndex() {
        const v = this.value;
        return this._options.findIndex((o) => this.str(o.value) === v);
    }

    get selectedLabel() {
        const i = this.selectedIndex;
        return i >= 0 ? this._options[i].label : '';
    }

    get items() {
        const selected = this.selectedIndex;
        return this._options.map((o, i) => ({
            key: `${i}-${this.str(o.value)}`,
            value: this.str(o.value),
            label: o.label,
            index: i,
            ariaSelected: i === selected ? 'true' : 'false',
            isSelected: i === selected,
            cls: 'option' + (i === selected ? ' selected' : '') + (i === this.activeIndex ? ' active' : '')
        }));
    }

    get wrapClass() {
        return `wrap v-${this.variant}` + (this.tone ? ` tone-${this.tone}` : '') + (this.open ? ' is-open' : '');
    }

    get listClass() {
        return 'list' + (this.openUp ? ' up' : '');
    }

    get ariaExpanded() {
        return this.open ? 'true' : 'false';
    }

    // ---------------------------------------------------------------- Open / close

    openList() {
        if (this.disabled || this.open) return;
        const trigger = this.template.querySelector('.trigger');
        if (trigger) {
            const rect = trigger.getBoundingClientRect();
            const below = window.innerHeight - rect.bottom;
            const needed = Math.min(LIST_MAX_HEIGHT, this._options.length * 38 + 12);
            this.openUp = below < needed && rect.top > below;
        }
        this.activeIndex = Math.max(this.selectedIndex, 0);
        this.open = true;
        this._focusActive = true;
    }

    closeList(focusTrigger) {
        if (!this.open) return;
        this.open = false;
        this.activeIndex = -1;
        if (focusTrigger) this.focus();
    }

    renderedCallback() {
        if (this.open && this._focusActive) {
            this._focusActive = false;
            const el = this.template.querySelector(`.option[data-index="${this.activeIndex}"]`);
            if (el) {
                el.focus();
                if (el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
            }
        }
    }

    moveTo(index) {
        const last = this._options.length - 1;
        this.activeIndex = Math.min(Math.max(index, 0), last);
        this._focusActive = true;
    }

    choose(index) {
        const option = this._options[index];
        if (!option) return;
        const value = this.str(option.value);
        const changed = value !== this.value;
        this._value = value;
        this.closeList(true);
        if (changed) {
            this.dispatchEvent(new CustomEvent('change', { detail: { value } }));
        }
    }

    // ---------------------------------------------------------------- Events

    handleTriggerClick() {
        if (this.open) this.closeList(true);
        else this.openList();
    }

    handleTriggerKey(event) {
        if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(event.key)) {
            event.preventDefault();
            this.openList();
        }
    }

    handleListKey(event) {
        const key = event.key;
        if (key === 'ArrowDown') this.moveTo(this.activeIndex + 1);
        else if (key === 'ArrowUp') this.moveTo(this.activeIndex - 1);
        else if (key === 'Home') this.moveTo(0);
        else if (key === 'End') this.moveTo(this._options.length - 1);
        else if (key === 'Enter' || key === ' ') this.choose(this.activeIndex);
        else if (key === 'Escape') {
            // Keep Escape from also closing the dialog the select sits in
            event.stopPropagation();
            this.closeList(true);
        } else if (key === 'Tab') {
            this.closeList(true);
            return;
        } else if (key.length === 1 && /\S/.test(key)) {
            this.typeAhead(key);
        } else {
            return;
        }
        event.preventDefault();
    }

    typeAhead(char) {
        const now = Date.now();
        this._typed = (now - this._typedAt > 700 ? '' : this._typed) + char.toLowerCase();
        this._typedAt = now;
        const count = this._options.length;
        const start = this._typed.length === 1 ? this.activeIndex + 1 : this.activeIndex;
        for (let step = 0; step < count; step++) {
            const i = (start + step) % count;
            if (String(this._options[i].label).toLowerCase().startsWith(this._typed)) {
                this.moveTo(i);
                return;
            }
        }
    }

    handleOptionClick(event) {
        this.choose(Number(event.currentTarget.dataset.index));
    }

    handleOptionHover(event) {
        this.activeIndex = Number(event.currentTarget.dataset.index);
    }

    handleFocusOut(event) {
        const wrap = this.template.querySelector('.wrap');
        if (!wrap || !wrap.contains(event.relatedTarget)) this.closeList(false);
    }
}
