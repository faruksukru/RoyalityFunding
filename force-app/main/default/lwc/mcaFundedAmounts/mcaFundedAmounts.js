// mcaFundedAmounts.js — Record page component for entering a funded amount per MCA and saving them to the Opportunity.
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import Toast from 'lightning/toast';
import getFundedAmounts from '@salesforce/apex/MCAFunding_FundedAmountController.getFundedAmounts';
import saveFundedAmounts from '@salesforce/apex/MCAFunding_FundedAmountController.saveFundedAmounts';

const GENERIC_ERROR = 'An unexpected error occurred.';
const SAVE_SUCCESS = 'Funded amounts saved.';
const FULL_WIDTH = 12;
const HALF_WIDTH = 6;
const CELL_BASE_CLASS = 'slds-p-horizontal_x-small slds-p-vertical_xxx-small';

/**
 * Shows each populated MCA name with a Funded Amount ($) input, two per line in every page region,
 * and saves the amounts through Apex.
 * Validation, formatting and the stored text format live in MCAFunding_FundedAmountController;
 * the inputs' min and step only give the user immediate feedback.
 */
export default class McaFundedAmounts extends LightningElement {
    @api recordId;

    rows = [];
    savedAmounts = {};
    editingSlots = [];
    hoveredAmountSlot = null;
    isLoading = true;
    isSaving = false;
    loadError;
    wiredResult;

    @wire(getFundedAmounts, { recordId: '$recordId' })
    wiredAmounts(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.applyRows(data);
            this.loadError = undefined;
            this.isLoading = false;
        } else if (error) {
            this.rows = [];
            this.loadError = this.reduceError(error);
            this.isLoading = false;
        }
    }

    get hasRows() {
        return !this.isLoading && !this.loadError && this.rows.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.loadError && this.rows.length === 0;
    }

    get isBusy() {
        return this.isLoading || this.isSaving;
    }

    // Two columns keep the card short with all 8 MCAs, including in the narrow sidebar region.
    get isTwoColumn() {
        return this.rows.length > 1;
    }

    get gridClass() {
        return this.isTwoColumn ? 'mca-grid mca-grid_two' : 'mca-grid';
    }

    get itemSize() {
        return this.isTwoColumn ? HALF_WIDTH : FULL_WIDTH;
    }

    get leftHeaderClass() {
        return this.isTwoColumn ? `${CELL_BASE_CLASS} slds-border_right` : CELL_BASE_CLASS;
    }

    get displayRows() {
        const columns = this.isTwoColumn ? 2 : 1;
        const lastLine = Math.floor((this.rows.length - 1) / columns);
        return this.rows.map((row, index) => {
            const classes = [CELL_BASE_CLASS];
            if (Math.floor(index / columns) !== lastLine) {
                classes.push('slds-border_bottom');
            }
            if (columns === 2 && index % 2 === 0 && index + 1 < this.rows.length) {
                classes.push('slds-border_right');
            }
            return {
                ...row,
                cellClass: classes.join(' '),
                amountTooltip: this.formatAmountTooltip(row.value),
                hasAmount: row.value !== null && row.value !== undefined && row.value !== '',
                showAmountTooltip: this.hoveredAmountSlot === row.mcaNumber,
                isEditing: this.editingSlots.includes(row.mcaNumber),
                editLabel: `Edit funded amount for ${row.mcaName}, MCA slot ${row.mcaNumber}`
            };
        });
    }

    get isDirty() {
        return this.rows.some(
            (row) => this.toAmount(row.value) !== this.toAmount(this.savedAmounts[row.mcaNumber])
        );
    }

    get isCancelDisabled() {
        return this.isSaving || (!this.isDirty && this.editingSlots.length === 0);
    }

    get isSaveDisabled() {
        return this.isSaving || !this.isDirty;
    }

    handleAmountMouseEnter(event) {
        this.hoveredAmountSlot = Number(event.currentTarget.dataset.mcaNumber);
    }

    handleAmountMouseLeave() {
        this.hoveredAmountSlot = null;
    }

    handleEdit(event) {
        const mcaNumber = Number(event.currentTarget.dataset.mcaNumber);
        if (!this.editingSlots.includes(mcaNumber)) {
            this.editingSlots = [...this.editingSlots, mcaNumber];
        }
    }

    handleAmountChange(event) {
        const mcaNumber = Number(event.target.dataset.mcaNumber);
        const { value } = event.detail;
        this.rows = this.rows.map((row) => (row.mcaNumber === mcaNumber ? { ...row, value } : row));
    }

    handleCancel() {
        this.rows = this.rows.map((row) => ({ ...row, value: this.savedAmounts[row.mcaNumber] }));
        this.editingSlots = [];
    }

    async handleSave() {
        if (!this.validateInputs()) {
            return;
        }
        this.isSaving = true;
        try {
            const amounts = this.rows.map((row) => ({
                mcaNumber: row.mcaNumber,
                fundedAmount: this.toAmount(row.value)
            }));
            const savedRows = await saveFundedAmounts({ recordId: this.recordId, amounts });
            this.applyRows(savedRows);

            // Tells the record page the summary field changed, so the Details tab shows it without a reload.
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            await refreshApex(this.wiredResult);
            this.showToast('Saved', SAVE_SUCCESS, 'success');
        } catch (error) {
            this.showToast('Error', this.reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    applyRows(data) {
        const saved = {};
        this.rows = data.map((row) => {
            const value = row.fundedAmount ?? null;
            saved[row.mcaNumber] = value;
            return {
                key: `mca-${row.mcaNumber}`,
                mcaNumber: row.mcaNumber,
                mcaName: row.mcaName,
                inputLabel: `Funded Amount ($) for ${row.mcaName}`,
                value
            };
        });
        this.savedAmounts = saved;
        this.editingSlots = [];
        this.hoveredAmountSlot = null;
    }

    validateInputs() {
        const inputs = [...this.template.querySelectorAll('lightning-input')];
        return inputs.reduce((allValid, input) => input.reportValidity() && allValid, true);
    }

    // Full formatted amount is available on hover without widening the two-column card.
    formatAmountTooltip(value) {
        if (value === null || value === undefined || value === '') {
            return 'No funded amount entered';
        }
        const amount = Number(value);
        return Number.isFinite(amount)
            ? new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount)
            : String(value);
    }

    toAmount(value) {
        return value === null || value === undefined || value === '' ? null : Number(value);
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return GENERIC_ERROR;
    }

    showToast(label, message, variant) {
        Toast.show({ label, message, variant }, this);
    }
}
