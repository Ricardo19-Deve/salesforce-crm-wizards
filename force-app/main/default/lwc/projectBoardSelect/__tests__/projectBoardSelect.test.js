import { createElement } from 'lwc';
import ProjectBoardSelect from 'c/projectBoardSelect';

const OPTIONS = [
    { value: 'High', label: 'High' },
    { value: 'Medium', label: 'Medium', selected: true },
    { value: 'Low', label: 'Low' }
];

function mount(props = {}) {
    const el = createElement('c-project-board-select', { is: ProjectBoardSelect });
    Object.assign(el, { label: 'Priority', options: OPTIONS }, props);
    document.body.appendChild(el);
    return el;
}

const flush = () => Promise.resolve();
const trigger = (el) => el.shadowRoot.querySelector('.trigger');
const list = (el) => el.shadowRoot.querySelector('[role="listbox"]');
const key = (target, k) => target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true }));

describe('c-project-board-select', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    });

    it('shows the selected option and exposes its value', () => {
        const el = mount();
        expect(trigger(el).textContent).toContain('Medium');
        expect(trigger(el).getAttribute('aria-label')).toBe('Priority');
        expect(el.value).toBe('Medium');
    });

    it('opens from the keyboard with the selected option focused', async () => {
        const el = mount();
        key(trigger(el), 'ArrowDown');
        await flush();
        expect(list(el)).not.toBeNull();
        expect(trigger(el).getAttribute('aria-expanded')).toBe('true');
        const active = el.shadowRoot.activeElement;
        expect(active.getAttribute('role')).toBe('option');
        expect(active.getAttribute('aria-selected')).toBe('true');
    });

    it('chooses with the arrows and Enter, and fires change from the host', async () => {
        const el = mount();
        const handler = jest.fn();
        el.addEventListener('change', handler);
        key(trigger(el), 'ArrowDown');
        await flush();
        key(list(el), 'ArrowDown');
        await flush();
        key(list(el), 'Enter');
        await flush();
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.value).toBe('Low');
        expect(el.value).toBe('Low');
        expect(list(el)).toBeNull();
    });

    it('closes on Escape without changing the value or reaching the dialog', async () => {
        const el = mount();
        const outer = jest.fn();
        document.body.addEventListener('keydown', outer);
        const handler = jest.fn();
        el.addEventListener('change', handler);
        trigger(el).click();
        await flush();
        key(list(el), 'Escape');
        await flush();
        expect(list(el)).toBeNull();
        expect(handler).not.toHaveBeenCalled();
        expect(outer).not.toHaveBeenCalled();
        document.body.removeEventListener('keydown', outer);
    });

    it('jumps to an option by its first letter', async () => {
        const el = mount();
        trigger(el).click();
        await flush();
        key(list(el), 'h');
        await flush();
        key(list(el), 'Enter');
        await flush();
        expect(el.value).toBe('High');
    });

    it('stays closed when disabled', async () => {
        const el = mount({ disabled: true });
        key(trigger(el), 'ArrowDown');
        await flush();
        expect(list(el)).toBeNull();
    });
});
