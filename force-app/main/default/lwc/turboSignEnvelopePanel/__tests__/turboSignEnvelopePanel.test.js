import { createElement } from 'lwc';
import TurboSignEnvelopePanel from 'c/turboSignEnvelopePanel';
import getEnvelopes from '@salesforce/apex/TurboSignQuickActionController.getEnvelopes';
import syncEnvelope from '@salesforce/apex/TurboSignRecipientSync.syncEnvelope';
import { refreshApex } from '@salesforce/apex';
import { subscribe, unsubscribe, APPLICATION_SCOPE } from 'lightning/messageService';
import ENVELOPE_SENT from '@salesforce/messageChannel/TurboSign_Envelope_Sent__c';

jest.mock('@salesforce/apex/TurboSignQuickActionController.getEnvelopes', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.remind', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignQuickActionController.voidEnvelope', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignRecipientSync.syncEnvelope', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn(() => Promise.resolve()) }), { virtual: true });

const RECORD_ID = '006000000000001';
const flush = () => new Promise((r) => setTimeout(r, 0));

function envelope(id, status) {
    return {
        Id: id, Status__c: status, Document_Name__c: `Doc ${id}`, Sent_On__c: '2026-10-01T10:00:00.000Z',
        Recipient_Count__c: 1, Signed_Count__c: status === 'completed' ? 1 : 0
    };
}

// A review link: prepared in TurboDocx for the rep to check, never sent to signers (no Sent_On__c).
function reviewOnly(id, status) {
    return { ...envelope(id, status), Sent_On__c: undefined };
}

async function mount() {
    const el = createElement('c-turbo-sign-envelope-panel', { is: TurboSignEnvelopePanel });
    el.recordId = RECORD_ID;
    document.body.appendChild(el);
    await flush();
    return el;
}

function actionButtons(el, id) {
    return Array.from(el.shadowRoot.querySelectorAll(`lightning-button[data-id="${id}"]`)).map((b) => b.label);
}

describe('c-turbo-sign-envelope-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
    });

    describe('Remind and Void', () => {
        it('are offered on a document still out for signature', async () => {
            const el = await mount();
            getEnvelopes.emit([envelope('a01', 'sent')]);
            await flush();
            expect(actionButtons(el, 'a01')).toEqual(['Remind', 'Void']);
        });

        it.each(['completed', 'voided', 'expired'])('are hidden on a %s document', async (status) => {
            const el = await mount();
            getEnvelopes.emit([envelope('a02', status)]);
            await flush();
            expect(actionButtons(el, 'a02')).toEqual([]);
            // The document itself still shows.
            expect(el.shadowRoot.textContent).toContain('Doc a02');
        });

        it.each(['draft', 'review_ready'])('are hidden on a review-only %s document', async (status) => {
            const el = await mount();
            getEnvelopes.emit([envelope('a05', status)]);
            await flush();
            expect(actionButtons(el, 'a05')).toEqual([]);
        });

        it('are offered on a document under review by a signer', async () => {
            const el = await mount();
            getEnvelopes.emit([envelope('a06', 'under_review')]);
            await flush();
            expect(actionButtons(el, 'a06')).toEqual(['Remind', 'Void']);
        });
    });

    describe('review-only envelopes', () => {
        afterEach(() => syncEnvelope.mockReset());

        it.each(['under_review', 'sent'])('get no Remind or Void when %s but never sent to signers', async (status) => {
            const el = await mount();
            getEnvelopes.emit([reviewOnly('a40', status)]);
            await flush();
            expect(actionButtons(el, 'a40')).toEqual([]);
            expect(el.shadowRoot.textContent).toContain('Doc a40');
        });

        it('are not auto-synced on load', async () => {
            await mount();
            getEnvelopes.emit([reviewOnly('a41', 'under_review')]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
        });

        it('get Remind and Void once a sync records them as sent', async () => {
            const el = await mount();
            getEnvelopes.emit([reviewOnly('a42', 'under_review')]);
            await flush();
            getEnvelopes.emit([envelope('a42', 'under_review')]);
            await flush();
            expect(actionButtons(el, 'a42')).toEqual(['Remind', 'Void']);
        });
    });

    describe('refresh after a send', () => {
        it('subscribes to the envelope-sent channel at application scope', async () => {
            await mount();
            expect(subscribe).toHaveBeenCalledTimes(1);
            const [, channel, , options] = subscribe.mock.calls[0];
            expect(channel).toBe(ENVELOPE_SENT);
            expect(options).toEqual({ scope: APPLICATION_SCOPE });
        });

        it('reloads its envelopes when a send for this record is published', async () => {
            await mount();
            getEnvelopes.emit([]);
            await flush();
            const handler = subscribe.mock.calls[0][2];
            handler({ recordId: RECORD_ID, envelopeId: 'a03' });
            await flush();
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('ignores a send for a different record', async () => {
            await mount();
            const handler = subscribe.mock.calls[0][2];
            handler({ recordId: '006000000000999', envelopeId: 'a04' });
            await flush();
            expect(refreshApex).not.toHaveBeenCalled();
        });

        it('unsubscribes when removed from the page', async () => {
            subscribe.mockReturnValueOnce({ id: 'sub-1' });
            const el = await mount();
            document.body.removeChild(el);
            expect(unsubscribe).toHaveBeenCalledWith({ id: 'sub-1' });
        });
    });

    describe('status sync on load', () => {
        afterEach(() => syncEnvelope.mockReset());

        it('shows the cached envelopes first, then syncs each unfinished one and reloads', async () => {
            let release;
            syncEnvelope.mockImplementation(() => new Promise((r) => { release = r; }));
            const el = await mount();
            getEnvelopes.emit([envelope('a10', 'sent'), envelope('a11', 'completed')]);
            await flush();
            // Cached data renders while the sync is still in flight.
            expect(el.shadowRoot.textContent).toContain('Doc a10');
            expect(el.shadowRoot.querySelector('lightning-spinner')).toBeNull();
            expect(syncEnvelope).toHaveBeenCalledTimes(1);
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a10' });
            expect(refreshApex).not.toHaveBeenCalled();
            release(1);
            await flush();
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('syncs at most once per load, even when the reloaded data is still unfinished', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            getEnvelopes.emit([envelope('a12', 'sent')]);
            await flush();
            getEnvelopes.emit([envelope('a12', 'sent')]);
            await flush();
            expect(syncEnvelope).toHaveBeenCalledTimes(1);
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('does not sync when every envelope is finished', async () => {
            await mount();
            getEnvelopes.emit([envelope('a13', 'completed'), envelope('a14', 'voided'), envelope('a15', 'expired')]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
            expect(refreshApex).not.toHaveBeenCalled();
        });

        it('does not auto-sync review-only documents the sync can never move (draft, review_ready)', async () => {
            await mount();
            getEnvelopes.emit([envelope('a17', 'draft'), envelope('a18', 'review_ready')]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
        });

        it('does not sync a fresh send on a record whose envelopes were all finished at load', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            getEnvelopes.emit([envelope('a19', 'completed')]);
            await flush();
            // A new send publishes, the panel reloads, and the just-sent envelope arrives.
            getEnvelopes.emit([envelope('a20', 'sent'), envelope('a19', 'completed')]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
        });

        it('skips an envelope synced within the last 5 minutes', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            const recent = { ...envelope('a21', 'sent'), Last_Synced__c: new Date(Date.now() - 60 * 1000).toISOString() };
            const stale = { ...envelope('a22', 'sent'), Last_Synced__c: new Date(Date.now() - 10 * 60 * 1000).toISOString() };
            getEnvelopes.emit([recent, stale]);
            await flush();
            expect(syncEnvelope).toHaveBeenCalledTimes(1);
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a22' });
        });

        it('does not sync or reload when every unfinished envelope was synced recently', async () => {
            await mount();
            const recent = { ...envelope('a23', 'under_review'), Last_Synced__c: new Date().toISOString() };
            getEnvelopes.emit([recent]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
            expect(refreshApex).not.toHaveBeenCalled();
        });

        it('disables Refresh while the load-time sync is in flight, so the two cannot overlap', async () => {
            let release;
            syncEnvelope.mockImplementation(() => new Promise((r) => { release = r; }));
            const el = await mount();
            getEnvelopes.emit([envelope('a24', 'sent')]);
            await flush();
            const refresh = el.shadowRoot.querySelector('lightning-button-icon[title="Refresh"]');
            expect(refresh.disabled).toBe(true);
            refresh.click();
            await flush();
            expect(syncEnvelope).toHaveBeenCalledTimes(1);
            release(1);
            await flush();
            await flush();
            expect(refresh.disabled).toBe(false);
        });

        it('syncs an envelope whose Last_Synced__c is in the future (clock skew), not treating it as recent', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            const skewed = { ...envelope('a25', 'sent'), Last_Synced__c: new Date(Date.now() + 60 * 60 * 1000).toISOString() };
            getEnvelopes.emit([skewed]);
            await flush();
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a25' });
        });

        it('lets the server throttle the load-time sync (no force flag)', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            getEnvelopes.emit([envelope('a26', 'sent')]);
            await flush();
            expect(syncEnvelope.mock.calls[0][0].force).toBeUndefined();
        });

        it('forces the sync from the Refresh button, past the server throttle', async () => {
            syncEnvelope.mockResolvedValue(1);
            const el = await mount();
            const recent = { ...envelope('a27', 'sent'), Last_Synced__c: new Date().toISOString() };
            getEnvelopes.emit([recent]);
            await flush();
            el.shadowRoot.querySelector('lightning-button-icon[title="Refresh"]').click();
            await flush();
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a27', force: true });
        });

        it('Refresh syncs a voided envelope so its recipient statuses get corrected', async () => {
            // A void from Salesforce marks the envelope terminal without touching recipient rows;
            // only a sync brings those rows in line, so Refresh must still sync terminal envelopes.
            syncEnvelope.mockResolvedValue(1);
            const el = await mount();
            getEnvelopes.emit([envelope('a30', 'voided'), envelope('a31', 'completed'),
                envelope('a32', 'expired'), envelope('a33', 'sent')]);
            await flush();
            await flush();
            syncEnvelope.mockClear();
            refreshApex.mockClear();
            el.shadowRoot.querySelector('lightning-button-icon[title="Refresh"]').click();
            await flush();
            await flush();
            expect(syncEnvelope).toHaveBeenCalledTimes(4);
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a30', force: true });
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a31', force: true });
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a32', force: true });
            expect(syncEnvelope).toHaveBeenCalledWith({ envelopeId: 'a33', force: true });
            expect(refreshApex).toHaveBeenCalledTimes(1);
        });

        it('load does not auto-sync a voided envelope; only Refresh does', async () => {
            syncEnvelope.mockResolvedValue(1);
            await mount();
            getEnvelopes.emit([envelope('a34', 'voided')]);
            await flush();
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
        });

        it('does not sync when there are no envelopes', async () => {
            await mount();
            getEnvelopes.emit([]);
            await flush();
            expect(syncEnvelope).not.toHaveBeenCalled();
        });

        it('still reloads when a sync fails, and keeps the cached data', async () => {
            syncEnvelope.mockRejectedValue({ body: { message: 'Unauthorized' } });
            const el = await mount();
            getEnvelopes.emit([envelope('a16', 'sent')]);
            await flush();
            await flush();
            expect(refreshApex).toHaveBeenCalledTimes(1);
            expect(el.shadowRoot.textContent).toContain('Doc a16');
        });
    });
});
