import { createElement } from 'lwc';
import TurboSignSendModal from 'c/turboSignSendModal';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';
import getViewerUrl from '@salesforce/apex/TurboSignQuickActionController.getViewerUrl';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';
import sendForSignature from '@salesforce/apex/TurboSignQuickActionController.sendForSignature';
import { publish } from 'lightning/messageService';
import ENVELOPE_SENT from '@salesforce/messageChannel/TurboSign_Envelope_Sent__c';

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

const RECORD_ID = '006000000000001';
const flush = () => new Promise((r) => setTimeout(r, 0));

async function openReview() {
    const el = createElement('c-turbo-sign-send-modal', { is: TurboSignSendModal });
    el.recordId = RECORD_ID;
    el.objectApiName = 'Opportunity';
    document.body.appendChild(el);
    listConfigs.emit([{ label: 'Preflight Lease', value: 'Preflight_Lease' }]);
    getViewerUrl.emit('/apex/TurboSign_PdfViewer');
    await flush();
    el.shadowRoot.querySelector('lightning-button[data-id="review"]').click();
    await flush();
    await flush();
    return el;
}

async function clickSend(el) {
    const send = Array.from(el.shadowRoot.querySelectorAll('lightning-button')).find((b) => b.label === 'Send');
    send.click();
    await flush();
    await flush();
}

describe('c-turbo-sign-send-modal tells the record page about a send', () => {
    beforeEach(() => {
        previewForSignature.mockResolvedValue({
            documentName: 'Service Agreement',
            variables: [],
            recipients: [{ role: 'signer_1', name: 'Eleanor Whitfield', email: 'e@example.com' }],
            anchors: []
        });
        checkAnchors.mockResolvedValue([]);
    });

    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
    });

    it('publishes the new envelope on the envelope-sent channel once TurboDocx accepts the send', async () => {
        sendForSignature.mockResolvedValue({ ok: true, envelopeId: 'a0X000000000001' });
        const el = await openReview();
        await clickSend(el);
        expect(publish).toHaveBeenCalledTimes(1);
        const [, channel, message] = publish.mock.calls[0];
        expect(channel).toBe(ENVELOPE_SENT);
        expect(message).toEqual({ recordId: RECORD_ID, envelopeId: 'a0X000000000001' });
    });

    it('publishes nothing when the send fails', async () => {
        sendForSignature.mockResolvedValue({ ok: false, maybeSent: false, message: 'Bad request' });
        const el = await openReview();
        await clickSend(el);
        expect(publish).not.toHaveBeenCalled();
    });
});
