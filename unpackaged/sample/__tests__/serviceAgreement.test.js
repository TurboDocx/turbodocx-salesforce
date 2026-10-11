// Guards the sample Service Agreement's signing block: the tokens must stay invisible on the signed PDF,
// and the Signature line must leave room for the signature box so it never covers the Client or Date lines.
const { execFileSync } = require('child_process');
const path = require('path');

const DOCX = process.env.SAMPLE_DOCX || path.join(__dirname, '..', 'Service Agreement.docx');

const paragraphs = () =>
    execFileSync('unzip', ['-p', DOCX, 'word/document.xml'], { encoding: 'utf8' }).split('<w:p>');
const paragraphWith = (text) => paragraphs().find((p) => p.includes(text));

describe('sample Service Agreement signing block', () => {
    it.each(['{sig}', '{date}'])('renders the %s token in white so no raw token shows', (token) => {
        const run = paragraphWith(token).split('<w:r>').find((r) => r.includes(token));
        expect(run).toContain('<w:color w:val="FFFFFF"/>');
    });

    it('spaces the Signature line away from the Client line above and the Date line below', () => {
        const spacing = paragraphWith('{sig}').match(/<w:spacing w:before="(\d+)" w:after="(\d+)"\/>/);
        expect(spacing).not.toBeNull();
        expect(Number(spacing[1])).toBeGreaterThanOrEqual(480);
        expect(Number(spacing[2])).toBeGreaterThanOrEqual(1440);
    });

    it('puts Signature and Date on separate lines', () => {
        expect(paragraphWith('{sig}')).not.toContain('{date}');
    });
});
