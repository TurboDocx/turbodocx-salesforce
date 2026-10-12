import { createElement } from 'lwc';
import TurboSignConfigBuilder from 'c/turboSignConfigBuilder';
import listConfigs from '@salesforce/apex/TurboSignConfigController.listConfigs';
import getConfig from '@salesforce/apex/TurboSignConfigController.getConfig';
import getFieldOptions from '@salesforce/apex/TurboSignConfigController.getFieldOptions';
import deactivateConfig from '@salesforce/apex/TurboSignConfigController.deactivateConfig';
import getConfigDeployStatus from '@salesforce/apex/TurboSignConfigController.getConfigDeployStatus';

jest.mock('@salesforce/apex/TurboSignConfigController.listConfigs', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.getTemplateOptions', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.getObjectOptions', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.getConfig', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.getFieldOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.deactivateConfig', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/TurboSignConfigController.getConfigDeployStatus', () => ({ default: jest.fn() }), { virtual: true });

const TOAST_EVENT = 'lightning__showtoast';
// What the user reads: Salesforce fills {0}, {1}… from messageData and drops any other {…} in the message.
const shown = (toast) => toast.message.replace(/\{([^}]*)\}/g, (m, k) => {
    const data = toast.messageData || [];
    return /^\d+$/.test(k) && data[k] !== undefined ? String(data[k]) : '';
});
const flush = () => new Promise((r) => setTimeout(r, 0));

async function mount() {
    const el = createElement('c-turbo-sign-config-builder', { is: TurboSignConfigBuilder });
    document.body.appendChild(el);
    await flush();
    return el;
}

async function openDeactivateConfirmation() {
    const el = await mount();
    listConfigs.emit([{ label: 'Example Agreement', value: 'Example_Agreement' }]);
    await flush();
    el.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'Example_Agreement' } }));
    await flush();
    await flush();
    const ask = [...el.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === 'Deactivate');
    ask.click();
    await flush();
    return el;
}

describe('c-turbo-sign-config-builder', () => {
    beforeEach(() => {
        getFieldOptions.mockResolvedValue([]);
        getConfig.mockResolvedValue({});
    });
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('Deactivate confirmation says how to bring a setup back, since a deactivated one cannot be loaded', async () => {
        const el = await openDeactivateConfirmation();
        const text = el.shadowRoot.querySelector('.slds-theme_warning p').textContent;
        expect(text).not.toMatch(/loading it/i);
        expect(text).toMatch(/redeploy its records with Active set to true, or recreate it/i);
    });

    it('Deactivate success toast does not promise reactivation by loading the setup', async () => {
        const el = await openDeactivateConfirmation();
        deactivateConfig.mockResolvedValue('job1');
        getConfigDeployStatus.mockResolvedValue({ status: 'Succeeded' });
        const toasts = [];
        el.addEventListener(TOAST_EVENT, (e) => toasts.push(e.detail));
        jest.useFakeTimers();
        const confirm = [...el.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.variant === 'destructive');
        confirm.click();
        await Promise.resolve();
        await jest.advanceTimersByTimeAsync(2000);
        jest.useRealTimers();
        await flush();
        expect(toasts).toHaveLength(1);
        expect(shown(toasts[0])).not.toMatch(/loading it/i);
        expect(shown(toasts[0])).toMatch(/redeploy its records with Active set to true, or recreate it/i);
    });

    it('shows an Apex error with {braces} as written', async () => {
        getConfig.mockRejectedValue({ body: { message: 'Token {ClientName} has no source field.' } });
        const el = await mount();
        const toasts = [];
        el.addEventListener(TOAST_EVENT, (e) => toasts.push(e.detail));
        listConfigs.emit([{ label: 'Example Agreement', value: 'Example_Agreement' }]);
        await flush();
        el.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'Example_Agreement' } }));
        await flush();
        await flush();
        expect(toasts.map(shown)).toContain('Token {ClientName} has no source field.');
    });

    // Screen readers (and test tools) need each remove button to say what it removes; they were all "Remove".
    it('names every remove button after what it removes', async () => {
        const el = await mount();
        const click = (label) => [...el.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label).click();
        click('Text');
        click('Date');
        click('Text');
        click('Text');
        click('Add recipient');
        click('Add token');
        await flush();
        const [lease, dash] = el.shadowRoot.querySelectorAll('input.ts-chip-input');
        lease.value = 'Lease - ';
        lease.dispatchEvent(new CustomEvent('input'));
        dash.value = ' - ';
        dash.dispatchEvent(new CustomEvent('input'));
        const tokenInput = el.shadowRoot.querySelector('lightning-input[data-field="token"]');
        tokenInput.dispatchEvent(new CustomEvent('change', { detail: { value: '{sig}' } }));
        await flush();
        const names = [...el.shadowRoot.querySelectorAll('lightning-button-icon')]
            .map((b) => b.alternativeText)
            .filter((t) => /^Remove/.test(t));
        expect(names).toEqual([
            'Remove "Lease - " from the document name',
            'Remove the date from the document name',
            'Remove " - " from the document name',
            'Remove empty text from the document name',
            'Remove signer 1',
            'Remove signer 2',
            'Remove token {sig}',
            'Remove token 2'
        ]);
    });

    it('asks for a record without an article that fits only some objects', async () => {
        const el = await mount();
        const hints = [...el.shadowRoot.querySelectorAll('p')].map((p) => p.textContent).filter((t) => /to see the values/.test(t));
        expect(hints).toEqual(['Pick a record to see the values these mappings resolve to.']);
    });

    it('Date Format help says a blank format uses the sending user\'s locale', async () => {
        const el = await mount();
        const input = el.shadowRoot.querySelector('lightning-input[data-field="dateFormat"]');
        expect(input.fieldLevelHelp).not.toMatch(/signer/i);
        expect(input.fieldLevelHelp).toMatch(/sending user's locale/i);
    });
});
