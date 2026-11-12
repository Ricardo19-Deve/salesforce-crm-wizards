import { LightningElement, api } from 'lwc';

/**
 * Renders one configured field (descriptor from wizardFieldUtils.decorateField) with the matching base component
 * and reports changes as a "fieldchange" event: detail = { apiName, value }.
 */
export default class WizardFieldInput extends LightningElement {
    @api field;

    @api
    reportValidity() {
        const input = this.template.querySelector('[data-input]');
        return typeof input?.reportValidity === 'function' ? input.reportValidity() : true;
    }

    handleChange(event) {
        let value;
        if (this.field.isCheckbox) {
            value = Boolean(event.detail?.checked ?? event.target?.checked);
        } else if (this.field.isLookup) {
            value = event.detail?.recordId || null;
        } else {
            value = event.detail?.value !== undefined ? event.detail.value : event.target?.value;
        }
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { apiName: this.field.apiName, value } }));
    }
}
