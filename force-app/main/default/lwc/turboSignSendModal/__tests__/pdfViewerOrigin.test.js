// The Visualforce viewer accepts a PDF only from a page of this org (the exact origins its Apex controller lists),
// and only for the nonce on its own URL. Its logic lives in the page's inline script, so these tests read it from
// the .page file and run it.
const fs = require('fs');
const path = require('path');

const page = fs.readFileSync(path.join(__dirname, '../../../pages/TurboSign_PdfViewer.page'), 'utf8');
const source = page.match(/function fromThisOrg\(origin, allowed\) \{[\s\S]*?\n {8}\}/);
// eslint-disable-next-line no-new-func
const fromThisOrg = new Function(`${source[0]}; return fromThisOrg;`)();
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];

// What TurboSignPdfViewerController lists for an org whose My Domain is "acme".
const ACME = ['https://acme.lightning.force.com', 'https://acme.my.salesforce.com', 'https://acme.my.site.com'];

describe('TurboSign_PdfViewer parent origin check', () => {
    it('reads the allowed origins from the controller, never from a merge field inside the script', () => {
        expect(page).toMatch(/controller="TurboSignPdfViewerController"/);
        // Visualforce already HTML-encodes a merge field in an attribute; an explicit HTMLENCODE on top was
        // double-encoded on a live org (&amp;quot;), so JSON.parse failed and every parent was rejected.
        expect(page).toMatch(/data-allowed-origins="\{!allowedOriginsJson\}"/);
        expect(script).not.toMatch(/\{!/);
    });

    it.each(ACME)('accepts this org\'s own origin %s', (origin) => {
        expect(fromThisOrg(origin, ACME)).toBe(true);
    });

    it.each([
        // another tenant's Salesforce pages
        'https://other.lightning.force.com',
        'https://other.my.salesforce.com',
        'https://someone.my.site.com',
        'https://acme--uat.sandbox.lightning.force.com',
        // this org's hosts, but not exactly
        'http://acme.lightning.force.com',
        'https://acme.lightning.force.com:8443',
        'https://acme.lightning.force.com.evil.example',
        'https://evil.acme.lightning.force.com',
        'https://acme--c.vf.force.com',
        'not a url',
        ''
    ])('rejects %s', (origin) => {
        expect(fromThisOrg(origin, ACME)).toBe(false);
    });

    it('rejects everything when the controller lists nothing', () => {
        expect(fromThisOrg('https://acme.lightning.force.com', [])).toBe(false);
        expect(fromThisOrg('https://acme.lightning.force.com', undefined)).toBe(false);
    });
});

describe('TurboSign_PdfViewer handshake', () => {
    const PARENT = 'https://acme.lightning.force.com';
    let parent;
    let listener;
    let frame;

    // Runs the page's script against a stub window whose URL carries the given nonce.
    let StubURL;
    function load(search, { allowed = ACME, nav = { pdfViewerEnabled: true } } = {}) {
        parent = { postMessage: jest.fn() };
        document.body.setAttribute('data-allowed-origins', JSON.stringify(allowed));
        frame = document.createElement('iframe');
        frame.id = 'pdf';
        document.body.appendChild(frame);
        const win = {
            parent,
            location: { search },
            addEventListener: (type, fn) => { if (type === 'message') listener = fn; }
        };
        StubURL = class extends URL {};
        StubURL.createObjectURL = jest.fn(() => 'blob:viewer-1');
        StubURL.revokeObjectURL = jest.fn();
        // eslint-disable-next-line no-new-func
        new Function('window', 'document', 'URL', 'navigator', script)(win, document, StubURL, nav);
    }

    function pdf(nonce, origin = PARENT) {
        listener({ source: parent, origin, data: { type: 'turbosign-pdf', name: 'Lease.pdf', nonce, blob: new Blob(['%PDF']) } });
    }

    afterEach(() => { document.body.innerHTML = ''; document.body.removeAttribute('data-allowed-origins'); });

    it('says it is ready with its nonce', () => {
        load('?nonce=abc123');
        expect(parent.postMessage).toHaveBeenCalledWith({ type: 'turbosign-pdf-viewer-ready', nonce: 'abc123' }, '*');
    });

    it('shows a PDF carrying its nonce and acknowledges it to that parent origin only', () => {
        load('?nonce=abc123');
        parent.postMessage.mockClear();
        pdf('abc123');
        expect(frame.src).toBe('blob:viewer-1#navpanes=0&view=FitH');
        expect(frame.title).toBe('Lease.pdf');
        expect(parent.postMessage).toHaveBeenCalledWith({ type: 'turbosign-pdf-viewer-shown', nonce: 'abc123' }, PARENT);
    });

    it('ignores a PDF for another nonce, or any PDF when its URL has none', () => {
        load('?nonce=abc123');
        parent.postMessage.mockClear();
        pdf('other');
        pdf(undefined);
        expect(frame.getAttribute('src')).toBeNull();
        expect(parent.postMessage).not.toHaveBeenCalled();

        document.body.innerHTML = '';
        load('');
        parent.postMessage.mockClear();
        pdf(undefined);
        pdf(null);
        expect(frame.getAttribute('src')).toBeNull();
        expect(parent.postMessage).not.toHaveBeenCalled();
    });

    // A blob: URL runs on the origin that made it, so whatever the parent posts is shown only as a PDF, never as
    // HTML that would run on this org's Visualforce domain.
    it('shows the posted Blob only as a PDF, whatever type it claims', () => {
        load('?nonce=abc123');
        listener({ source: parent, origin: PARENT,
            data: { type: 'turbosign-pdf', nonce: 'abc123', blob: new Blob(['<script>alert(1)</script>'], { type: 'text/html' }) } });
        expect(StubURL.createObjectURL).toHaveBeenCalledTimes(1);
        expect(StubURL.createObjectURL.mock.calls[0][0].type).toBe('application/pdf');
    });

    it('ignores a PDF from a parent that is not this org', () => {
        load('?nonce=abc123');
        parent.postMessage.mockClear();
        pdf('abc123', 'https://evil.example.com');
        pdf('abc123', 'https://other.lightning.force.com'); // another Salesforce tenant
        expect(frame.getAttribute('src')).toBeNull();
        expect(parent.postMessage).not.toHaveBeenCalled();
    });

    // A browser set to download PDFs would leave the frame blank while the modal heard "shown".
    it('says the PDF cannot be shown when the browser has no PDF viewer', () => {
        load('?nonce=abc123', { nav: { pdfViewerEnabled: false } });
        parent.postMessage.mockClear();
        pdf('abc123');
        expect(parent.postMessage).toHaveBeenCalledTimes(1);
        expect(parent.postMessage).toHaveBeenCalledWith({ type: 'turbosign-pdf-viewer-unsupported', nonce: 'abc123' }, PARENT);
        expect(frame.getAttribute('src')).toBeNull(); // not loaded, so nothing is downloaded either
    });

    it('treats a browser that does not report pdfViewerEnabled as able to show the PDF', () => {
        load('?nonce=abc123', { nav: {} });
        parent.postMessage.mockClear();
        pdf('abc123');
        expect(parent.postMessage).toHaveBeenCalledWith({ type: 'turbosign-pdf-viewer-shown', nonce: 'abc123' }, PARENT);
    });
});
