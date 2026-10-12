import { createElement } from 'lwc';
import TurboSignSendModal from 'c/turboSignSendModal';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';
import getViewerUrl from '@salesforce/apex/TurboSignQuickActionController.getViewerUrl';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';
import sendForSignature from '@salesforce/apex/TurboSignQuickActionController.sendForSignature';

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

// What the rep reads: Salesforce fills {0}, {1}… from messageData and drops any other {…} in the message.
function shown(toast) {
    return toast.message.replace(/\{([^}]*)\}/g, (match, key) => {
        const data = toast.messageData || [];
        return /^\d+$/.test(key) && data[key] !== undefined ? String(data[key]) : '';
    });
}

async function sendFromReview() {
    const el = createElement('c-turbo-sign-send-modal', { is: TurboSignSendModal });
    el.recordId = '006000000000001';
    el.objectApiName = 'Opportunity';
    document.body.appendChild(el);
    listConfigs.emit([{ label: 'Service Agreement', value: 'Service_Agreement' }]);
    getViewerUrl.emit('/apex/TurboSign_PdfViewer');
    await flush();
    el.shadowRoot.querySelector('lightning-button[data-id="review"]').click();
    await flush();
    await flush();
    const toasts = [];
    el.addEventListener('lightning__showtoast', (e) => toasts.push(e.detail));
    [...el.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === 'Send').click();
    await flush();
    await flush();
    return toasts;
}

// Apex messages name the token in braces, e.g. "Required value {ClientName} is empty". The rep must see it.
describe('c-turbo-sign-send-modal send toasts keep {token} text', () => {
    beforeEach(() => {
        previewForSignature.mockResolvedValue({
            documentName: 'Service Agreement - {Acme}',
            variables: [{ placeholder: '{ClientName}', label: 'Client Name', value: '' }],
            recipients: [{ role: 'signer_1', name: 'Pat Doe', email: 'pat@example.com' }],
            anchors: []
        });
        checkAnchors.mockResolvedValue([]);
    });

    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
    });

    it('names the empty required token when the send is refused', async () => {
        sendForSignature.mockResolvedValue({ ok: false, message: 'Required value {ClientName} is empty on this record.' });
        const toasts = await sendFromReview();
        expect(toasts).toHaveLength(1);
        expect(toasts[0].title).toBe('Send failed');
        expect(shown(toasts[0])).toBe('Required value {ClientName} is empty on this record.');
    });

    it('keeps braces in a "Check before sending again" warning', async () => {
        sendForSignature.mockResolvedValue({ ok: false, maybeSent: true, message: 'TurboDocx may have sent {Lease}. Check first.' });
        const toasts = await sendFromReview();
        expect(toasts[0].title).toBe('Check before sending again');
        expect(toasts[0].mode).toBe('sticky');
        expect(shown(toasts[0])).toBe('TurboDocx may have sent {Lease}. Check first.');
    });

    it('keeps braces in a thrown Apex error', async () => {
        sendForSignature.mockRejectedValue({ body: { message: 'Signer {signer_2} has no email.' } });
        const toasts = await sendFromReview();
        expect(toasts[0].title).toBe('Send failed');
        expect(shown(toasts[0])).toBe('Signer {signer_2} has no email.');
    });

    it('keeps braces in the document name on success', async () => {
        sendForSignature.mockResolvedValue({ ok: true, envelopeId: 'a01000000000001' });
        const toasts = await sendFromReview();
        expect(toasts[0].title).toBe('Sent for signature');
        expect(shown(toasts[0])).toMatch(/^Service Agreement - \{Acme\} is on its way/);
    });
});
