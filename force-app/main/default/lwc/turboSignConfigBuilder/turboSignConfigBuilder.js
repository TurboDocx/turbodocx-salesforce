import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import { refreshApex } from '@salesforce/apex';
import getTemplateOptions from '@salesforce/apex/TurboSignConfigController.getTemplateOptions';
import getTemplatePlaceholders from '@salesforce/apex/TurboSignConfigController.getTemplatePlaceholders';
import validateConfig from '@salesforce/apex/TurboSignConfigController.validateConfig';
import bestFieldMatch from '@salesforce/apex/TurboSignConfigController.bestFieldMatch';
import previewPayload from '@salesforce/apex/TurboSignConfigController.previewPayload';
import previewDocumentName from '@salesforce/apex/TurboSignConfigController.previewDocumentName';
import getObjectOptions from '@salesforce/apex/TurboSignConfigController.getObjectOptions';
import checkTemplateAnchors from '@salesforce/apex/TurboSignConfigController.checkTemplateAnchors';
import getPicklistValues from '@salesforce/apex/TurboSignConfigController.getPicklistValues';
import cloneConfig from '@salesforce/apex/TurboSignConfigController.cloneConfig';
import deriveApiName from '@salesforce/apex/TurboSignConfigController.deriveApiName';
import deactivateConfig from '@salesforce/apex/TurboSignConfigController.deactivateConfig';
import saveConfig from '@salesforce/apex/TurboSignConfigController.saveConfig';
import getFieldOptions from '@salesforce/apex/TurboSignConfigController.getFieldOptions';
import getConfig from '@salesforce/apex/TurboSignConfigController.getConfig';
import getConfigDeployStatus from '@salesforce/apex/TurboSignConfigController.getConfigDeployStatus';
import listConfigs from '@salesforce/apex/TurboSignConfigController.listConfigs';

const FIELD_TYPES = ['signature', 'initial', 'date', 'text', 'checkbox', 'full_name', 'first_name', 'last_name', 'title', 'company', 'email'];
// A token is either filled with record data ('data') or placed as a signing field (one of FIELD_TYPES).
const KIND_DATA = 'data';
const prettyKind = (t) => t.charAt(0).toUpperCase() + t.slice(1).replace(/_/g, ' ');
const KIND_OPTIONS = [{ label: 'Data value', value: KIND_DATA }, ...FIELD_TYPES.map((t) => ({ label: prettyKind(t), value: t }))];
// TurboDocx rejects optional signature/initial fields, so those kinds are always required.
const ALWAYS_REQUIRED = new Set(['signature', 'initial']);
const newToken = (seq, over) => ({ id: seq, token: '', kind: KIND_DATA, sourceField: '', defaultValue: '', role: '', required: true, ...over });

export default class TurboSignConfigBuilder extends LightningElement {
    @track developerName = '';
    @track label = '';
    @track sourceObject = 'Opportunity';
    @track templateId = '';
    @track dateFormat = '';
    @track completionField = '';
    @track completionValue = '';
    @track completionValueOptions = [];
    @track templateOptions = [];
    @track objectOptions = [];
    @track validationIssues = [];
    templatesError;
    loadingTemplates = true;
    saving = false;

    // field pickers (cascade: relationship -> field)
    @track fieldsByRel = { '': [] };
    @track relationshipOptions = [{ label: '— this object —', value: '' }];
    fieldsLoading = false;
    fieldsError;

    // edit existing
    @track existingConfigs = [];
    editingName = '';
    // Snapshot of the last saved/loaded state; anything different means unsaved edits.
    _baseline = '';
    // Snapshot the field VALUES (not the synthetic row ids, which churn on add/reorder). Rows with any
    // field filled count — so a half-typed recipient/variable is "dirty" and the guard won't silently drop it —
    // while a wholly empty row does not, so just adding a blank row doesn't trip the guard.
    rawSnapshot() {
        const nonEmpty = (row, keys) => keys.some((k) => row[k] !== undefined && row[k] !== null && row[k] !== '');
        return JSON.stringify({
            scalars: {
                developerName: this.developerName, label: this.label, sourceObject: this.sourceObject,
                templateId: this.templateId, documentName: this.docNamePattern(), dateFormat: this.dateFormat,
                completionField: this.completionField, completionValue: this.completionValue
            },
            tokens: this.tokens.filter((t) => nonEmpty(t, ['token', 'sourceField', 'defaultValue', 'role']))
                .map((t) => ({ token: t.token, kind: t.kind, sourceField: t.sourceField, defaultValue: t.defaultValue, role: t.role, required: t.required })),
            recipients: this.recipients.filter((r) => nonEmpty(r, ['role', 'nameField', 'emailField', 'staticName', 'staticEmail']))
                .map((r) => ({ nameField: r.nameField, emailField: r.emailField, staticName: r.staticName, staticEmail: r.staticEmail, fixed: !!r.fixed, required: r.required !== false })) // array order encodes signing order
        });
    }
    captureBaseline() { this._baseline = this.rawSnapshot(); }
    get isDirty() { return this._baseline !== this.rawSnapshot(); }
    // Returns true if it's safe to blow away the current form (clean, or the user confirmed discard).
    async confirmDiscardIfDirty() {
        if (!this.isDirty) return true;
        return LightningConfirm.open({
            label: 'Discard unsaved changes?',
            message: 'This configuration has unsaved changes. Leaving now will discard them.',
            theme: 'warning'
        });
    }
    _wiredConfigs;

    // One unified list: every template token, each classified as a data value or a signing field.
    @track tokens = [{ id: 1, token: '', kind: KIND_DATA, sourceField: '', defaultValue: '', role: '', required: true }];
    @track recipients = [{ id: 1, role: 'signer_1', nameField: '', emailField: '', order: 1, required: true }];
    seq = 100;

    kindOptions = KIND_OPTIONS;

    connectedCallback() {
        this.loadFields();
        this.captureBaseline();
    }

    @wire(getTemplateOptions)
    wiredTemplates({ data, error }) {
        this.loadingTemplates = false;
        if (data) this.templateOptions = data;
        else if (error) this.templatesError = (error.body && error.body.message) || 'Could not load templates from TurboDocx.';
    }

    @wire(getObjectOptions)
    wiredObjects({ data }) {
        if (data) this.objectOptions = data;
    }

    handleSourceObject(e) {
        this.sourceObject = e.detail.value;
        this.loadFields();
    }

    // When the completion field changes, constrain the value to its picklist (if it has one).
    handleCompletionField(e) {
        this.completionField = e.detail.value;
        this.completionValue = '';
        this.loadCompletionPicklist();
    }

    async loadCompletionPicklist() {
        this.completionValueOptions = [];
        const field = (this.completionField || '').trim();
        const obj = (this.sourceObject || '').trim();
        if (!field || !obj) return;
        try {
            const vals = (await getPicklistValues({ objectApiName: obj, fieldApiName: field })) || [];
            // Keep a loaded value that isn't in the active set, so editing an existing config doesn't lose it.
            const opts = this.completionValue && !vals.some((o) => o.value === this.completionValue)
                ? [...vals, { label: this.completionValue, value: this.completionValue }]
                : vals;
            this.completionValueOptions = opts;
        } catch (err) {
            this.completionValueOptions = [];
        }
    }

    // Picklist field -> constrained dropdown; anything else -> free-text entry.
    get completionValueIsPicklist() {
        return this.completionValueOptions.length > 0;
    }

    // A signing token picks WHICH recipient signs there. Recipients have no visible role column; we show
    // each by its order + name source ("Signer 1 · Account.Name") and store its stable id, so reordering
    // signers never repoints a signature field.
    get roleOptions() {
        return this.recipients
            .filter((r) => (r.role || '').trim())
            .map((r, i) => {
                // Fixed signers show their typed name; record signers show the field the name comes from.
                const who = r.fixed ? (r.staticName || '').trim() : this.cleanPath(r.nameField);
                const suffix = who ? ` · ${who}` : '';
                return { label: `Signer ${i + 1}${suffix}`, value: r.role };
            });
    }

    // Signing tokens (kind != data). Anchors are their token text.
    get signingTokens() {
        return this.tokens.filter((t) => t.kind !== KIND_DATA);
    }

    // Every token decorated for the template: split source path + field options for data tokens, and a
    // recipient-role flag for signing tokens. isData/isSigning drive which controls the row shows.
    get tokenRows() {
        const roles = new Set(this.recipients.map((r) => (r.role || '').trim()).filter(Boolean));
        return this.tokens.map((t) => {
            const isData = t.kind === KIND_DATA;
            const s = this.splitPath(t.sourceField);
            const roleMissing = !!(!isData && t.role && !roles.has(t.role));
            const hasValue = (t.sourceField && !t.sourceField.endsWith('.')) || !!t.defaultValue;
            // One glanceable status per row (replaces per-row hint text, which used to break row alignment).
            let icon = 'utility:dash', variant = '', title = '';
            if (isData) {
                if (hasValue) { icon = 'utility:success'; variant = 'success'; title = 'Mapped to a field'; }
                else { title = 'No field or default yet'; }
            } else if (!t.role) { icon = 'utility:warning'; variant = 'warning'; title = 'Assign a signer'; }
            else if (roleMissing) { icon = 'utility:error'; variant = 'error'; title = 'No recipient has this role'; }
            else { icon = 'utility:success'; variant = 'success'; title = 'Ready to sign'; }
            return {
                ...t,
                isData,
                isSigning: !isData,
                canBeOptional: !ALWAYS_REQUIRED.has(t.kind),
                srcRel: s.rel, srcField: s.field, srcFieldOptions: this.fieldOptionsForRel(s.rel),
                roleMissing,
                statusIcon: icon, statusVariant: variant, statusTitle: title
            };
        });
    }

    // ---- Check anchors against the actual template (before saving) ----
    @track anchorCheck = { checking: false, ran: false, results: [], error: '' };
    get canCheckAnchors() {
        return !!this.templateId && this.signingTokens.some((t) => (t.token || '').trim()) && !this.anchorCheck.checking;
    }
    get canCheckAnchorsDisabled() {
        return !this.canCheckAnchors;
    }
    async checkAnchors() {
        const anchors = [...new Set(this.signingTokens.map((t) => (t.token || '').trim()).filter(Boolean))];
        if (!this.templateId || !anchors.length) return;
        this.anchorCheck = { checking: true, ran: false, results: [], error: '' };
        try {
            const rep = await checkTemplateAnchors({ templateId: this.templateId, anchors });
            const results = (rep || []).map((r) => ({
                anchor: r.anchor,
                found: r.found === true,
                icon: r.found === true ? 'utility:success' : 'utility:warning',
                variant: r.found === true ? 'success' : 'warning',
                label: r.found === true ? 'found in the document' : 'not found — fix the template or the token'
            }));
            this.anchorCheck = { checking: false, ran: true, results, error: '' };
        } catch (e) {
            this.anchorCheck = { checking: false, ran: true, results: [], error: (e.body && e.body.message) || 'Could not check anchors.' };
        }
    }

    @wire(listConfigs, { sourceObject: '' })
    wiredConfigs(result) {
        this._wiredConfigs = result;
        if (result.data) this.existingConfigs = result.data;
    }

    get noTemplates() {
        return !this.loadingTemplates && !this.templatesError && this.templateOptions.length === 0;
    }
    get configOptions() {
        return this.existingConfigs.map((c) => ({ label: c.label, value: c.value }));
    }
    get hasExisting() {
        return this.existingConfigs.length > 0;
    }
    // status advancement targets a field ON the record itself: top-level only, and only writable fields
    get completionFieldOptions() {
        const top = (this.fieldsByRel[''] || []).filter((o) => o.updateable);
        const known = new Set(top.map((o) => o.value));
        const extra = this.completionField && !known.has(this.completionField) ? [{ label: this.completionField, value: this.completionField }] : [];
        return [{ label: '-- no status change --', value: '' }, ...top, ...extra];
    }

    // ---- cascade field pickers: [relationship][field], each dropdown bounded to one object's fields ----
    splitPath(val) {
        if (!val) return { rel: '', field: '' };
        const i = val.indexOf('.');
        return i === -1 ? { rel: '', field: val } : { rel: val.slice(0, i), field: val.slice(i + 1) };
    }
    fieldOptionsForRel(rel) {
        return [{ label: '-- select field --', value: '' }, ...(this.fieldsByRel[rel] || [])];
    }
    get recipientRows() {
        // isFixed -> name/email are literal values (a signer not on the record: a facility rep, a witness).
        const last = this.recipients.length - 1;
        return this.recipients.map((r, i) => ({
            ...r, position: i + 1, isFixed: !!r.fixed, required: r.required !== false,
            isFirst: i === 0, isLast: i === last,
            upLabel: `Move signer ${i + 1} up`, downLabel: `Move signer ${i + 1} down`
        }));
    }

    // Keyboard-operable reorder (drag-and-drop alone fails WCAG 2.1.1 / 2.5.7).
    moveRecipient(e) {
        const id = Number(e.currentTarget.dataset.id);
        const step = e.currentTarget.dataset.dir === 'up' ? -1 : 1;
        const list = [...this.recipients];
        const from = list.findIndex((r) => r.id === id);
        const to = from + step;
        if (from === -1 || to < 0 || to >= list.length) return;
        [list[from], list[to]] = [list[to], list[from]];
        this.recipients = list;
    }

    // ---- drag to reorder (recipients: signing order; doc-name: segment order) ----
    _draggingId = null;
    _dragCollection = 'recipients';
    onDragStart(e) {
        this._draggingId = Number(e.target.dataset.id);
        this._dragCollection = e.target.dataset.collection || 'recipients';
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', String(this._draggingId)); // some browsers need data set to start a drag
    }
    onDragOver(e) {
        e.preventDefault(); // allow drop
        e.dataTransfer.dropEffect = 'move';
    }
    onDrop(e) {
        e.preventDefault();
        const coll = e.currentTarget.dataset.collection || this._dragCollection || 'recipients';
        const targetId = Number(e.currentTarget.dataset.id);
        if (this._draggingId == null || this._draggingId === targetId) return;
        const list = [...this[coll]];
        const from = list.findIndex((r) => r.id === this._draggingId);
        const to = list.findIndex((r) => r.id === targetId);
        if (from === -1 || to === -1) return;
        const [moved] = list.splice(from, 1);
        list.splice(to, 0, moved);
        this[coll] = list;
        this._draggingId = null;
    }
    onDragEnd() { this._draggingId = null; } // a cancelled drag must not leave a stale source id

    // ---- Document name builder: compose the name from reorderable segments ----
    @track docNameSegments = [];
    get docFieldMenuItems() { return this.allFieldPaths; } // reuse the record's field paths
    get separatorItems() {
        return [{ label: 'Underscore ( _ )', value: '_' }, { label: 'Hyphen ( - )', value: '-' },
            { label: 'Space', value: ' ' }, { label: 'Period ( . )', value: '.' }];
    }
    get docNameRows() {
        return this.docNameSegments.map((s) => ({
            ...s,
            isText: s.type === 'text',
            isField: s.type === 'field',
            isDate: s.type === 'date',
            fieldLabel: s.type === 'field' ? this.labelForPath(s.value) : ''
        }));
    }
    get hasDocDate() { return this.docNameSegments.some((s) => s.type === 'date'); }
    get hasDocSegments() { return this.docNameSegments.length > 0; }
    labelForPath(path) {
        // Compact, unambiguous chip label: the field path itself (e.g. "Account.Name").
        return path;
    }
    // Segments -> stored pattern ("Lease - {Account.Name} - {date}"); the backend resolves it per record.
    docNamePattern() {
        return this.docNameSegments.map((s) => {
            if (s.type === 'field') return `{${s.value}}`;
            if (s.type === 'date') return '{date}';
            return s.value || '';
        }).join('');
    }
    // A no-record hint of the shape, like the FE builder: [Field] for fields, (today's date) for date.
    get docNameHint() {
        if (!this.docNameSegments.length) return '';
        return this.docNameSegments.map((s) => {
            if (s.type === 'field') return `[${this.labelForPath(s.value)}]`;
            if (s.type === 'date') return "(today's date)";
            return s.value || '';
        }).join('');
    }
    addDocText() { this.docNameSegments = [...this.docNameSegments, { id: ++this.seq, type: 'text', value: '' }]; }
    addDocDate() { if (!this.hasDocDate) this.docNameSegments = [...this.docNameSegments, { id: ++this.seq, type: 'date', value: '' }]; }
    insertDocField(e) {
        this.docNameSegments = [...this.docNameSegments, { id: ++this.seq, type: 'field', value: e.detail.value }];
    }
    insertDocSeparator(e) {
        this.docNameSegments = [...this.docNameSegments, { id: ++this.seq, type: 'text', value: e.detail.value }];
    }
    editDocText(e) {
        const id = Number(e.target.dataset.id);
        const value = e.target.value;
        this.docNameSegments = this.docNameSegments.map((s) => (s.id === id ? { ...s, value } : s));
    }
    removeDocSegment(e) {
        const id = Number(e.currentTarget.dataset.id);
        this.docNameSegments = this.docNameSegments.filter((s) => s.id !== id);
    }
    clearDocName() { this.docNameSegments = []; }
    // Stored pattern -> segments, for loading a saved config back into the builder.
    parseDocName(pattern) {
        if (!pattern) return [];
        const segs = [];
        const re = /\{([^}]+)\}/g;
        let last = 0;
        let m = re.exec(pattern);
        while (m !== null) {
            if (m.index > last) segs.push({ id: ++this.seq, type: 'text', value: pattern.slice(last, m.index) });
            const tok = m[1].trim();
            segs.push(tok === 'date' ? { id: ++this.seq, type: 'date', value: '' } : { id: ++this.seq, type: 'field', value: tok });
            last = re.lastIndex;
            m = re.exec(pattern);
        }
        if (last < pattern.length) segs.push({ id: ++this.seq, type: 'text', value: pattern.slice(last) });
        return segs;
    }
    editPath(collection, e) {
        const id = Number(e.target.dataset.id);
        const pathField = e.target.dataset.field; // sourceField | nameField | emailField
        const part = e.target.dataset.part; // rel | field
        const newVal = e.detail ? e.detail.value : e.target.value;
        this[collection] = this[collection].map((r) => {
            if (r.id !== id) return r;
            const cur = this.splitPath(r[pathField]);
            let rel = cur.rel;
            let field = cur.field;
            if (part === 'rel') { rel = newVal; field = ''; } // relationship changed -> reset field
            else { field = newVal; }
            const combined = rel ? (field ? `${rel}.${field}` : `${rel}.`) : field;
            return { ...r, [pathField]: combined };
        });
    }
    editTokenPath(e) { this.editPath('tokens', e); }
    editRecipientPath(e) {
        this.editPath('recipients', e);
        // When a recipient's Name/Email relationship is chosen, auto-pick the obvious field on it.
        if (e.target.dataset.part === 'rel' && e.detail && e.detail.value) {
            this.autoPickRecipientField(Number(e.target.dataset.id), e.target.dataset.field, e.detail.value);
        }
    }

    async autoPickRecipientField(id, pathField, rel) {
        const opts = this.fieldsByRel[rel] || [];
        if (!opts.length) return;
        const token = pathField === 'emailField' ? 'Email' : 'Full Name';
        try {
            const val = await bestFieldMatch({ token, options: opts.map((o) => ({ label: o.label, value: o.value })) });
            if (val) this.recipients = this.recipients.map((r) => (r.id === id ? { ...r, [pathField]: `${rel}.${val}` } : r));
        } catch (e) { /* suggestion is best-effort */ }
    }

    // Flat list of every mappable field path (base + one level of relationships), for placeholder matching.
    get allFieldPaths() {
        const out = [];
        Object.keys(this.fieldsByRel).forEach((rel) => {
            (this.fieldsByRel[rel] || []).forEach((f) => {
                out.push({ label: rel ? `${rel} ${f.label}` : f.label, value: rel ? `${rel}.${f.value}` : f.value });
            });
        });
        return out;
    }

    async suggestFields() {
        const paths = this.allFieldPaths;
        if (!paths.length) return;
        const rows = await Promise.all(this.tokens.map(async (t) => {
            if (t.kind !== KIND_DATA || !t.token || t.sourceField) return t;
            try {
                const match = await bestFieldMatch({ token: t.token, options: paths });
                return match ? { ...t, sourceField: match } : t;
            } catch (e) { return t; }
        }));
        this.tokens = rows;
        this.toast('Fields suggested', 'Review the suggested fields and adjust any that are off.', 'info');
    }
    cleanPath(p) { return p && !p.endsWith('.') ? p : undefined; } // drop a relationship-without-field selection

    async loadFields() {
        const obj = (this.sourceObject || '').trim();
        if (!obj) { this.fieldsByRel = { '': [] }; this.relationshipOptions = [{ label: '— this object —', value: '' }]; return; }
        this.fieldsLoading = true;
        this.fieldsError = undefined;
        try {
            const base = await getFieldOptions({ objectApiName: obj });
            const byRel = { '': base.map((f) => ({ label: `${f.label} (${f.value})`, value: f.value, updateable: f.updateable })) };
            const refs = base.filter((f) => f.isReference && f.relationshipName && f.referenceTo);
            const related = await Promise.all(
                refs.map((r) => getFieldOptions({ objectApiName: r.referenceTo }).then((rf) => ({ r, rf })).catch(() => null))
            );
            for (const item of related) {
                if (!item) continue;
                byRel[item.r.relationshipName] = item.rf.map((rf) => ({ label: `${rf.label} (${rf.value})`, value: rf.value, updateable: rf.updateable }));
            }
            this.fieldsByRel = byRel;
            this.relationshipOptions = [
                { label: `— fields on this ${obj} —`, value: '' },
                ...refs.map((r) => ({ label: r.relationshipName, value: r.relationshipName }))
            ];
        } catch (e) {
            this.fieldsError = (e.body && e.body.message) || `Could not read fields on ${obj}.`;
            this.fieldsByRel = { '': [] };
            this.relationshipOptions = [{ label: '— this object —', value: '' }];
        } finally {
            this.fieldsLoading = false;
        }
    }

    // ---- header fields ----
    get hasValidationIssues() { return this.validationIssues.length > 0; }

    handleField(e) {
        // Works for both lightning-input and lightning-combobox (completion value): combobox change
        // payloads arrive on e.detail.value, and e.target.value can be stale/undefined for them.
        this[e.target.dataset.field] = e.detail ? e.detail.value : e.target.value;
        if (e.target.dataset.field === 'sourceObject') this.loadFields();
    }

    // Auto-fill the Config API Name from the Label until the admin edits the name themselves.
    devNameEdited = false;
    handleLabel(e) {
        this.label = e.target.value;
        if (this.devNameEdited || this.editingName) return;
        deriveApiName({ label: this.label })
            .then((api) => { if (!this.devNameEdited) this.developerName = api || ''; })
            .catch(() => {});
    }
    handleDeveloperName(e) {
        this.developerName = e.target.value;
        this.devNameEdited = true;
    }
    handleTemplate(e) {
        this.templateId = e.detail.value;
        const t = this.templateOptions.find((o) => o.value === e.detail.value);
        if (t && !this.docNameSegments.length) this.docNameSegments = [{ id: ++this.seq, type: 'text', value: t.label }];
        this.prefillPlaceholders();
    }

    // The template already declares its {placeholders} (TurboDocx parsed them on upload). Pull them so the
    // admin only maps the field side instead of retyping every token. Additive + non-blocking: keeps any
    // rows already mapped, drops a lone empty starter row, and stays quiet if the fetch fails.
    async prefillPlaceholders() {
        if (!this.templateId) return;
        try {
            const placeholders = await getTemplatePlaceholders({ templateId: this.templateId });
            if (!placeholders || !placeholders.length) return;
            const known = new Set(this.tokens.map((t) => (t.token || '').trim()).filter(Boolean));
            // Each detected token starts as a data value; the admin flips the ones that are signing fields.
            const rows = this.tokens.filter((t) => t.token || t.sourceField || t.defaultValue || t.role);
            placeholders.forEach((ph) => {
                if (!known.has(ph)) { rows.push(newToken(++this.seq, { token: ph })); known.add(ph); }
            });
            this.tokens = rows.length ? rows : [newToken(++this.seq)];
        } catch (e) {
            // non-blocking: if TurboDocx can't be reached, the admin can still add rows by hand
        }
    }

    // ---- edit existing ----
    async handleEditConfig(e) {
        const dev = e.detail.value;
        const prev = this.editingName;
        if (!(await this.confirmDiscardIfDirty())) {
            this.editingName = prev; // user backed out — keep the current config selected
            return;
        }
        this.editingName = dev;
        if (!dev) return;
        try {
            const c = await getConfig({ developerName: dev });
            if (!c || !c.developerName) return;
            this.developerName = c.developerName;
            this.devNameEdited = true;
            this.label = c.label || '';
            this.sourceObject = c.sourceObject || 'Opportunity';
            this.templateId = c.templateId || '';
            this.docNameSegments = this.parseDocName(c.documentName || '');
            this.dateFormat = c.dateFormat || '';
            this.completionField = c.completionField || '';
            this.completionValue = c.completionValue || '';
            this.loadCompletionPicklist();
            // Fold the saved variable mappings and signature fields back into one token list.
            const tokens = [];
            // Saved roles are signer_<n>; start new ids past every saved one so Add recipient can't collide.
            (c.recipients || []).forEach((r) => {
                const n = Number(String(r.role || '').replace(/^signer_/, ''));
                if (Number.isFinite(n) && n >= this.seq) this.seq = n + 1;
            });
            (c.variables || []).forEach((v) => tokens.push(newToken(++this.seq, { token: v.placeholder, kind: KIND_DATA, sourceField: v.sourceField || '', defaultValue: v.defaultValue || '', required: v.required === true })));
            (c.fields || []).forEach((f) => tokens.push(newToken(++this.seq, { token: f.anchor, kind: f.type || 'signature', role: f.role || '', required: ALWAYS_REQUIRED.has(f.type || 'signature') || !!f.required })));
            this.tokens = tokens.length ? tokens : [newToken(++this.seq)];
            this.recipients = (c.recipients || []).map((r) => ({ id: ++this.seq, role: r.role, nameField: r.nameField || '', emailField: r.emailField || '', staticName: r.staticName || '', staticEmail: r.staticEmail || '', fixed: !!(r.staticName || r.staticEmail), order: r.order || 1, required: r.required !== false }));
            if (!this.recipients.length) { const rid = ++this.seq; this.recipients = [{ id: rid, role: `signer_${rid}`, nameField: '', emailField: '', order: 1, required: true }]; }
            this.loadFields();
            this.previewRows = [];
            this.testRecordId = '';
            this.captureBaseline();
        } catch (err) {
            this.toast('Could not load config', (err.body && err.body.message) || 'Unknown error', 'error');
        }
    }
    // ---- duplicate an existing config to a new name ----
    @track duplicating = false;
    @track cloneName = '';
    get canDuplicate() { return !!this.editingName; }
    startDuplicate() {
        if (!this.editingName) return;
        this.cloneName = this.editingName + '_Copy';
        this.duplicating = true;
    }
    cancelDuplicate() { this.duplicating = false; this.cloneName = ''; }
    handleCloneName(e) { this.cloneName = (e.target.value || '').replace(/[^A-Za-z0-9_]/g, '_'); }
    async confirmDuplicate() {
        const source = this.editingName;
        const newName = (this.cloneName || '').replace(/[^A-Za-z0-9_]/g, '_');
        if (!source || !newName) return;
        this.saving = true;
        try {
            const jobId = await cloneConfig({ sourceDeveloperName: source, newDeveloperName: newName, newLabel: (this.label || source) + ' Copy' });
            const outcome = await this.pollDeployStatus(jobId);
            if (outcome === 'Failed') {
                this.toast('Copy failed', this.deployError || 'The copy failed to deploy.', 'error');
            } else {
                this.toast('Copy created', `"${newName}" was created from "${source}".`, 'success');
                if (this._wiredConfigs) refreshApex(this._wiredConfigs);
                this.duplicating = false;
                this.cloneName = '';
                await this.handleEditConfig({ detail: { value: newName } });
            }
        } catch (err) {
            this.toast('Copy failed', (err.body && err.body.message) || 'Unknown error', 'error');
        } finally {
            this.saving = false;
        }
    }

    // ---- deactivate (soft delete: reversible, removes from picker + builder list) ----
    @track confirmingDeactivate = false;
    askDeactivate() { if (this.editingName) this.confirmingDeactivate = true; }
    cancelDeactivate() { this.confirmingDeactivate = false; }
    async confirmDeactivate() {
        const name = this.editingName;
        if (!name) return;
        this.saving = true;
        try {
            const jobId = await deactivateConfig({ developerName: name });
            const outcome = await this.pollDeployStatus(jobId);
            if (outcome === 'Failed') {
                this.toast('Deactivate failed', this.deployError || 'Could not deactivate.', 'error');
            } else {
                this.toast('Configuration deactivated', `"${name}" was removed from the document picker. To bring it back, redeploy its records with Active set to true, or recreate it.`, 'success');
                if (this._wiredConfigs) refreshApex(this._wiredConfigs);
                this.confirmingDeactivate = false;
                this.resetForm();
            }
        } catch (err) {
            this.toast('Deactivate failed', (err.body && err.body.message) || 'Unknown error', 'error');
        } finally {
            this.saving = false;
        }
    }

    async handleNew() {
        if (!(await this.confirmDiscardIfDirty())) return;
        this.resetForm();
    }
    resetForm() {
        this.editingName = '';
        this.validationIssues = [];
        this.confirmingDeactivate = false;
        this.devNameEdited = false;
        this.developerName = '';
        this.label = '';
        this.templateId = '';
        this.docNameSegments = [];
        this.dateFormat = '';
        this.completionField = '';
        this.completionValue = '';
        this.tokens = [newToken(++this.seq)];
        const rid = ++this.seq;
        this.recipients = [{ id: rid, role: `signer_${rid}`, nameField: '', emailField: '', order: 1, required: true }];
        this.previewRows = [];
        this.testRecordId = '';
        this.captureBaseline();
    }

    // ---- dynamic row editing ----
    edit(collection, e) {
        const id = Number(e.target.dataset.id);
        const field = e.target.dataset.field;
        const value = e.target.type === 'checkbox' ? e.target.checked : (e.detail ? e.detail.value : e.target.value);
        this[collection] = this[collection].map((r) => (r.id === id ? { ...r, [field]: value } : r));
    }
    editToken(e) { this.edit('tokens', e); }
    editRecipient(e) { this.edit('recipients', e); }

    addToken() { this.tokens = [...this.tokens, newToken(++this.seq)]; }
    addRecipient() {
        const rid = ++this.seq; // role is a stable, hidden per-recipient id (survives reorder/delete); the UI shows order + name
        this.recipients = [...this.recipients, { id: rid, role: `signer_${rid}`, nameField: '', emailField: '', order: this.recipients.length + 1, required: true }];
    }

    removeRow(e) {
        const collection = e.target.dataset.collection;
        const id = Number(e.target.dataset.id);
        this[collection] = this[collection].filter((r) => r.id !== id);
    }

    get canSave() {
        return this.developerName && this.templateId && this.recipients.some((r) => r.role) && !this.saving;
    }
    // template can't negate; bind the button's disabled to this
    get saveDisabled() {
        return !this.canSave;
    }

    // literal example tokens — `{sig}` in a template attribute/text would be parsed as a data binding
    get exampleSig() { return '{sig}'; }
    get exampleDate() { return '{date}'; }
    get exampleClientName() { return '{ClientName}'; }

    buildPayload() {
        return {
            developerName: this.developerName.replace(/[^A-Za-z0-9_]/g, '_'),
            label: this.label || this.developerName,
            sourceObject: this.sourceObject,
            templateId: this.templateId,
            documentName: this.docNamePattern() || undefined,
            dateFormat: this.dateFormat || undefined,
            completionField: this.completionField || undefined,
            completionValue: this.completionField ? this.completionValue : undefined,
            // Split the one token list back into the two shapes the backend expects.
            variables: this.tokens.filter((t) => t.kind === KIND_DATA && t.token)
                .map((t) => ({ placeholder: t.token, sourceField: this.cleanPath(t.sourceField), defaultValue: t.defaultValue || undefined, required: t.required !== false })),
            recipients: this.recipients.filter((r) => r.role).map((r, i) => ({
                role: r.role, order: i + 1, required: r.required !== false,
                ...(r.fixed
                    ? { staticName: r.staticName || undefined, staticEmail: r.staticEmail || undefined }
                    : { nameField: this.cleanPath(r.nameField), emailField: this.cleanPath(r.emailField) })
            })),
            fields: this.tokens.filter((t) => t.kind !== KIND_DATA && t.token)
                .map((t) => ({ anchor: t.token, type: t.kind, role: t.role, required: ALWAYS_REQUIRED.has(t.kind) || !!t.required }))
        };
    }

    // ---- Test with a record: resolve the in-progress mappings against a real record ----
    @track testRecordId = '';
    @track previewRows = [];
    @track previewDocName = '';
    @track previewing = false;
    handleTestRecord(e) { this.testRecordId = (e.detail && e.detail.recordId) || ''; this.previewRows = []; this.previewDocName = ''; }
    get canPreview() { return !!this.testRecordId && !this.previewing; }
    get previewDisabled() { return !this.canPreview; }
    async runPreview() {
        if (!this.testRecordId) return;
        this.previewing = true;
        try {
            const [rows, docName] = await Promise.all([
                previewPayload({ recordId: this.testRecordId, payloadJson: JSON.stringify(this.buildPayload()) }),
                previewDocumentName({ recordId: this.testRecordId, template: this.docNamePattern(), dateFormat: this.dateFormat })
            ]);
            this.previewRows = (rows || []).map((r) => ({ ...r, key: r.placeholder }));
            this.previewDocName = docName || '';
        } catch (e) {
            this.toast('Preview failed', (e.body && e.body.message) || 'Could not resolve values for that record.', 'error');
        } finally {
            this.previewing = false;
        }
    }

    async handleSave() {
        const payload = this.buildPayload();
        // Pre-save validation: surface every problem at once instead of a failed async deploy.
        this.validationIssues = [];
        try {
            const tph = this.templateId ? await getTemplatePlaceholders({ templateId: this.templateId }) : [];
            const issues = await validateConfig({ payloadJson: JSON.stringify(payload), templatePlaceholders: tph || [] });
            if (issues && issues.length) {
                this.validationIssues = issues;
                this.toast('Fix a few things first', `${issues.length} issue${issues.length > 1 ? 's' : ''} to resolve before saving.`, 'warning');
                return;
            }
        } catch (e) {
            // validation is best-effort; if it can't run, fall through and let the save proceed
        }
        // Overwrite guard: saving a brand-new config whose API name collides with an existing one would silently replace it.
        if (!this.editingName) {
            const collision = this.existingConfigs.find((c) => (c.value || '').toLowerCase() === payload.developerName.toLowerCase());
            if (collision) {
                const proceed = await LightningConfirm.open({
                    label: 'Overwrite existing configuration?',
                    message: `A configuration named "${collision.label}" (${collision.value}) already exists. Saving will overwrite it.`,
                    theme: 'warning'
                });
                if (!proceed) return;
            }
        }
        this.saving = true;
        try {
            const jobId = await saveConfig({ payloadJson: JSON.stringify(payload) });
            const outcome = await this.pollDeployStatus(jobId);
            if (outcome === 'Failed') {
                this.toast('Save failed', this.deployError || 'The configuration failed to deploy.', 'error');
            } else if (outcome === 'Succeeded') {
                this.toast('Configuration saved', `"${payload.label}" is live.`, 'success');
                this.editingName = payload.developerName;
                this.captureBaseline();
                if (this._wiredConfigs) refreshApex(this._wiredConfigs);
            } else {
                this.toast('Still deploying', `"${payload.label}" is taking longer than usual. Refresh in a moment to confirm it saved.`, 'warning');
                if (this._wiredConfigs) refreshApex(this._wiredConfigs);
            }
        } catch (err) {
            this.toast('Save failed', (err.body && err.body.message) || 'Unknown error', 'error');
        } finally {
            this.saving = false;
        }
    }

    // The CMDT deploy is async — poll the recorded outcome so we report a real success/failure.
    async pollDeployStatus(jobId) {
        this.deployError = undefined;
        for (let i = 0; i < 8; i++) {
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, 1500));
            // eslint-disable-next-line no-await-in-loop
            const s = await getConfigDeployStatus({ jobId });
            if (s.status === 'Succeeded') return 'Succeeded';
            if (s.status === 'Failed') { this.deployError = s.error; return 'Failed'; }
        }
        return 'Pending';
    }

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}
