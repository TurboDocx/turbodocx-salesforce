import { createElement } from 'lwc';
import TurboSignSendModal from 'c/turboSignSendModal';
import listConfigs from '@salesforce/apex/TurboSignQuickActionController.listConfigs';
import previewForSignature from '@salesforce/apex/TurboSignQuickActionController.previewForSignature';
import previewPdf from '@salesforce/apex/TurboSignQuickActionController.previewPdf';
import checkAnchors from '@salesforce/apex/TurboSignQuickActionController.checkAnchors';

jest.mock('@salesforce/client/formFactor', () => ({ default: 'Medium' }), { virtual: true });
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

// The Salesforce mobile app (phone Small, tablet Medium) has no reliable inline PDF viewer, so a render would
// only cost a deliverable.
it('tells a mobile-app user (here a tablet) the document view needs a computer, without rendering', async () => {
    previewForSignature.mockResolvedValue({ documentName: 'Lease', variables: [], recipients: [], anchors: [] });
    checkAnchors.mockResolvedValue([]);
    const el = createElement('c-turbo-sign-send-modal', { is: TurboSignSendModal });
    el.recordId = '006000000000001';
    el.objectApiName = 'Opportunity';
    document.body.appendChild(el);
    listConfigs.emit([{ label: 'Preflight Lease', value: 'Preflight_Lease' }]);
    await flush();
    el.shadowRoot.querySelector('lightning-button[data-id="review"]').click();
    await flush();
    await flush();

    el.shadowRoot.querySelector('lightning-tab[data-id="document"]').dispatchEvent(new CustomEvent('active'));
    await flush();

    expect(previewPdf).not.toHaveBeenCalled();
    expect(el.shadowRoot.querySelector('iframe[data-id="pdf"]')).toBeNull();
    expect(el.shadowRoot.querySelector('[data-id="phone-note"]').textContent)
        .toContain('Open this record on a computer to see the document before you send it.');
});
