/**
 * Composes a TurboSignService.SendRequest from CMDT config + a source record (spec §7, §9.1).
 * This is the "customer two is configuration, not a code fork" engine: variable mappings,
 * recipient rules, and field-anchor rules all live in Custom Metadata and are resolved at runtime.
 *
 * preview() returns the resolved-but-not-sent view for the pre-send review UI (editable prefilled
 * values + anchors); build(recordId, config, overrides) lets the rep's edits win over the resolved
 * record values before sending. The 2-arg build() is unchanged (delegates with no overrides).
 */
public with sharing class TurboSignRequestBuilder {
    private static final String DEFAULT_DATE_FORMAT = 'MMMM d, yyyy';
    // Java SimpleDateFormat pattern letters; any other unquoted ASCII letter makes the pattern invalid.
    private static final String DATE_PATTERN_LETTERS = 'GyYMLwWDdFEuaHkKhmsSzZX';
    // Field types a signer fills in; the others (full_name, email, ...) are auto-filled by TurboDocx.
    public static final Set<String> SIGNER_FILLED_TYPES = new Set<String>{ 'signature', 'initial', 'text', 'checkbox' };

    /** True for a blank pattern (the default is used) or a pattern Datetime.format accepts. */
    public static Boolean isValidDatePattern(String pattern) {
        if (String.isBlank(pattern)) return false;
        Boolean quoted = false;
        for (Integer i = 0; i < pattern.length(); i++) {
            String ch = pattern.substring(i, i + 1);
            if (ch == '\'') { quoted = !quoted; continue; }
            if (!quoted && ch.isAlpha() && ch.isAsciiPrintable() && !DATE_PATTERN_LETTERS.contains(ch)) return false;
        }
        return !quoted;
    }

    /** Signature and initial fields can never be optional at TurboDocx; other types follow the config. */
    public static Boolean fieldRequired(String fieldType, Boolean configured) {
        return fieldType == 'signature' || fieldType == 'initial' || configured == true;
    }

    /** What the signer is called in emails and the audit trail: their name, else their email address. */
    @TestVisible
    private static String displayName(String nameStr, String emailStr) {
        return String.isNotBlank(nameStr) ? nameStr : emailStr;
    }

    /**
     * One variable for /v1/deliverable. A blank REQUIRED value blocks the send before any callout (spec
     * §7.2). A blank optional value is sent isDisabled, the only way the backend accepts empty text, and
     * renders that spot empty (#38, e.g. no second resident).
     */
    @TestVisible
    private static Map<String, Object> variableFor(TurboSign_Variable_Mapping__mdt m, String text) {
        if (String.isBlank(text) && m.Required__c == true) {
            throw new TurboSignHttpClient.ApiException('Required value ' + m.Placeholder__c
                + ' is empty on this record. Fill in its source field or mark it optional in TurboSign Setup.');
        }
        Map<String, Object> v = new Map<String, Object>{
            'placeholder' => m.Placeholder__c, 'text' => text,
            'mimeType' => (String.isBlank(m.Mime_Type__c) ? 'text' : m.Mime_Type__c) };
        if (String.isBlank(text)) v.put('isDisabled', true);
        return v;
    }

    /**
     * TurboDocx requires signing order 1..n with no gaps. Dropping an optional signer leaves one, so
     * re-rank densely (equal orders stay equal: those signers sign in parallel). Input is already sorted.
     */
    @TestVisible
    private static void renumberSigningOrder(List<Object> recipients) {
        Integer rank = 0;
        Decimal last;
        for (Object o : recipients) {
            Map<String, Object> r = (Map<String, Object>) o;
            Decimal ord = (Decimal) r.get('signingOrder');
            if (rank == 0 || ord != last) rank++;
            last = ord;
            r.put('signingOrder', rank);
        }
    }

    /**
     * Resolves the document-name pattern against a record: {Field.Path} tokens become the record's value
     * and {date} becomes today's date (Date_Format__c pattern, or a sensible default). So a shared config
     * names each document per record, e.g. "Lease - {Account.Name} - {date}".
     */
    public static String resolveDocumentName(String template, Id recordId, String dateFormat) {
        if (String.isBlank(template)) return 'TurboSign Document';
        // Collect {Field.Path} tokens ({date} is handled separately).
        Set<String> paths = new Set<String>();
        Matcher m = Pattern.compile('\\{([^}]+)\\}').matcher(template);
        while (m.find()) {
            String tok = m.group(1).trim();
            if (String.isNotBlank(tok) && tok != 'date') paths.add(tok);
        }
        Map<String, Object> vals = new Map<String, Object>();
        if (recordId != null && !paths.isEmpty()) {
            TurboSignFieldResolver.ResolveRequest rr = new TurboSignFieldResolver.ResolveRequest();
            rr.recordId = recordId; rr.paths = new List<String>(paths);
            vals = TurboSignFieldResolver.resolve(rr);
        }
        String out = template;
        for (String p : paths) {
            Object v = vals.get(p);
            out = out.replace('{' + p + '}', v == null ? '' : String.valueOf(v));
        }
        if (out.contains('{date}')) {
            String fmt = isValidDatePattern(dateFormat) ? dateFormat : DEFAULT_DATE_FORMAT;
            out = out.replace('{date}', Datetime.now().format(fmt));
        }
        out = out.trim();
        return String.isBlank(out) ? 'TurboSign Document' : out;
    }

    /**
     * A recipient's effective name/email: a rep's send-time override wins, then a configured static
     * (literal) value, then the value resolved from a record field path. Lets a signer who isn't on the
     * record (a facility rep, a witness) be configured with a fixed name/email.
     */
    @TestVisible
    private static String pick(String overrideVal, String staticVal, String path, Map<String, Object> vals) {
        if (String.isNotBlank(overrideVal)) return overrideVal;
        if (String.isNotBlank(staticVal)) return staticVal;
        Object v = (String.isNotBlank(path) && vals != null) ? vals.get(path) : null;
        return v == null ? null : String.valueOf(v);
    }

    /** Raw config + resolved record values, shared by build() and preview() so resolution lives once. */
    private class Resolved {
        TurboSign_Config__mdt cfg;
        List<TurboSign_Variable_Mapping__mdt> maps;
        List<TurboSign_Recipient_Rule__mdt> recRules;
        List<TurboSign_Field_Rule__mdt> fieldRules;
        Map<String, Object> vals = new Map<String, Object>();
    }

    private static Resolved resolveAll(Id recordId, String configDeveloperName) {
        TurboSign_Config__mdt cfg = TurboSign_Config__mdt.getInstance(configDeveloperName);
        if (cfg == null) {
            throw new TurboSignHttpClient.ApiException('No TurboSign_Config__mdt named ' + configDeveloperName);
        }
        Resolved r = new Resolved();
        r.cfg = cfg;
        r.maps = [
            SELECT Placeholder__c, Source_Field_Path__c, Mime_Type__c, Default_Value__c, Editable_In_Modal__c, Required__c
            FROM TurboSign_Variable_Mapping__mdt WHERE Config__r.DeveloperName = :configDeveloperName AND Active__c = true];
        r.recRules = [
            SELECT Role_Label__c, Name_Field_Path__c, Email_Field_Path__c, Static_Name__c, Static_Email__c, Signing_Order__c, Required__c
            FROM TurboSign_Recipient_Rule__mdt WHERE Config__r.DeveloperName = :configDeveloperName AND Active__c = true
            ORDER BY Signing_Order__c NULLS LAST];
        r.fieldRules = [
            SELECT Anchor__c, Field_Type__c, Recipient_Role_Label__c, Width__c, Height__c, Placement__c, Required__c
            FROM TurboSign_Field_Rule__mdt WHERE Config__r.DeveloperName = :configDeveloperName AND Active__c = true];

        Set<String> recipientPaths = new Set<String>();
        for (TurboSign_Recipient_Rule__mdt rec : r.recRules) {
            if (String.isNotBlank(rec.Name_Field_Path__c)) recipientPaths.add(rec.Name_Field_Path__c);
            if (String.isNotBlank(rec.Email_Field_Path__c)) recipientPaths.add(rec.Email_Field_Path__c);
        }
        r.vals = resolveValues(recordId, r.maps, recipientPaths, cfg.Date_Format__c);
        return r;
    }

    /**
     * Reads the mappings' fields (plus extraPaths) from the record the way a send does: numbers and dates
     * come back localized by SOQL FORMAT(), except dates when a Date Format pattern is set (resolvedText
     * applies it). Also backs the builder's Preview values, so the preview shows what a send would.
     */
    public static Map<String, Object> resolveValues(Id recordId, List<TurboSign_Variable_Mapping__mdt> maps, Set<String> extraPaths, String dateFormat) {
        Set<String> paths = new Set<String>(extraPaths);
        for (TurboSign_Variable_Mapping__mdt m : maps) if (String.isNotBlank(m.Source_Field_Path__c)) paths.add(m.Source_Field_Path__c);
        if (paths.isEmpty()) return new Map<String, Object>();
        TurboSignFieldResolver.ResolveRequest rr = new TurboSignFieldResolver.ResolveRequest();
        rr.recordId = recordId; rr.paths = new List<String>(paths);
        rr.formatPaths = nativeFormatPaths(recordId.getSObjectType(), maps, String.isNotBlank(dateFormat));
        return TurboSignFieldResolver.resolve(rr);
    }

    /**
     * Resolved value for a mapping (record path -> value, else default), overridden if the rep edited it.
     * Currency/number fields arrive already localized from SOQL FORMAT() (see nativeFormatPaths). Dates
     * arrive localized too, UNLESS the config sets a Date_Format__c pattern — then they come back raw and
     * we apply that pattern here so every date in the document follows the customer's chosen style.
     */
    public static String resolvedText(TurboSign_Variable_Mapping__mdt m, Map<String, Object> vals, Map<String, String> overrides, String dateFormat) {
        if (overrides != null && overrides.containsKey(m.Placeholder__c)) {
            return overrides.get(m.Placeholder__c);
        }
        Object v = String.isNotBlank(m.Source_Field_Path__c) ? vals.get(m.Source_Field_Path__c) : null;
        if (v == null) {
            return m.Default_Value__c == null ? '' : m.Default_Value__c;
        }
        if ((v instanceof Date || v instanceof Datetime) && String.isNotBlank(dateFormat)) {
            return applyDatePattern(v, dateFormat);
        }
        return String.valueOf(v);
    }

    /** Apply an Apex/Java date pattern to a Date/Datetime; falls back to the raw value if the pattern is invalid. */
    @TestVisible
    private static String applyDatePattern(Object v, String pattern) {
        try {
            if (v instanceof Date) {
                Date d = (Date) v;
                return Datetime.newInstance(d.year(), d.month(), d.day(), 0, 0, 0).format(pattern);
            }
            if (v instanceof Datetime) {
                return ((Datetime) v).format(pattern);
            }
        } catch (Exception e) {
            return String.valueOf(v); // bad pattern -> don't blow up the send; use the raw value
        }
        return String.valueOf(v);
    }

    /**
     * Field paths whose values should be localized natively by SOQL FORMAT() (currency, number, percent,
     * and dates when no custom Date_Format__c pattern is configured). Text fields must NOT be wrapped —
     * FORMAT() only accepts numeric/date/time fields — so they are excluded here and selected raw.
     */
    @TestVisible
    private static Set<String> nativeFormatPaths(Schema.SObjectType rootType, List<TurboSign_Variable_Mapping__mdt> maps, Boolean datesUseCustomPattern) {
        Set<String> out = new Set<String>();
        for (TurboSign_Variable_Mapping__mdt m : maps) {
            if (String.isBlank(m.Source_Field_Path__c)) continue;
            Schema.DisplayType t = finalFieldType(rootType, m.Source_Field_Path__c);
            if (t == null) continue;
            Boolean numeric = (t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.DOUBLE
                || t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG || t == Schema.DisplayType.PERCENT);
            Boolean dateLike = (t == Schema.DisplayType.DATE || t == Schema.DisplayType.DATETIME || t == Schema.DisplayType.TIME);
            if (numeric || (dateLike && !datesUseCustomPattern)) {
                out.add(m.Source_Field_Path__c);
            }
        }
        return out;
    }

    /**
     * Ensure every configured signature/date anchor survives the mail-merge by appending it as a variable
     * whose value is the token itself (e.g. {sig} -> "{sig}"). Skips any anchor the admin already mapped
     * explicitly. This is what lets the Anchors section stand alone with no self-value mapping row.
     */
    @TestVisible
    private static void injectAnchorSelfValues(List<Object> variables, List<TurboSign_Field_Rule__mdt> fieldRules, Set<String> mappedPlaceholders, Set<String> survivingRoles) {
        if (fieldRules == null) return;
        Set<String> injected = new Set<String>();
        for (TurboSign_Field_Rule__mdt f : fieldRules) {
            String anchor = f.Anchor__c;
            if (String.isBlank(anchor) || mappedPlaceholders.contains(anchor) || injected.contains(anchor)) continue;
            // Only merge the anchor token for anchors whose recipient survived; otherwise the field/box is
            // dropped downstream and the token would linger as literal text in the document.
            if (survivingRoles != null && !survivingRoles.contains(f.Recipient_Role_Label__c)) continue;
            injected.add(anchor);
            variables.add(new Map<String, Object>{ 'placeholder' => anchor, 'text' => anchor, 'mimeType' => 'text' });
        }
    }

    public static TurboSignService.SendRequest build(Id recordId, String configDeveloperName) {
        return build(recordId, configDeveloperName, null, null);
    }

    public static TurboSignService.SendRequest build(Id recordId, String configDeveloperName, Map<String, String> overrides) {
        return build(recordId, configDeveloperName, overrides, null);
    }

    /** Who a send goes to, and whose anchors the document keeps (see resolveRecipients). */
    @TestVisible
    private class ResolvedRecipients {
        @TestVisible List<Object> recipients = new List<Object>();      // [{name,email,signingOrder}]
        @TestVisible Map<String, String> roleToEmail = new Map<String, String>();
        @TestVisible Set<String> anchorRoles = new Set<String>();        // roles whose anchor tokens are merged
    }

    @TestVisible
    private class RecipientParams {
        @TestVisible List<TurboSign_Recipient_Rule__mdt> rules;
        @TestVisible Map<String, Map<String, String>> overrides;       // role -> { name, email } edited by the rep
        @TestVisible Map<String, Object> vals;                          // resolved record values
        @TestVisible Boolean forPreview = false;
    }

    /**
     * Applies the recipient rules (optional roles that resolve no email are dropped, not errored: §7.3).
     * A send stops on a required signer with no email. The Review step's preview only renders the document,
     * so it doesn't: it keeps that signer's anchors, showing the document the send will produce once the rep
     * fills in the email. An optional signer with no email is dropped in both, so its anchors render empty
     * in the preview exactly as in the sent document.
     */
    @TestVisible
    private static ResolvedRecipients resolveRecipients(RecipientParams p) {
        ResolvedRecipients out = new ResolvedRecipients();
        Integer signerNo = 0;
        for (TurboSign_Recipient_Rule__mdt rec : p.rules) {
            signerNo++;
            Map<String, String> ovr = (p.overrides != null) ? p.overrides.get(rec.Role_Label__c) : null;
            String emailStr = pick((ovr != null) ? ovr.get('email') : null, rec.Static_Email__c, rec.Email_Field_Path__c, p.vals);
            if (String.isBlank(emailStr)) {
                if (rec.Required__c == true) {
                    if (p.forPreview != true) {
                        // Role_Label__c is a hidden id (signer_<n>); name the signer by position instead.
                        throw new TurboSignHttpClient.ApiException('Signer ' + signerNo + ' has no email on this record.');
                    }
                    out.anchorRoles.add(rec.Role_Label__c);
                }
                continue;
            }
            String nameStr = pick((ovr != null) ? ovr.get('name') : null, rec.Static_Name__c, rec.Name_Field_Path__c, p.vals);
            out.recipients.add(new Map<String, Object>{
                'name' => displayName(nameStr, emailStr),
                'email' => emailStr,
                'signingOrder' => (rec.Signing_Order__c != null ? rec.Signing_Order__c : 1) });
            out.roleToEmail.put(rec.Role_Label__c, emailStr);
            out.anchorRoles.add(rec.Role_Label__c);
        }
        renumberSigningOrder(out.recipients);
        return out;
    }

    /** A record, a config and the rep's edits from the review modal. */
    public class BuildParams {
        public Id recordId;
        public String configDeveloperName;
        public Map<String, String> overrides;                         // placeholder -> edited value
        public Map<String, Map<String, String>> recipientOverrides;   // role -> { name, email }
    }

    /**
     * @param overrides           placeholder -> edited variable value (rep's edits win over the record).
     * @param recipientOverrides  role -> { name, email } edited signer values (win over resolved fields).
     */
    public static TurboSignService.SendRequest build(
        Id recordId, String configDeveloperName, Map<String, String> overrides, Map<String, Map<String, String>> recipientOverrides
    ) {
        BuildParams p = new BuildParams();
        p.recordId = recordId;
        p.configDeveloperName = configDeveloperName;
        p.overrides = overrides;
        p.recipientOverrides = recipientOverrides;
        return compose(p, false);
    }

    /**
     * The request the Review step's preview renders: the same template, name and variables as the send, but
     * a signer with no email doesn't stop it (see resolveRecipients). Its recipients are not sendable.
     */
    public static TurboSignService.SendRequest buildForPreview(BuildParams p) {
        return compose(p, true);
    }

    private static TurboSignService.SendRequest compose(BuildParams p, Boolean forPreview) {
        Id recordId = p.recordId;
        String configDeveloperName = p.configDeveloperName;
        Resolved r = resolveAll(recordId, configDeveloperName);

        List<Object> variables = new List<Object>();
        Set<String> mappedPlaceholders = new Set<String>();
        for (TurboSign_Variable_Mapping__mdt m : r.maps) {
            mappedPlaceholders.add(m.Placeholder__c);
            variables.add(variableFor(m, resolvedText(m, r.vals, p.overrides, r.cfg.Date_Format__c)));
        }
        RecipientParams rp = new RecipientParams();
        rp.rules = r.recRules;
        rp.overrides = p.recipientOverrides;
        rp.vals = r.vals;
        rp.forPreview = forPreview;
        ResolvedRecipients who = resolveRecipients(rp);
        List<Object> recipients = who.recipients;
        Map<String, String> roleToEmail = who.roleToEmail;

        // Anchors are their own source of truth (the Anchors section): auto-inject each configured anchor
        // token as a variable whose value is the token itself, so it survives the mail-merge. Only inject
        // anchors whose recipient survived so a dropped signer never leaves a literal token.
        injectAnchorSelfValues(variables, r.fieldRules, mappedPlaceholders, who.anchorRoles);

        // Fields (anchors — §2.6)
        List<Object> fields = new List<Object>();
        for (TurboSign_Field_Rule__mdt f : r.fieldRules) {
            String em = roleToEmail.get(f.Recipient_Role_Label__c);
            if (em == null) continue; // recipient dropped -> skip its fields
            fields.add(new Map<String, Object>{
                'type' => f.Field_Type__c, 'recipientEmail' => em, 'required' => fieldRequired(f.Field_Type__c, f.Required__c),
                'template' => new Map<String, Object>{
                    'anchor' => f.Anchor__c,
                    'placement' => (String.isBlank(f.Placement__c) ? 'replace' : f.Placement__c),
                    'size' => new Map<String, Object>{
                        'width' => (f.Width__c != null ? f.Width__c : 150),
                        'height' => (f.Height__c != null ? f.Height__c : 40) } } });
        }

        TurboSignService.SendRequest req = new TurboSignService.SendRequest();
        req.recordId = recordId;
        req.templateId = r.cfg.Deliverable_Template_Id__c;
        req.documentName = resolveDocumentName(r.cfg.Document_Name_Template__c, recordId, r.cfg.Date_Format__c);
        req.configDeveloperName = configDeveloperName;
        req.variables = variables;
        req.recipients = recipients;
        req.fields = fields;
        req.senderEmail = UserInfo.getUserEmail();
        req.senderName = UserInfo.getName();
        req.completionField = r.cfg.Completion_Field__c;
        req.completionValue = r.cfg.Completion_Value__c;
        return req;
    }

    /**
     * Resolved-but-not-sent view for the pre-send review UI: each variable prefilled from the record
     * with an `editable` flag (from Editable_In_Modal__c), the resolved recipients, and the configured
     * anchors. Anchor presence (found/missing QA) is layered on by the caller via the backend preview.
     */
    public static Map<String, Object> preview(Id recordId, String configDeveloperName) {
        Resolved r = resolveAll(recordId, configDeveloperName);
        Schema.SObjectType rootType = recordId.getSObjectType();

        List<Object> variables = new List<Object>();
        for (TurboSign_Variable_Mapping__mdt m : r.maps) {
            // source = where the prefilled value came from (record field path, e.g. Account.Name), so a
            // rep can trace it when a config maps many referenced fields across objects. Blank = a static
            // default with no record field behind it. sourceLabel humanizes it with the org's field labels.
            Boolean hasSource = String.isNotBlank(m.Source_Field_Path__c);
            variables.add(new Map<String, Object>{
                'placeholder' => m.Placeholder__c,
                'label' => labelFor(m.Placeholder__c),
                'value' => resolvedText(m, r.vals, null, r.cfg.Date_Format__c),
                'editable' => (m.Editable_In_Modal__c == true),
                'source' => hasSource ? m.Source_Field_Path__c : null,
                'sourceObject' => hasSource ? m.Source_Field_Path__c.substringBefore('.') : null,
                'sourceLabel' => hasSource ? friendlyPath(rootType, m.Source_Field_Path__c) : null,
                'mimeType' => (String.isBlank(m.Mime_Type__c) ? 'text' : m.Mime_Type__c) });
        }

        List<Object> recipients = new List<Object>();
        for (TurboSign_Recipient_Rule__mdt rec : r.recRules) {
            String nameStr = pick(null, rec.Static_Name__c, rec.Name_Field_Path__c, r.vals);
            String emailStr = pick(null, rec.Static_Email__c, rec.Email_Field_Path__c, r.vals);
            recipients.add(new Map<String, Object>{
                'role' => rec.Role_Label__c,
                'name' => (nameStr != null ? nameStr : ''),
                'email' => (emailStr != null ? emailStr : ''),
                'nameSource' => (String.isNotBlank(rec.Static_Name__c) ? 'fixed value' : rec.Name_Field_Path__c),
                'emailSource' => (String.isNotBlank(rec.Static_Email__c) ? 'fixed value' : rec.Email_Field_Path__c),
                'nameSourceLabel' => friendlyPath(rootType, rec.Name_Field_Path__c),
                'emailSourceLabel' => friendlyPath(rootType, rec.Email_Field_Path__c),
                'required' => (rec.Required__c == true) });
        }

        List<Object> anchors = new List<Object>();
        for (TurboSign_Field_Rule__mdt f : r.fieldRules) {
            anchors.add(new Map<String, Object>{
                'anchor' => f.Anchor__c, 'type' => f.Field_Type__c, 'role' => f.Recipient_Role_Label__c });
        }

        return new Map<String, Object>{
            'templateId' => r.cfg.Deliverable_Template_Id__c,
            'documentName' => resolveDocumentName(r.cfg.Document_Name_Template__c, recordId, r.cfg.Date_Format__c),
            'variables' => variables, 'recipients' => recipients, 'anchors' => anchors };
    }

    /** Humanize a placeholder for the review UI: {ClientName} -> "Client Name". */
    private static String labelFor(String placeholder) {
        if (String.isBlank(placeholder)) return '';
        String s = placeholder.replaceAll('[{}]', '');
        s = s.replaceAll('([a-z])([A-Z])', '$1 $2').replaceAll('[_\\-]', ' ');
        return s.trim();
    }

    // Describe caches so a preview with many paths on the same object doesn't re-scan its fields.
    private static Map<String, Map<String, Schema.SObjectField>> FIELD_CACHE = new Map<String, Map<String, Schema.SObjectField>>();
    private static Map<String, Map<String, Schema.SObjectField>> REL_CACHE = new Map<String, Map<String, Schema.SObjectField>>();

    private static Map<String, Schema.SObjectField> fieldsOf(Schema.SObjectType t) {
        String k = String.valueOf(t);
        if (!FIELD_CACHE.containsKey(k)) FIELD_CACHE.put(k, t.getDescribe().fields.getMap());
        return FIELD_CACHE.get(k);
    }

    /** relationshipName (lowercased) -> the lookup field, e.g. "unit__r" -> Opportunity.Unit__c. */
    private static Map<String, Schema.SObjectField> relsOf(Schema.SObjectType t) {
        String k = String.valueOf(t);
        if (!REL_CACHE.containsKey(k)) {
            Map<String, Schema.SObjectField> m = new Map<String, Schema.SObjectField>();
            for (Schema.SObjectField f : fieldsOf(t).values()) {
                String rn = f.getDescribe().getRelationshipName();
                if (String.isNotBlank(rn)) m.put(rn.toLowerCase(), f);
            }
            REL_CACHE.put(k, m);
        }
        return REL_CACHE.get(k);
    }

    private static String trimIdSuffix(String label) {
        return (label != null && label.endsWithIgnoreCase(' id')) ? label.substring(0, label.length() - 3).trim() : label;
    }

    /**
     * Human provenance label from a field path, using the org's own field labels:
     *   Account.Name        -> "Account · Account Name"
     *   Unit__r.Name        -> "Apartment · Apartment Name"
     *   Housing_Type__c     -> "Level of Care"
     * Relationship segments use the lookup's label (trailing " Id" trimmed). Falls back to the raw
     * path if any segment can't be described, so the rep always sees something traceable.
     */
    /** DisplayType of the field a path ends on (traversing relationships), or null if it can't be described. */
    private static Schema.DisplayType finalFieldType(Schema.SObjectType rootType, String path) {
        if (rootType == null || String.isBlank(path)) return null;
        List<String> parts = path.split('\\.');
        Schema.SObjectType current = rootType;
        for (Integer i = 0; i < parts.size(); i++) {
            if (i == parts.size() - 1) {
                Schema.SObjectField f = fieldsOf(current).get(parts[i]);
                return f == null ? null : f.getDescribe().getType();
            }
            Schema.SObjectField rel = relsOf(current).get(parts[i].toLowerCase());
            if (rel == null) return null;
            List<Schema.SObjectType> refs = rel.getDescribe().getReferenceTo();
            if (refs == null || refs.isEmpty()) return null;
            current = refs[0];
        }
        return null;
    }

    @TestVisible
    private static String friendlyPath(Schema.SObjectType rootType, String path) {
        if (String.isBlank(path)) return null;
        if (rootType == null) return path;
        List<String> parts = path.split('\\.');
        Schema.SObjectType current = rootType;
        List<String> labels = new List<String>();
        for (Integer i = 0; i < parts.size(); i++) {
            if (i == parts.size() - 1) {
                Schema.SObjectField f = fieldsOf(current).get(parts[i]);
                if (f == null) return path;
                labels.add(f.getDescribe().getLabel());
            } else {
                Schema.SObjectField rel = relsOf(current).get(parts[i].toLowerCase());
                if (rel == null) return path;
                Schema.DescribeFieldResult rd = rel.getDescribe();
                List<Schema.SObjectType> refs = rd.getReferenceTo();
                if (refs == null || refs.isEmpty()) return path;
                labels.add(trimIdSuffix(rd.getLabel()));
                current = refs[0];
            }
        }
        return String.join(labels, ' · ');
    }
}
