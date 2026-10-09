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
        expect(toasts[0].message).not.toMatch(/loading it/i);
        expect(toasts[0].message).toMatch(/redeploy its records with Active set to true, or recreate it/i);
    });

    it('Date Format help says a blank format uses the sending user\'s locale', async () => {
        const el = await mount();
        const input = el.shadowRoot.querySelector('lightning-input[data-field="dateFormat"]');
        expect(input.fieldLevelHelp).not.toMatch(/signer/i);
        expect(input.fieldLevelHelp).toMatch(/sending user's locale/i);
    });
});
