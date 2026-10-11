import { createElement } from 'lwc';
import TurboSignSendModal from 'c/turboSignSendModal';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import previewPdf from '@salesforce/apex/TurboSignQuickActionController.previewPdf';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';
import getViewerUrl from '@salesforce/apex/TurboSignQuickActionController.getViewerUrl';

jest.mock('@salesforce/apex/TurboSignQuickActionController.listConfigs', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.getViewerUrl', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.previewForSignature', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.previewPdf', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.checkAnchors', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.sendForSignature', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('lightning/actions', () => ({ CloseActionScreenEvent: class extends CustomEvent { constructor() { super('close'); } } }), { virtual: true });

const flush = () => new Promise((r) => setTimeout(r, 0));

const VIEWER_URL = '/apex/ns__TurboSign_PdfViewer';
const VF_ORIGIN = 'https://acme--ns.vf.force.com';

async function openReview({ viewerUrl = VIEWER_URL } = {}) {
    const el = createElement('c-turbo-sign-send-modal', { is: TurboSignSendModal });
    el.recordId = '006000000000001';
    el.objectApiName = 'Opportunity';
    document.body.appendChild(el);
    listConfigs.emit([{ label: 'Preflight Lease', value: 'Preflight_Lease' }]);
    if (viewerUrl) getViewerUrl.emit(viewerUrl);
    await flush();
    el.shadowRoot.querySelector('lightning-button[data-id="review"]').click();
    await flush();
    await flush();
    return el;
}

// The per-render nonce the modal puts on the viewer's URL; the viewer echoes it in every message.
function nonceOf(frame) {
    return new URL(frame.getAttribute('src'), 'https://acme.lightning.force.com').searchParams.get('nonce');
}

// What the viewer page sends its parent once it has loaded and is listening.
function viewerReady(source, origin = VF_ORIGIN, nonce) {
    const e = new MessageEvent('message', { data: { type: 'turbosign-pdf-viewer-ready', nonce }, origin, source });
    window.dispatchEvent(e);
}

// What the viewer sends once it has put the PDF on screen.
function viewerShown(source, origin = VF_ORIGIN, nonce) {
    window.dispatchEvent(new MessageEvent('message', { data: { type: 'turbosign-pdf-viewer-shown', nonce }, origin, source }));
}

// What the viewer sends when the browser can't show a PDF inline (it would download it instead).
function viewerUnsupported(source, origin = VF_ORIGIN, nonce) {
    window.dispatchEvent(new MessageEvent('message', { data: { type: 'turbosign-pdf-viewer-unsupported', nonce }, origin, source }));
}

function openDocumentTab(el) {
    el.shadowRoot.querySelector('lightning-tab[data-id="document"]').dispatchEvent(new CustomEvent('active'));
}

function openDetailsTab(el) {
    el.shadowRoot.querySelector('lightning-tab[data-id="details"]').dispatchEvent(new CustomEvent('active'));
}

describe('c-turbo-sign-send-modal document preview', () => {
    beforeEach(() => {
        previewForSignature.mockResolvedValue({
            documentName: 'Lease - Eleanor Whitfield',
            variables: [{ placeholder: '{ResidentName}', label: 'Resident Name', value: 'Eleanor Whitfield' }],
            recipients: [{ role: 'signer_1', name: 'Eleanor Whitfield', email: 'e@example.com' }],
            anchors: []
        });
        checkAnchors.mockResolvedValue([]);
        previewPdf.mockResolvedValue({ fileName: 'Lease - Eleanor Whitfield.pdf', base64: btoa('%PDF-1.7 test') });
        URL.createObjectURL = jest.fn(() => 'blob:preview-1');
        URL.revokeObjectURL = jest.fn();
        window.open = jest.fn();
    });

    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('does not render the document until the rep opens the Document tab', async () => {
        const el = await openReview();
        expect(el.shadowRoot.querySelector('lightning-tab[data-id="details"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('lightning-tab[data-id="document"]')).not.toBeNull();
        expect(previewPdf).not.toHaveBeenCalled();
    });

    it('renders the PDF inside the modal when the Document tab opens, without a new tab', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();

        expect(previewPdf).toHaveBeenCalledTimes(1);
        expect(JSON.parse(previewPdf.mock.calls[0][0].overridesJson).variables['{ResidentName}']).toBe('Eleanor Whitfield');
        // Lightning Web Security only lets an iframe load http(s) or relative URLs, so the PDF is shown by a
        // Visualforce viewer whose URL comes from Apex (namespace included) and which receives the PDF by
        // postMessage once it says it is ready.
        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        expect(frame).not.toBeNull();
        // The viewer URL carries a per-render nonce, so only this frame's viewer gets the PDF.
        expect(frame.getAttribute('src')).toMatch(/^\/apex\/ns__TurboSign_PdfViewer\?nonce=[0-9a-f]{32}$/);
        expect(frame.title).toBe('Lease - Eleanor Whitfield.pdf');
        const post = jest.spyOn(frame.contentWindow, 'postMessage').mockImplementation(() => {});
        frame.dispatchEvent(new CustomEvent('load'));
        expect(post).not.toHaveBeenCalled(); // nothing goes out before the viewer says it is ready
        viewerReady(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
        expect(post).toHaveBeenCalledTimes(1);
        const [msg, targetOrigin] = post.mock.calls[0];
        expect(targetOrigin).toBe(VF_ORIGIN); // exactly the viewer's origin, never '*'
        expect(msg.type).toBe('turbosign-pdf');
        expect(msg.nonce).toBe(nonceOf(frame));
        expect(msg.name).toBe('Lease - Eleanor Whitfield.pdf');
        // One copy of the PDF: the same Blob backs the Open in a new tab link and goes to the viewer.
        expect(msg.blob).toBe(URL.createObjectURL.mock.calls[0][0]);
        expect(msg.blob.type).toBe('application/pdf');
        expect(msg.blob.size).toBe('%PDF-1.7 test'.length);
        expect(msg.bytes).toBeUndefined();
        expect(el.shadowRoot.querySelector('a[data-id="open-pdf"]').href).toBe('blob:preview-1');
        expect(window.open).not.toHaveBeenCalled();

        // Re-opening the tab with nothing changed reuses the rendered document.
        openDocumentTab(el);
        await flush();
        expect(previewPdf).toHaveBeenCalledTimes(1);
    });

    it('marks the preview stale after an edit and re-renders only when asked', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();

        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        await flush();

        expect(el.shadowRoot.querySelector('[data-id="stale"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull(); // old version stays visible
        expect(previewPdf).toHaveBeenCalledTimes(1);

        el.shadowRoot.querySelector('lightning-button[data-id="update-preview"]').click();
        await flush();
        await flush();

        expect(previewPdf).toHaveBeenCalledTimes(2);
        expect(JSON.parse(previewPdf.mock.calls[1][0].overridesJson).variables['{ResidentName}']).toBe('Eleanor R. Whitfield');
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).toBeNull();
    });

    it('explains a failed render and offers to try again', async () => {
        previewPdf.mockRejectedValueOnce({ body: { message: 'Required value {ApartmentName} is empty on this record.' } });
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();

        expect(el.shadowRoot.querySelector('[data-id="preview-error"]').textContent)
            .toContain('Required value {ApartmentName} is empty on this record.');
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).toBeNull();

        el.shadowRoot.querySelector('lightning-button[data-id="retry-preview"]').click();
        await flush();
        await flush();
        expect(previewPdf).toHaveBeenCalledTimes(2);
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
    });

    // Lightning's transport error ("Disconnected or Canceled") says nothing a rep can act on.
    it('replaces the platform transport error with what to do next', async () => {
        previewPdf.mockRejectedValueOnce({ body: { message: 'Disconnected or Canceled' } });
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();

        expect(el.shadowRoot.querySelector('[data-id="preview-error"]').textContent)
            .toBe("Couldn't reach Salesforce to render the document. Check your connection, then try again.");
    });

    // Keyboard users clicked a button that the spinner replaced; put them on the new document.
    it('moves focus to the document after a render the rep asked for', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        await flush();

        el.shadowRoot.querySelector('lightning-button[data-id="update-preview"]').click();
        await flush();
        await flush();
        await flush();

        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        expect(el.shadowRoot.activeElement).toBe(frame);
        // Chrome doesn't match :focus on an iframe whose document holds focus, so the ring is a class.
        expect(frame.classList.contains('doc-frame_focused')).toBe(true);
        frame.dispatchEvent(new CustomEvent('blur'));
        await flush();
        expect(frame.classList.contains('doc-frame_focused')).toBe(false);
    });

    // Review: a render takes a minute or two; an edit made meanwhile must still mark the result stale.
    it('keeps an edit made during a render marked as not in the preview', async () => {
        let finish;
        previewPdf.mockReturnValueOnce(new Promise((r) => { finish = r; }));
        const el = await openReview();
        openDocumentTab(el);
        await flush();

        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        finish({ fileName: 'Lease.pdf', base64: btoa('%PDF-1.7 test') });
        await flush();
        await flush();

        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).not.toBeNull();
    });

    it('ignores ready messages that do not come from the viewer frame', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        const post = jest.spyOn(frame.contentWindow, 'postMessage').mockImplementation(() => {});

        const nonce = nonceOf(frame);
        viewerReady(window, 'https://evil.example.com', nonce);
        viewerReady(null, 'https://evil.example.com', nonce);
        window.dispatchEvent(new MessageEvent('message', { data: { type: 'something-else', nonce }, origin: VF_ORIGIN, source: frame.contentWindow }));
        // The right frame and origin, but not this render's nonce: another viewer (or a stale one) asked.
        viewerReady(frame.contentWindow);
        viewerReady(frame.contentWindow, VF_ORIGIN, 'f'.repeat(32));
        expect(post).not.toHaveBeenCalled();
    });

    // Lightning Web Security hands the component a wrapped event.source that never equals the frame's
    // contentWindow (verified on a live org), so a ready message from a Salesforce origin is accepted too.
    // The PDF still goes only to that exact origin, which the browser enforces against the frame's real origin.
    it('accepts the ready message by Salesforce origin when Lightning wraps its source', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        const post = jest.spyOn(frame.contentWindow, 'postMessage').mockImplementation(() => {});
        const nonce = nonceOf(frame);

        viewerReady(window, VF_ORIGIN, nonce);
        expect(post).toHaveBeenCalledTimes(1);
        expect(post.mock.calls[0][1]).toBe(VF_ORIGIN);

        viewerReady(window, 'http://acme--ns.vf.force.com', nonce); // not https
        viewerReady(window, 'https://force.com.evil.example', nonce);
        // Only the Visualforce family serves the viewer: other Salesforce hosts (Experience Cloud sites, other
        // orgs' pages, plain force.com) can't hand the modal a viewer.
        viewerReady(window, 'https://someone.my.site.com', nonce);
        viewerReady(window, 'https://acme.my.salesforce.com', nonce);
        viewerReady(window, 'https://acme.lightning.force.com', nonce);
        viewerReady(window, 'https://evil.force.com', nonce);
        viewerReady(window, 'https://vf.force.com.evil.example', nonce);
        expect(post).toHaveBeenCalledTimes(1);

        viewerReady(window, 'https://acme--ns.sandbox.vf.force.com', nonce); // sandbox Visualforce host
        expect(post).toHaveBeenCalledTimes(2);
    });

    it('stops listening for the viewer once the modal is gone', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        const win = frame.contentWindow;
        const post = jest.spyOn(win, 'postMessage').mockImplementation(() => {});
        const nonce = nonceOf(frame);
        document.body.removeChild(el);
        viewerReady(win, VF_ORIGIN, nonce);
        expect(post).not.toHaveBeenCalled();
    });

    // Namespace-safe: the viewer URL comes from Page.TurboSign_PdfViewer.getUrl(). Each render spends a deliverable,
    // so none is spent until that URL is known: opening Document early waits for it, then renders.
    it('waits for the viewer URL before rendering the document', async () => {
        const el = await openReview({ viewerUrl: null });
        openDocumentTab(el);
        await flush();
        await flush();
        expect(previewPdf).not.toHaveBeenCalled();
        expect(el.shadowRoot.querySelector('[data-id="viewer-loading"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).toBeNull();

        getViewerUrl.emit(VIEWER_URL);
        await flush();
        await flush();
        expect(previewPdf).toHaveBeenCalledTimes(1);
        expect(el.shadowRoot.querySelector('[data-id="viewer-loading"]')).toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]').getAttribute('src').startsWith(`${VIEWER_URL}?nonce=`)).toBe(true);
    });

    it('spends no render when the viewer URL fails while Document waits for it', async () => {
        const el = await openReview({ viewerUrl: null });
        openDocumentTab(el);
        await flush();
        getViewerUrl.error({ message: 'No access to TurboSign_PdfViewer' });
        await flush();
        await flush();
        expect(previewPdf).not.toHaveBeenCalled();
        expect(el.shadowRoot.querySelector('[data-id="viewer-error"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('[data-id="viewer-loading"]')).toBeNull();
    });

    it('does not render once the viewer URL arrives after the rep went back', async () => {
        const el = await openReview({ viewerUrl: null });
        openDocumentTab(el);
        await flush();
        Array.from(el.shadowRoot.querySelectorAll('lightning-button')).find((b) => b.label === 'Back').click();
        await flush();
        getViewerUrl.emit(VIEWER_URL);
        await flush();
        await flush();
        expect(previewPdf).not.toHaveBeenCalled();
    });

    // Review: a render that finishes after Back belongs to a setup the rep has left.
    it('drops a render that finishes after the rep went back', async () => {
        let finish;
        previewPdf.mockReturnValueOnce(new Promise((r) => { finish = r; }));
        const el = await openReview();
        openDocumentTab(el);
        await flush();

        Array.from(el.shadowRoot.querySelectorAll('lightning-button')).find((b) => b.label === 'Back').click();
        finish({ fileName: 'Lease.pdf', base64: btoa('%PDF-1.7 test') });
        await flush();
        await flush();

        expect(URL.createObjectURL).not.toHaveBeenCalled();
    });
    // Review: lightning-tab keeps the Document tab's content in the DOM after its first visit, so a render
    // finishing while the rep is on Details must not pull focus into the hidden frame.
    it('does not move focus into the Document tab once the rep has gone back to Details', async () => {
        let finish;
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        await flush();

        previewPdf.mockReturnValueOnce(new Promise((r) => { finish = r; }));
        el.shadowRoot.querySelector('lightning-button[data-id="update-preview"]').click();
        await flush();
        openDetailsTab(el);
        finish({ fileName: 'Lease.pdf', base64: btoa('%PDF-1.7 test') });
        await flush();
        await flush();
        await flush();

        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        expect(frame).not.toBeNull();
        expect(el.shadowRoot.activeElement).not.toBe(frame);

        // Coming back later doesn't jump focus either: the pending focus was dropped.
        openDocumentTab(el);
        await flush();
        expect(el.shadowRoot.activeElement).not.toBe(frame);
    });

    // Review: without the viewer page there is nothing to show the PDF in, so say so and don't render.
    it('explains a viewer that could not load, without spending a render', async () => {
        const el = await openReview({ viewerUrl: null });
        getViewerUrl.error({ message: 'No access to TurboSign_PdfViewer' });
        await flush();
        openDocumentTab(el);
        await flush();
        await flush();

        const note = el.shadowRoot.querySelector('[data-id="viewer-error"]');
        expect(note).not.toBeNull();
        expect(note.textContent).toBe("The document viewer couldn't load, so the preview isn't available. You can still send.");
        expect(previewPdf).not.toHaveBeenCalled();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).toBeNull();
    });

    // Review: the preview budget is 90s of generation plus 30s for the PDF, so the copy says "a minute or two".
    it('sets expectations that match the render budget', async () => {
        previewPdf.mockReturnValueOnce(new Promise(() => {}));
        const el = await openReview();
        openDocumentTab(el);
        await flush();

        const status = el.shadowRoot.querySelector('[data-id="rendering"]');
        expect(status.textContent).toContain('This can take a minute or two.');
    });

    // Review 3: each render gets its own nonce, so a viewer from an earlier render can't take the new PDF.
    it('binds every render to a fresh nonce', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const first = nonceOf(el.shadowRoot.querySelector('iframe[data-id="pdf"]'));

        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        await flush();
        el.shadowRoot.querySelector('lightning-button[data-id="update-preview"]').click();
        await flush();
        await flush();

        const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
        const second = nonceOf(frame);
        expect(second).not.toBe(first);
        const post = jest.spyOn(frame.contentWindow, 'postMessage').mockImplementation(() => {});
        viewerReady(frame.contentWindow, VF_ORIGIN, first);
        expect(post).not.toHaveBeenCalled();
        viewerReady(frame.contentWindow, VF_ORIGIN, second);
        expect(post).toHaveBeenCalledTimes(1);
    });

    // Review 3: signer names never reach the PDF; only whether an optional signer has an email does (an
    // optional signer without one is dropped, and its anchors with it).
    it('marks the preview stale only for signer edits that change the document', async () => {
        previewForSignature.mockResolvedValue({
            documentName: 'Lease',
            variables: [{ placeholder: '{ResidentName}', label: 'Resident Name', value: 'Eleanor Whitfield' }],
            recipients: [
                { role: 'signer_1', name: 'Eleanor Whitfield', email: 'e@example.com', required: true },
                { role: 'signer_2', name: 'Guarantor', email: 'g@example.com', required: false }
            ],
            anchors: []
        });
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const input = (key, field) => el.shadowRoot.querySelector(`lightning-input[data-key="${key}"][data-field="${field}"]`);
        const edit = async (key, field, value) => {
            const i = input(key, field);
            i.value = value;
            i.dispatchEvent(new CustomEvent('change'));
            await flush();
        };
        const stale = () => el.shadowRoot.querySelector('[data-id="stale"]') !== null;

        await edit('0:signer_1', 'name', 'Eleanor R. Whitfield');
        await edit('1:signer_2', 'name', 'Someone Else');
        expect(stale()).toBe(false);
        await edit('0:signer_1', 'email', ''); // a required signer keeps its anchors either way
        await edit('1:signer_2', 'email', 'other@example.com'); // still has an email
        expect(stale()).toBe(false);

        // Apex falls back to the record's email when the modal sends a blank one, so clearing a prefilled email
        // doesn't drop the signer and doesn't change the document.
        await edit('1:signer_2', 'email', '');
        expect(stale()).toBe(false);
    });

    it('marks the preview stale when an optional signer without an email gets one', async () => {
        previewForSignature.mockResolvedValue({
            documentName: 'Lease',
            variables: [],
            recipients: [
                { role: 'signer_1', name: 'Eleanor Whitfield', email: 'e@example.com', required: true },
                { role: 'signer_2', name: 'Guarantor', email: null, required: false }
            ],
            anchors: []
        });
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const i = el.shadowRoot.querySelector('lightning-input[data-key="1:signer_2"][data-field="email"]');
        i.value = 'g@example.com';
        i.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).not.toBeNull();

        i.value = '  ';
        i.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).toBeNull();
    });

    // Lightning can report a cleared input's value as null; the stale check must not throw on it.
    it('treats a null signer email or name from the input as empty', async () => {
        previewForSignature.mockResolvedValue({
            documentName: 'Lease',
            variables: [],
            recipients: [
                { role: 'signer_1', name: 'Eleanor Whitfield', email: 'e@example.com', required: true },
                { role: 'signer_2', name: 'Guarantor', email: null, required: false }
            ],
            anchors: []
        });
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        for (const field of ['email', 'name']) {
            const i = el.shadowRoot.querySelector(`lightning-input[data-key="1:signer_2"][data-field="${field}"]`);
            i.value = null;
            i.dispatchEvent(new CustomEvent('change'));
            await flush();
        }
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
    });

    // A failed Update preview must not take away the last good document.
    it('keeps the previous preview when an update fails, with the error and Try again above it', async () => {
        const el = await openReview();
        openDocumentTab(el);
        await flush();
        await flush();
        const input = el.shadowRoot.querySelector('lightning-input[data-placeholder="{ResidentName}"]');
        input.value = 'Eleanor R. Whitfield';
        input.dispatchEvent(new CustomEvent('change'));
        await flush();

        previewPdf.mockRejectedValueOnce({ body: { message: 'Could not render the preview: timed out' } });
        const focus = jest.spyOn(HTMLElement.prototype, 'focus');
        el.shadowRoot.querySelector('lightning-button[data-id="update-preview"]').click();
        await flush();
        await flush();
        await flush();

        expect(el.shadowRoot.querySelector('[data-id="preview-error"]').textContent)
            .toBe('Could not render the preview: timed out');
        const retry = el.shadowRoot.querySelector('lightning-button[data-id="retry-preview"]');
        expect(retry).not.toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
        expect(el.shadowRoot.querySelector('a[data-id="open-pdf"]').href).toBe('blob:preview-1');
        expect(el.shadowRoot.querySelector('[data-id="stale"]')).toBeNull(); // one Try again, not two buttons
        // The rep's button was replaced by the spinner: focus lands on the error's Try again, not the old document.
        // (The lightning-button stub can't hold focus in jsdom, so the call is checked.)
        expect(focus.mock.contexts).toContain(retry);
        expect(focus.mock.contexts.some((c) => c.tagName === 'IFRAME')).toBe(false);
        focus.mockRestore();

        retry.click();
        await flush();
        await flush();
        expect(previewPdf).toHaveBeenCalledTimes(3);
        expect(el.shadowRoot.querySelector('[data-id="preview-error"]')).toBeNull();
        expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
    });

    describe('viewer handshake timeout', () => {
        const SHOWN_TIMEOUT_MS = 15000;
        const tick = () => jest.advanceTimersByTimeAsync(0);

        async function renderWithFakeTimers() {
            const el = await openReview();
            jest.useFakeTimers();
            openDocumentTab(el);
            await tick();
            await tick();
            const frame = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
            const post = jest.spyOn(frame.contentWindow, 'postMessage').mockImplementation(() => {});
            return { el, frame, post };
        }

        function expectTimeoutError(el) {
            const note = el.shadowRoot.querySelector('[data-id="viewer-timeout"]');
            expect(note).not.toBeNull();
            expect(note.textContent).toBe("The document couldn't be shown here. Use Open in a new tab to see it.");
            expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).toBeNull();
            expect(el.shadowRoot.querySelector('a[data-id="open-pdf"]').href).toBe('blob:preview-1');
        }

        it('explains a viewer that never says it is ready, keeping Open in a new tab', async () => {
            const { el } = await renderWithFakeTimers();
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS - 1);
            expect(el.shadowRoot.querySelector('[data-id="viewer-timeout"]')).toBeNull();
            await jest.advanceTimersByTimeAsync(1);
            expectTimeoutError(el);
        });

        it('explains a viewer that took the PDF but never showed it', async () => {
            const { el, frame, post } = await renderWithFakeTimers();
            await jest.advanceTimersByTimeAsync(10000);
            viewerReady(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            expect(post).toHaveBeenCalledTimes(1);
            // The wait restarts when the PDF goes out.
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS - 1);
            expect(el.shadowRoot.querySelector('[data-id="viewer-timeout"]')).toBeNull();
            await jest.advanceTimersByTimeAsync(1);
            expectTimeoutError(el);
        });

        it('ignores acknowledgments from another render or origin', async () => {
            const { el, frame } = await renderWithFakeTimers();
            const nonce = nonceOf(frame);
            viewerReady(frame.contentWindow, VF_ORIGIN, nonce);
            viewerShown(frame.contentWindow, VF_ORIGIN, 'f'.repeat(32)); // not this render's: ignored
            viewerShown(window, 'https://evil.example.com', nonce); // not the frame, not a Visualforce origin: ignored
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS);
            expectTimeoutError(el);
        });

        it('shows no error when the viewer acknowledges in time', async () => {
            const { el, frame } = await renderWithFakeTimers();
            viewerReady(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            viewerShown(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS * 2);
            expect(el.shadowRoot.querySelector('[data-id="viewer-timeout"]')).toBeNull();
            expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
        });

        it('explains at once a browser that cannot show the PDF here', async () => {
            const { el, frame } = await renderWithFakeTimers();
            viewerReady(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            viewerUnsupported(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            await tick();
            expectTimeoutError(el);
            expect(jest.getTimerCount()).toBe(0); // no longer waiting
        });

        // Try again can't succeed in a browser set to download PDFs, so only the note and the link are offered.
        it('offers no Try again when the browser cannot show the PDF here', async () => {
            const { el, frame } = await renderWithFakeTimers();
            viewerReady(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            viewerUnsupported(frame.contentWindow, VF_ORIGIN, nonceOf(frame));
            await tick();
            expectTimeoutError(el);
            expect(el.shadowRoot.querySelector('lightning-button[data-id="retry-viewer"]')).toBeNull();
        });

        // The wait is for the viewer to show the PDF, so it starts only once the viewer's frame is on the page.
        it('starts the viewer timer only once the frame exists', async () => {
            const el = await openReview();
            const seen = [];
            const realSetTimeout = window.setTimeout;
            const spy = jest.spyOn(window, 'setTimeout').mockImplementation((fn, ms, ...rest) => {
                if (ms === SHOWN_TIMEOUT_MS) seen.push(el.shadowRoot.querySelector('iframe[data-id="pdf"]') !== null);
                return realSetTimeout(fn, ms, ...rest);
            });
            openDocumentTab(el);
            await flush();
            await flush();
            await flush();
            spy.mockRestore();
            expect(seen.length).toBeGreaterThan(0);
            expect(seen.every(Boolean)).toBe(true);
        });

        it('ignores an unsupported message from another render', async () => {
            const { el, frame } = await renderWithFakeTimers();
            viewerUnsupported(frame.contentWindow, VF_ORIGIN, 'f'.repeat(32));
            await tick();
            expect(el.shadowRoot.querySelector('[data-id="viewer-timeout"]')).toBeNull();
            expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).not.toBeNull();
        });

        it('offers Try again, which shows the same PDF in a fresh viewer without rendering again', async () => {
            const { el, frame } = await renderWithFakeTimers();
            const firstNonce = nonceOf(frame);
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS);
            expectTimeoutError(el);

            el.shadowRoot.querySelector('lightning-button[data-id="retry-viewer"]').click();
            await tick();
            await tick();

            expect(previewPdf).toHaveBeenCalledTimes(1);
            expect(el.shadowRoot.querySelector('[data-id="viewer-timeout"]')).toBeNull();
            const again = el.shadowRoot.querySelector('iframe[data-id="pdf"]');
            expect(again).not.toBeNull();
            expect(nonceOf(again)).not.toBe(firstNonce);
            expect(el.shadowRoot.activeElement).toBe(again); // the clicked button is gone; focus follows the result
            const post = jest.spyOn(again.contentWindow, 'postMessage').mockImplementation(() => {});
            viewerReady(again.contentWindow, VF_ORIGIN, firstNonce); // the old frame's nonce no longer counts
            expect(post).not.toHaveBeenCalled();
            viewerReady(again.contentWindow, VF_ORIGIN, nonceOf(again));
            expect(post).toHaveBeenCalledTimes(1);
            expect(post.mock.calls[0][0].blob).toBe(URL.createObjectURL.mock.calls[0][0]);

            // The fresh viewer gets the full wait too.
            await jest.advanceTimersByTimeAsync(SHOWN_TIMEOUT_MS);
            expectTimeoutError(el);
        });

        it('stops waiting once the rep goes back', async () => {
            const { el } = await renderWithFakeTimers();
            expect(jest.getTimerCount()).toBeGreaterThan(0);
            Array.from(el.shadowRoot.querySelectorAll('lightning-button')).find((b) => b.label === 'Back').click();
            await tick();
            expect(jest.getTimerCount()).toBe(0);
        });
    });
});
