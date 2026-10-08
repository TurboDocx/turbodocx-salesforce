import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import sendForSignature from '@salesforce/apex/TurboSignQuickActionController.sendForSignature';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';

export default class TurboSignSendModal extends LightningElement {
    @api recordId;
    @api objectApiName;

    // step: 'pick' -> choose the document; 'review' -> confirm/correct values, then send
    step = 'pick';

    configOptions = [];
    configDeveloperName = '';
    loadingConfigs = true;
    loadError;

    // review state
    preparing = false;
    prepareError;
    documentName = '';
    fields = []; // { placeholder, label, value, source, isLong }
    signers = []; // { role, name, email, nameSourceLabel, emailSourceLabel } — editable
    anchors = []; // { anchor, type, role, found (optional) }
    sending = false;

    @wire(listConfigs, { sourceObject: '$objectApiName' })
    wiredConfigs({ data, error }) {
        this.loadingConfigs = false;
        if (data) {
            this.configOptions = data.map((c) => ({ label: c.label, value: c.value }));
            if (this.configOptions.length === 1) this.configDeveloperName = this.configOptions[0].value;
        } else if (error) {
            this.loadError = (error.body && error.body.message) || 'Could not load signature setups.';
        }
    }

    // ---- step 1: pick ----
    get isPick() { return this.step === 'pick'; }
    get isReview() { return this.step === 'review'; }
    get hasConfigs() { return this.configOptions.length > 0; }
    get reviewDisabled() { return this.preparing || !this.configDeveloperName; }
    get chosenLabel() {
        const c = this.configOptions.find((o) => o.value === this.configDeveloperName);
        return c ? c.label : this.configDeveloperName;
    }
    handleConfigChange(e) { this.configDeveloperName = e.detail.value; }

    async handleReview() {
        this.preparing = true;
        this.prepareError = undefined;
        try {
            const pv = await previewForSignature({ recordId: this.recordId, configDeveloperName: this.configDeveloperName });
            this.documentName = pv.documentName;
            // Signers are editable too, prefilled from the record, each showing its source path.
            this.signers = (pv.recipients || []).map((r, i) => ({
                key: `${i}:${r.role || ''}`, // stable unique key — two recipients may share a role
                role: r.role,
                heading: `Signer ${i + 1}`, // role is a hidden id (signer_<n>); show the signing position
                name: r.name == null ? '' : String(r.name),
                email: r.email == null ? '' : String(r.email),
                nameSourceLabel: r.nameSourceLabel ? `from ${r.nameSourceLabel}` : 'manual',
                emailSourceLabel: r.emailSourceLabel ? `from ${r.emailSourceLabel}` : 'manual'
            }));
            this.anchors = pv.anchors || [];
            // Hide anchor-indirection plumbing: a variable whose placeholder IS a signature anchor
            // (e.g. {sig} -> "{sig}") only exists to keep the token in the doc — not a value to edit.
            const anchorSet = new Set((this.anchors || []).map((a) => a.anchor));
            this.fields = (pv.variables || [])
                .filter((v) => !anchorSet.has(v.placeholder))
                .map((v) => {
                    const value = v.value == null ? '' : String(v.value);
                    return {
                        placeholder: v.placeholder,
                        label: v.label || v.placeholder,
                        value,
                        isLong: value.length > 48,
                        source: v.source || null, // raw path (e.g. "Account.Name") kept for traceability
                        // Friendly, label-based provenance from Apex (e.g. "Account · Account Name").
                        sourceLabel: v.sourceLabel ? `from ${v.sourceLabel}` : 'manual default'
                    };
                });
            this.step = 'review';
            this.runAnchorCheck(); // non-blocking: fields are usable immediately; QA fills in when ready
        } catch (e) {
            this.prepareError = (e && e.body && e.body.message) || 'Could not prepare the document. Check the configuration and try again.';
        } finally {
            this.preparing = false;
        }
    }

    // Render the deliverable at TurboDocx and mark each anchor found/missing. Best-effort — if it
    // fails or is slow, the review stays fully usable and the rep can still send.
    async runAnchorCheck() {
        try {
            const reports = await checkAnchors({ recordId: this.recordId, configDeveloperName: this.configDeveloperName });
            const foundBy = {};
            (reports || []).forEach((r) => { foundBy[r.anchor] = r.found === true; });
            this.anchors = this.anchors.map((a) => ({ ...a, found: foundBy[a.anchor] }));
        } catch (e) {
            // leave anchors unverified — non-blocking by design
        }
    }

    // ---- step 2: review ----
    get intentLine() {
        const who = this.signers.length === 1
            ? (this.signers[0].name || this.signers[0].email || 'the recipient')
            : `${this.signers.length} recipients`;
        return `Sending ${this.documentName} to ${who}.`;
    }
    get hasSigners() { return this.signers.length > 0; }

    handleSignerEdit(e) {
        const key = e.target.dataset.key;
        const which = e.target.dataset.field; // 'name' | 'email'
        const value = e.target.value;
        this.signers = this.signers.map((s) => (s.key === key ? { ...s, [which]: value } : s));
    }
    get hasFields() { return this.fields.length > 0; }
    get shortFields() { return this.fields.filter((f) => !f.isLong); }
    get longFields() { return this.fields.filter((f) => f.isLong); }

    // silent when healthy, loud when broken (only meaningful once anchors carry a `found` flag)
    get anchorsChecked() { return this.anchors.some((a) => a.found !== undefined); }
    get missingAnchors() { return this.anchors.filter((a) => a.found === false); }
    get anchorsAllFound() { return this.anchorsChecked && this.missingAnchors.length === 0; }
    get anchorList() {
        return this.anchors.map((a) => ({
            key: a.anchor + a.role, anchor: a.anchor,
            desc: `${this.titleCase(a.type)}${a.role ? ' · ' + a.role : ''}`
        }));
    }

    handleFieldEdit(e) {
        const ph = e.target.dataset.placeholder;
        const value = e.target.value;
        this.fields = this.fields.map((f) => (f.placeholder === ph ? { ...f, value } : f));
    }

    async handleSend() {
        this.sending = true;
        try {
            const overrides = { variables: {}, recipients: [] };
            this.fields.forEach((f) => { overrides.variables[f.placeholder] = f.value; });
            overrides.recipients = this.signers.map((s) => ({ role: s.role, name: s.name, email: s.email }));
            // Resolves after TurboDocx accepted the envelope ({ ok: true }) or with the reason it didn't
            // ({ ok: false, message, maybeSent }), so "Sent" is never shown early.
            const res = await sendForSignature({
                recordId: this.recordId,
                configDeveloperName: this.configDeveloperName,
                overridesJson: JSON.stringify(overrides)
            });
            if (!res || !res.ok) {
                this.dispatchEvent(new ShowToastEvent({
                    title: res && res.maybeSent ? 'Check before sending again' : 'Send failed',
                    message: (res && res.message) || 'The document could not be sent. Try again.',
                    variant: res && res.maybeSent ? 'warning' : 'error',
                    mode: res && res.maybeSent ? 'sticky' : 'dismissible'
                }));
                return;
            }
            this.dispatchEvent(new ShowToastEvent({
                title: 'Sent for signature',
                message: `${this.documentName} is on its way to the signers. It will appear under TurboSign Signatures on this record.`,
                variant: 'success'
            }));
            this.close();
        } catch (e) {
            const msg = (e && e.body && e.body.message) ? e.body.message : 'The document could not be sent. Try again.';
            this.dispatchEvent(new ShowToastEvent({ title: 'Send failed', message: msg, variant: 'error' }));
        } finally {
            this.sending = false;
        }
    }

    handleBack() { this.step = 'pick'; }
    handleCancel() { this.close(); }
    close() { this.dispatchEvent(new CloseActionScreenEvent()); }

    titleCase(s) {
        if (!s) return '';
        return s.replace(/[_-]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    }
}
