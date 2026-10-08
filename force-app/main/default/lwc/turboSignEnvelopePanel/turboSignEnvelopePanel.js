import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEnvelopes from '@salesforce/apex/TurboSignQuickActionController.getEnvelopes';
import remind from '@salesforce/apex/TurboSignQuickActionController.remind';
import voidEnvelope from '@salesforce/apex/TurboSignQuickActionController.voidEnvelope';
import syncEnvelope from '@salesforce/apex/TurboSignRecipientSync.syncEnvelope';

const STATUS_VARIANT = {
    draft: 'inverse', sent: 'warning', under_review: 'warning',
    review_ready: 'warning', completed: 'success', voided: 'error', expired: 'error'
};

export default class TurboSignEnvelopePanel extends LightningElement {
    @api recordId;
    envelopes = [];
    loading = true;
    loadError;
    busyId;
    _wired;

    // void modal
    voidModalOpen = false;
    voidReason = '';
    voidTargetId;

    @wire(getEnvelopes, { recordId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.loading = false;
            this.loadError = undefined;
            this.envelopes = result.data.map((e) => ({
                ...e,
                statusVariant: STATUS_VARIANT[e.Status__c] || 'inverse',
                progress: `${e.Signed_Count__c || 0} of ${e.Recipient_Count__c || 0} signed`
            }));
        } else if (result.error) {
            this.loading = false;
            this.loadError = (result.error.body && result.error.body.message) || 'Could not load signatures.';
        }
    }

    get hasEnvelopes() {
        return this.envelopes && this.envelopes.length > 0;
    }
    get showEmpty() {
        return !this.loading && !this.loadError && !this.hasEnvelopes;
    }
    get voidConfirmDisabled() {
        return !this.voidReason || !!this.busyId;
    }

    async handleRefresh() {
        this.loading = true;
        try {
            // Pull the latest per-recipient status from the backend into child records so the
            // progress counts + the "Envelopes with Recipients" reports reflect current state.
            // Each syncEnvelope is its own Apex transaction (a callout can't follow DML in one
            // transaction), and it's best-effort — one failure must not block the refresh.
            const results = await Promise.allSettled(
                (this.envelopes || []).map((e) => syncEnvelope({ envelopeId: e.Id }))
            );
            const failed = results.filter((r) => r.status === 'rejected');
            if (failed.length) {
                // Still best-effort, but never silent: a missing permission or a 401 would otherwise
                // leave stale counts with no explanation.
                const reason = failed[0].reason && failed[0].reason.body && failed[0].reason.body.message;
                this.dispatchEvent(new ShowToastEvent({
                    title: `Couldn't refresh ${failed.length} of ${results.length} signature status${results.length === 1 ? '' : 'es'}`,
                    message: reason || 'Try again, or ask your admin to check the TurboDocx connection.',
                    variant: 'warning'
                }));
            }
            await refreshApex(this._wired);
        } finally {
            // If refreshApex rejects, the wire never re-fires; clear the spinner here so it can't hang.
            this.loading = false;
        }
    }

    async handleRemind(event) {
        const id = event.target.dataset.id;
        this.busyId = id;
        try {
            await remind({ envelopeId: id });
            this.toast('Reminder sent', 'The signers have been reminded by email.', 'success');
        } catch (e) {
            this.toast('Reminder failed', this.msg(e), 'error');
        } finally {
            this.busyId = undefined;
        }
    }

    // Void — SLDS modal instead of a browser prompt (which Lightning Web Security can block)
    openVoid(event) {
        this.voidTargetId = event.target.dataset.id;
        this.voidReason = '';
        this.voidModalOpen = true;
    }
    handleVoidReason(event) {
        this.voidReason = event.target.value;
    }
    closeVoid() {
        this.voidModalOpen = false;
        this.voidTargetId = undefined;
    }
    async confirmVoid() {
        this.busyId = this.voidTargetId;
        try {
            await voidEnvelope({ envelopeId: this.voidTargetId, reason: this.voidReason });
            this.toast('Envelope voided', 'The signature request has been cancelled.', 'success');
            this.closeVoid();
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Void failed', this.msg(e), 'error');
        } finally {
            this.busyId = undefined;
        }
    }

    msg(e) {
        return (e && e.body && e.body.message) ? e.body.message : 'Something went wrong. Try again.';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
