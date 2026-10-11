import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import sendForSignature from '@salesforce/apex/TurboSignQuickActionController.sendForSignature';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import previewPdf from '@salesforce/apex/TurboSignQuickActionController.previewPdf';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';
import getViewerUrl from '@salesforce/apex/TurboSignQuickActionController.getViewerUrl';
import FORM_FACTOR from '@salesforce/client/formFactor';
import { publish, MessageContext } from 'lightning/messageService';
import ENVELOPE_SENT from '@salesforce/messageChannel/TurboSign_Envelope_Sent__c';

// The viewer is a Visualforce page, served (enhanced domains) from <MyDomain>--<namespace>.vf.force.com, or
// .sandbox.vf.force.com, .develop.vf.force.com and so on, all ending in .vf.force.com.
function isVisualforceOrigin(origin) {
    let url;
    try { url = new URL(origin); } catch (err) { return false; }
    return url.protocol === 'https:' && url.hostname.endsWith('.vf.force.com');
}

// How long the viewer has to put the PDF on screen, once the PDF is ready and again once it is posted, before the
// modal says it couldn't be shown (a host the viewer doesn't accept, or a blocked frame, would leave it blank).
const VIEWER_SHOWN_TIMEOUT_MS = 15000;

function newNonce() {
    const words = new Uint32Array(4);
    window.crypto.getRandomValues(words);
    return Array.from(words, (w) => w.toString(16).padStart(8, '0')).join('');
}

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
    previewing = false;
    previewError;
    previewUrl; // blob: URL of the last rendered preview
    previewFileName = '';
    renderedValues; // the Details values the shown preview was rendered from
    renderSeq = 0; // bumps on every render and on Back/close, so a late result can't land
    previewBlob; // the last rendered PDF: backs previewUrl and is handed to the viewer page
    focusAfterRender = false; // the rep's button was replaced by the spinner; land them on the result
    activeTab = 'details'; // the tabset opens on Details; lightning-tab keeps a visited tab's content in the DOM
    frameFocused = false; // drives the focus ring: Chrome won't match :focus on an iframe holding focus
    viewerNonce; // fresh per render, on the viewer's URL: binds the handshake to this frame
    viewerTimedOut = false; // the viewer never confirmed it showed the PDF, or said it can't show it here
    viewerUnsupported = false; // the viewer said this browser downloads PDFs: a fresh viewer would fail the same way
    renderWhenViewerReady = false; // Document opened before the viewer URL arrived: render once it does
    waitAfterRender = false; // start the viewer timer once the fresh frame is on the page
    focusViewerAfterRender = false; // Try again on the viewer was clicked; focus the fresh frame
    viewerTimer;

    @wire(MessageContext) messageContext;

    // The viewer page's URL from Apex, which adds the package namespace prefix when there is one. A render spends a
    // deliverable, so none starts before this is known; Document opened earlier waits for it.
    viewerUrl;
    @wire(getViewerUrl)
    wiredViewerUrl({ data, error }) {
        this.viewerUrl = { data, error };
        if (error) this.renderWhenViewerReady = false;
        if (data && this.renderWhenViewerReady) {
            this.renderWhenViewerReady = false;
            this.renderPreview();
        }
    }
    get viewerSrc() { return this.viewerUrl && this.viewerUrl.data; }
    get viewerFrameSrc() {
        const src = this.viewerSrc;
        return `${src}${src.includes('?') ? '&' : '?'}nonce=${this.viewerNonce}`;
    }
    get showViewerFrame() { return !!this.viewerSrc && !this.viewerTimedOut; }
    // Without the viewer there is nowhere to show the PDF, so no render is spent.
    get viewerFailed() { return !!(this.viewerUrl && this.viewerUrl.error); }
    get viewerLoading() { return !this.viewerSrc && !this.viewerFailed; }
    get showViewerLoading() { return this.renderWhenViewerReady && this.viewerLoading; }
    get showRetryViewer() { return !this.viewerUnsupported; }

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
                // What Apex falls back to when the modal sends a blank email (record field or static email).
                originalEmail: r.email == null ? '' : String(r.email),
                required: r.required === true, // an optional signer without an email is dropped from the document
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
            this.activeTab = 'details';
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
        const value = e.target.value == null ? '' : String(e.target.value);
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

    // The rep's edits, in the shape sendForSignature and previewPdf both accept.
    buildOverrides() {
        const overrides = { variables: {}, recipients: [] };
        this.fields.forEach((f) => { overrides.variables[f.placeholder] = f.value; });
        overrides.recipients = this.signers.map((s) => ({ role: s.role, name: s.name, email: s.email }));
        return JSON.stringify(overrides);
    }

    // Stale = the Details values differ from the ones the preview was rendered from. Compared, not flagged,
    // so an edit made while a render is running (a minute or two) still shows the notice afterwards.
    get previewStale() { return !!this.previewUrl && this.valuesKey() !== this.renderedValues; }
    // A failed render with no earlier preview fills the tab; after a failed update the earlier preview stays
    // on screen (and its Open link) with the error and Try again above it, instead of the stale notice.
    get previewErrorOnly() { return !!this.previewError && !this.previewUrl; }
    get showStaleNotice() { return this.previewStale && !this.previewError; }
    // Only what changes the PDF: field values, and whether each optional signer has an email (one without is
    // dropped, and its anchors render empty). Signer names never reach the document. Apex uses the prefilled
    // email when the modal sends a blank one, so a cleared prefilled email still counts as an email.
    valuesKey() {
        return JSON.stringify([
            this.fields.map((f) => [f.placeholder, f.value]),
            this.signers.filter((s) => !s.required)
                .map((s) => [s.role, (s.email || '').trim() !== '' || (s.originalEmail || '').trim() !== ''])
        ]);
    }

    // First visit to the Document tab renders it; later visits reuse it until the rep asks for an update.
    handleDocumentTab() {
        this.activeTab = 'document';
        if (this.isMobileApp || this.viewerFailed) return;
        if (this.previewUrl || this.previewing || this.previewError) return;
        if (this.viewerLoading) this.renderWhenViewerReady = true;
        else this.renderPreview();
    }

    // The mobile app (phone Small, tablet Medium) has no reliable inline PDF viewer, so a render there would
    // only spend a deliverable on a blank frame.
    get isMobileApp() { return FORM_FACTOR !== 'Large'; }

    // Update preview / Try again: the clicked button is replaced by the spinner, so focus follows the result.
    handleDetailsTab() { this.activeTab = 'details'; }

    handleRequestRender() {
        if (this.viewerFailed) return;
        this.focusAfterRender = true;
        this.renderPreview();
    }

    renderedCallback() {
        if (this.waitAfterRender && this.template.querySelector('iframe[data-id="pdf"]')) {
            // The fresh viewer frame is on the page: from now on it has the full wait to show the PDF.
            this.waitAfterRender = false;
            this.waitForViewer();
        }
        if (this.focusViewerAfterRender) {
            // Try again's button is gone; land the rep on the fresh viewer.
            this.focusViewerAfterRender = false;
            const frame = this.template.querySelector('iframe[data-id="pdf"]');
            if (frame) {
                frame.focus();
                this.frameFocused = true;
            }
            return;
        }
        if (!this.focusAfterRender || this.previewing) return;
        // Once the render is done, focus moves now or not at all: if the rep switched tabs meanwhile the Document
        // tab is hidden (its content stays in the DOM), and focus must not jump into the frame on a later visit.
        this.focusAfterRender = false;
        if (this.activeTab !== 'document') return;
        const target = this.template.querySelector('lightning-button[data-id="retry-preview"]')
            || this.template.querySelector('iframe[data-id="pdf"]');
        if (target) {
            target.focus();
            this.frameFocused = target.tagName === 'IFRAME';
        }
    }

    get frameClass() { return this.frameFocused ? 'doc-frame doc-frame_focused' : 'doc-frame'; }
    handleFrameFocus() { this.frameFocused = true; }
    handleFrameBlur() { this.frameFocused = false; }

    // Render this send's document (with the edits on Details) at TurboDocx and show it in the Document tab.
    // Apex returns the PDF as base64, so the browser never holds TurboDocx credentials.
    async renderPreview() {
        const seq = ++this.renderSeq;
        const values = this.valuesKey();
        this.previewing = true;
        this.previewError = undefined;
        try {
            const res = await previewPdf({
                recordId: this.recordId,
                configDeveloperName: this.configDeveloperName,
                overridesJson: this.buildOverrides()
            });
            if (seq !== this.renderSeq) return; // the rep went back or closed the modal meanwhile
            const binary = atob(res.base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            this.clearPreview();
            this.previewBlob = new Blob([bytes], { type: 'application/pdf' });
            this.previewUrl = URL.createObjectURL(this.previewBlob);
            this.previewFileName = res.fileName || 'Document preview';
            this.renderedValues = values;
            this.viewerNonce = newNonce();
            this.waitAfterRender = true;
        } catch (e) {
            if (seq !== this.renderSeq) return;
            const message = e && e.body && e.body.message;
            // Lightning reports a dropped request as "Disconnected or Canceled"; say what to do instead.
            this.previewError = !message || /disconnected or canceled/i.test(message)
                ? "Couldn't reach Salesforce to render the document. Check your connection, then try again."
                : message;
        } finally {
            if (seq === this.renderSeq) this.previewing = false;
        }
    }

    // Lightning Web Security won't let an iframe load a blob: URL, so the Document tab frames a Visualforce
    // viewer (its own origin). The viewer says when it is ready; its message carries the Visualforce origin,
    // so the PDF is posted to exactly that origin. The frame is recreated on every render with a fresh nonce on
    // its URL, and only messages echoing that nonce count, so each render's PDF goes to its own frame. The viewer
    // acknowledges once the PDF is on screen; without that, the tab says so instead of showing a blank frame.
    connectedCallback() {
        this.onViewerMessage = (e) => this.handleViewerMessage(e);
        window.addEventListener('message', this.onViewerMessage);
    }

    handleViewerMessage(e) {
        const type = e.data && e.data.type;
        if (type !== 'turbosign-pdf-viewer-ready' && type !== 'turbosign-pdf-viewer-shown'
            && type !== 'turbosign-pdf-viewer-unsupported') return;
        if (!this.previewBlob || !this.viewerNonce || e.data.nonce !== this.viewerNonce) return;
        const frame = this.template.querySelector('iframe[data-id="pdf"]');
        if (!frame) return;
        // Lightning Web Security wraps event.source, so it never equals the frame's contentWindow there; a
        // Visualforce origin is accepted instead. The PDF still goes only to that exact origin, and the browser
        // delivers it only if the frame really is on it.
        if (e.source !== frame.contentWindow && !isVisualforceOrigin(e.origin)) return;
        if (type === 'turbosign-pdf-viewer-shown') {
            this.stopWaitingForViewer();
            return;
        }
        if (type === 'turbosign-pdf-viewer-unsupported') {
            // The browser would download the PDF rather than show it: say so now instead of after the wait.
            this.stopWaitingForViewer();
            this.viewerTimedOut = true;
            this.viewerUnsupported = true;
            return;
        }
        frame.contentWindow.postMessage(
            { type: 'turbosign-pdf', name: this.previewFileName, nonce: this.viewerNonce, blob: this.previewBlob }, e.origin);
        this.waitForViewer(); // the viewer now has the PDF: give it the full wait to show it
    }

    // Try again after the viewer timed out (not offered when the browser can't show PDFs inline): a fresh viewer (new frame, new nonce) for
    // the PDF already in memory, so no new render is spent.
    handleRetryViewer() {
        if (!this.previewBlob) return;
        this.viewerNonce = newNonce();
        this.viewerTimedOut = false;
        this.focusViewerAfterRender = true;
        this.waitAfterRender = true;
    }

    waitForViewer() {
        this.stopWaitingForViewer();
        const nonce = this.viewerNonce;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.viewerTimer = setTimeout(() => {
            this.viewerTimer = undefined;
            if (nonce === this.viewerNonce) this.viewerTimedOut = true;
        }, VIEWER_SHOWN_TIMEOUT_MS);
    }

    stopWaitingForViewer() {
        if (this.viewerTimer) clearTimeout(this.viewerTimer);
        this.viewerTimer = undefined;
    }

    clearPreview() {
        this.stopWaitingForViewer();
        this.waitAfterRender = false;
        this.viewerTimedOut = false;
        this.viewerUnsupported = false;
        this.viewerNonce = undefined;
        if (this.previewUrl) URL.revokeObjectURL(this.previewUrl);
        this.previewUrl = undefined;
        this.previewBlob = undefined;
    }

    // Back or close: forget the preview and any render still running.
    abandonPreview() {
        this.renderSeq++;
        this.renderWhenViewerReady = false;
        this.previewing = false;
        this.previewError = undefined;
        this.clearPreview();
    }

    disconnectedCallback() {
        window.removeEventListener('message', this.onViewerMessage);
        this.abandonPreview();
    }

    async handleSend() {
        this.sending = true;
        try {
            // Resolves after TurboDocx accepted the envelope ({ ok: true }) or with the reason it didn't
            // ({ ok: false, message, maybeSent }), so "Sent" is never shown early.
            const res = await sendForSignature({
                recordId: this.recordId,
                configDeveloperName: this.configDeveloperName,
                overridesJson: this.buildOverrides()
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
            // Before close(): the TurboSign Signatures panel on this record reloads on this message.
            publish(this.messageContext, ENVELOPE_SENT, { recordId: this.recordId, envelopeId: res.envelopeId });
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

    handleBack() {
        this.abandonPreview();
        this.focusAfterRender = false;
        this.step = 'pick';
    }
    handleCancel() { this.close(); }
    close() { this.dispatchEvent(new CloseActionScreenEvent()); }

    titleCase(s) {
        if (!s) return '';
        return s.replace(/[_-]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
    }
}
