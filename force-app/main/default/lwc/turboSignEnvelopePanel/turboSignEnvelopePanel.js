import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEnvelopes from '@salesforce/apex/TurboSignQuickActionController.getEnvelopes';
import remind from '@salesforce/apex/TurboSignQuickActionController.remind';
import voidEnvelope from '@salesforce/apex/TurboSignQuickActionController.voidEnvelope';
import syncEnvelope from '@salesforce/apex/TurboSignRecipientSync.syncEnvelope';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import ENVELOPE_SENT from '@salesforce/messageChannel/TurboSign_Envelope_Sent__c';

const STATUS_VARIANT = {
    draft: 'inverse', sent: 'warning', under_review: 'warning',
    review_ready: 'warning', completed: 'success', voided: 'error', expired: 'error'
};

// Out for signature: the only statuses with signers to remind, a request to void, and a status a
// sync can move. Finished documents and review-only drafts (draft, review_ready) get none of these.
const OUT_FOR_SIGNATURE = new Set(['sent', 'under_review']);
// A review link can carry an out-for-signature status before anyone sends it; only Sent_On__c (set by
// a send, or by a sync once TurboDocx reports it sent) says signers actually have it.
const isOutForSignature = (e) => OUT_FOR_SIGNATURE.has(e.Status__c) && !!e.Sent_On__c;
// syncEnvelope throttles itself server-side (5 minutes unless forced). This mirror only saves the
// round trip and reload when the cached rows already show a recent sync.
const RECENT_SYNC_MS = 5 * 60 * 1000;

export default class TurboSignEnvelopePanel extends LightningElement {
    @api recordId;
    envelopes = [];
    loading = true;
    loadError;
    busyId;
    _wired;
    _autoSyncedFor; // recordId whose envelopes were already status-synced on this load
    autoSyncing = false; // load-time sync in flight; Refresh waits for it so the two can't overlap

    // void modal
    voidModalOpen = false;
    voidReason = '';
    voidTargetId;

    @wire(MessageContext) messageContext;
    _sentSubscription;

    // The Send for Signature modal publishes on this channel once TurboDocx accepts a send, so the
    // new envelope shows here without the rep pressing Refresh. Application scope: the quick-action
    // modal is not in this panel's active area.
    connectedCallback() {
        if (!this._sentSubscription) {
            this._sentSubscription = subscribe(this.messageContext, ENVELOPE_SENT,
                (message) => this.handleEnvelopeSent(message), { scope: APPLICATION_SCOPE });
        }
    }
    disconnectedCallback() {
        unsubscribe(this._sentSubscription);
        this._sentSubscription = undefined;
    }
    handleEnvelopeSent(message) {
        if (!message || message.recordId !== this.recordId || !this._wired) return;
        refreshApex(this._wired);
    }

    @wire(getEnvelopes, { recordId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.loading = false;
            this.loadError = undefined;
            this.envelopes = result.data.map((e) => ({
                ...e,
                statusVariant: STATUS_VARIANT[e.Status__c] || 'inverse',
                canAct: isOutForSignature(e),
                progress: `${e.Signed_Count__c || 0} of ${e.Recipient_Count__c || 0} signed`
            }));
            this.syncUnfinishedOnce();
        } else if (result.error) {
            this.loading = false;
            this.loadError = (result.error.body && result.error.body.message) || 'Could not load signatures.';
        }
    }

    // The cached rows can lag the real status (e.g. still "sent" after the document was signed),
    // so on load pull the live status for any unfinished envelope once, then reload. Imperative
    // calls (getEnvelopes is a cacheable wire and can't make the callout); the cached rows stay on
    // screen meanwhile; and the once-per-record guard means the reload can't trigger another sync.
    async syncUnfinishedOnce() {
        if (this._autoSyncedFor === this.recordId) return;
        // Guard on the first data for this record, syncable or not: a later reload (e.g. after a fresh
        // send) carries a just-sent envelope whose status is already current, so syncing it is wasted.
        this._autoSyncedFor = this.recordId;
        // Only statuses a sync can move: a review-only draft never changes, so it would re-sync on
        // every page view.
        const unfinished = this.envelopes.filter((e) =>
            isOutForSignature(e) && !this.syncedRecently(e));
        if (!unfinished.length) return;
        // Best-effort and quiet: the rep can still press Refresh, which reports failures.
        this.autoSyncing = true;
        try {
            await Promise.allSettled(unfinished.map((e) => syncEnvelope({ envelopeId: e.Id })));
            await refreshApex(this._wired);
        } catch (e) {
            // Keep showing the cached rows.
        } finally {
            this.autoSyncing = false;
        }
    }

    syncedRecently(e) {
        // A future timestamp (clock skew) is not "recent": let the server decide.
        const age = Date.now() - Date.parse(e.Last_Synced__c);
        return age >= 0 && age < RECENT_SYNC_MS;
    }

    get hasEnvelopes() {
        return this.envelopes && this.envelopes.length > 0;
    }
    get showEmpty() {
        return !this.loading && !this.loadError && !this.hasEnvelopes;
    }
    get refreshDisabled() {
        return this.loading || this.autoSyncing;
    }
    get voidConfirmDisabled() {
        return !this.voidReason || !!this.busyId;
    }

    async handleRefresh() {
        if (this.autoSyncing) return;
        this.loading = true;
        try {
            // Pull the latest per-recipient status from the backend into child records so the
            // progress counts + the "Envelopes with Recipients" reports reflect current state.
            // Each syncEnvelope is its own Apex transaction (a callout can't follow DML in one
            // transaction), and it's best-effort — one failure must not block the refresh.
            // Finished envelopes are synced too: a void from Salesforce marks the envelope voided
            // without updating its recipient rows, and only a sync corrects them.
            const results = await Promise.allSettled(
                (this.envelopes || []).map((e) => syncEnvelope({ envelopeId: e.Id, force: true }))
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
