/**
 * Admin config builder backend (spec §9.2 setup wizard). Lets a Salesforce admin pick a TurboDocx
 * template, map its variables to record fields, define recipients, and place signature/date anchors,
 * then persists the whole thing as the TurboSign CMDT graph. Writes CMDT via the Apex Metadata API
 * (Metadata.Operations.enqueueDeployment) — the reliable path on orgs where a Metadata-API deploy of
 * CMDT records throws UNKNOWN_EXCEPTION. No hardcoding: switching template / mapping fields / moving
 * anchors is all data the LWC collects and this saves.
 */
public with sharing class TurboSignConfigController {

    /** Resolve an in-progress config's variable mappings against a sample record so an admin can preview before saving. */
    /** Live preview of the document-name pattern resolved against a record (for the name builder). */
    @AuraEnabled
    public static String previewDocumentName(Id recordId, String template, String dateFormat) {
        return TurboSignRequestBuilder.resolveDocumentName(template, recordId, dateFormat);
    }

    @AuraEnabled
    public static List<Object> previewPayload(Id recordId, String payloadJson) {
        List<Object> out = new List<Object>();
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        List<Object> vars = listOf(p.get('variables'));
        List<String> paths = new List<String>();
        for (Object o : vars) {
            String sf = (String) ((Map<String, Object>) o).get('sourceField');
            if (String.isNotBlank(sf)) paths.add(sf);
        }
        Map<String, Object> vals = new Map<String, Object>();
        if (recordId != null && !paths.isEmpty()) {
            TurboSignFieldResolver.ResolveRequest rr = new TurboSignFieldResolver.ResolveRequest();
            rr.recordId = recordId; rr.paths = paths;
            vals = TurboSignFieldResolver.resolve(rr);
        }
        for (Object o : vars) {
            Map<String, Object> v = (Map<String, Object>) o;
            String sf = (String) v.get('sourceField');
            // Mirror the real send: when a mapped field resolves null, fall back to the default value.
            Object resolved = String.isNotBlank(sf) ? vals.get(sf) : null;
            Boolean fromField = resolved != null;
            Object val = fromField ? resolved : v.get('defaultValue');
            out.add(new Map<String, Object>{
                'placeholder' => v.get('placeholder'),
                'value' => (val == null ? '' : String.valueOf(val)),
                'source' => fromField ? sf : 'default value' });
        }
        return out;
    }

    /** Best-matching field value for a token (placeholder or 'Name'/'Email'), by word overlap with labels; '' if none. */
    @AuraEnabled(cacheable=true)
    public static String bestFieldMatch(String token, List<Map<String, Object>> options) {
        if (String.isBlank(token) || options == null || options.isEmpty()) return '';
        Set<String> want = words(token);
        if (want.isEmpty()) return '';
        String best = '';
        Integer bestScore = 0;
        for (Map<String, Object> o : options) {
            Set<String> have = words(String.valueOf(o.get('label')));
            Integer score = 0;
            for (String w : want) if (have.contains(w)) score++;
            if (score > bestScore) { bestScore = score; best = String.valueOf(o.get('value')); }
        }
        return best;
    }

    /** Lowercased word set from a string, splitting on non-alphanumerics and camelCase. */
    private static Set<String> words(String s) {
        Set<String> out = new Set<String>();
        if (String.isBlank(s)) return out;
        String spaced = s.replaceAll('([a-z0-9])([A-Z])', '$1 $2').replaceAll('[^A-Za-z0-9]', ' ');
        for (String w : spaced.toLowerCase().split('\\s+')) if (String.isNotBlank(w)) out.add(w);
        return out;
    }

    /** Pre-save checks: returns human-readable problems with a config payload so nothing ships broken. */
    @AuraEnabled(cacheable=true)
    public static List<String> validateConfig(String payloadJson, List<String> templatePlaceholders) {
        List<String> issues = new List<String>();
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        if (String.isBlank((String) p.get('developerName'))) issues.add('Config API Name is required.');
        if (String.isBlank((String) p.get('templateId'))) issues.add('Select a TurboDocx template.');

        List<Object> recips = listOf(p.get('recipients'));
        if (recips.isEmpty()) issues.add('Add at least one recipient (signer).');

        // Which placeholders actually have a value behind them (a field path or a default).
        Set<String> mapped = new Set<String>();
        for (Object o : listOf(p.get('variables'))) {
            Map<String, Object> v = (Map<String, Object>) o;
            String ph = (String) v.get('placeholder');
            Boolean hasValue = String.isNotBlank((String) v.get('sourceField')) || String.isNotBlank((String) v.get('defaultValue'));
            if (String.isNotBlank(ph) && hasValue) mapped.add(ph);
        }
        // A signing token that sits in the template as text ({sig}) is placed as a field, so it is covered.
        for (Object o : listOf(p.get('fields'))) {
            String anchor = (String) ((Map<String, Object>) o).get('anchor');
            if (String.isNotBlank(anchor)) mapped.add(anchor);
        }
        if (templatePlaceholders != null) {
            for (String ph : templatePlaceholders) {
                if (String.isNotBlank(ph) && !mapped.contains(ph)) issues.add('Template placeholder ' + ph + ' is not mapped to a field.');
            }
        }

        // Duplicate recipient roles / signing orders.
        Set<String> roles = new Set<String>();
        Set<String> orders = new Set<String>();
        for (Object o : recips) {
            Map<String, Object> r = (Map<String, Object>) o;
            String role = (String) r.get('role');
            if (String.isNotBlank(role)) {
                if (roles.contains(role)) issues.add('Two signers share the same internal id (' + role + '). Remove one and add it again.'); else roles.add(role);
            }
            if (r.get('order') != null) {
                String ord = String.valueOf(r.get('order'));
                if (orders.contains(ord)) issues.add('Two recipients share signing order ' + ord + '.'); else orders.add(ord);
            }
        }

        // Anchors: must carry a recipient role, and that role must exist. Track which roles have a field
        // so we can flag any signer who has none.
        Set<String> rolesWithField = new Set<String>();
        for (Object o : listOf(p.get('fields'))) {
            Map<String, Object> f = (Map<String, Object>) o;
            String anchor = (String) f.get('anchor');
            String role = (String) f.get('role');
            String type = (String) f.get('type');
            if (String.isBlank(anchor)) continue;
            // TurboDocx rejects optional signature/initial fields (OptionalNotSupported).
            if ((type == 'signature' || type == 'initial') && f.get('required') == false) {
                issues.add('Field ' + anchor + ' is a ' + type + ' and cannot be optional.');
            }
            Boolean required = TurboSignRequestBuilder.fieldRequired(type, f.get('required') == true);
            if (String.isBlank(role)) {
                issues.add('Anchor ' + anchor + ' has no recipient role (its signature box would be dropped).');
            } else if (!roles.contains(role)) {
                issues.add('Anchor ' + anchor + ' targets role "' + role + '" but no recipient has that role.');
            } else if (required && TurboSignRequestBuilder.SIGNER_FILLED_TYPES.contains(type)) {
                // Only a required field the signer fills in counts: TurboDocx rejects a signer with none
                // (NoEditableFieldsForRecipient).
                rolesWithField.add(role);
            }
        }

        // Every signer needs somewhere to sign: each recipient must have at least one field assigned.
        Integer pos = 0;
        for (Object o : recips) {
            pos++;
            Map<String, Object> r = (Map<String, Object>) o;
            String role = (String) r.get('role');
            if (String.isBlank(role) || rolesWithField.contains(role)) continue;
            String nameField = (String) r.get('nameField');
            String who = 'Signer ' + pos + (String.isNotBlank(nameField) ? ' (' + nameField + ')' : '');
            issues.add(who + ' has no required signature field. Assign one under Template Tokens, or remove the signer.');
        }

        String df = (String) p.get('dateFormat');
        if (String.isNotBlank(df) && !TurboSignRequestBuilder.isValidDatePattern(df)) {
            issues.add('Date format "' + df + '" is not a valid pattern (use letters like yyyy, MM, d, MMMM).');
        }

        // API Name length — the CMDT DeveloperName (fullName) maxes out at 40 chars; a longer one fails the deploy.
        String dev = (String) p.get('developerName');
        if (String.isNotBlank(dev) && dev.length() > 40) {
            issues.add('Config API Name must be 40 characters or fewer (it is ' + dev.length() + ').');
        }

        // Completion field, if set, must be a real field on the source object.
        String sourceObject = (String) p.get('sourceObject');
        String completionField = (String) p.get('completionField');
        if (String.isNotBlank(completionField) && String.isNotBlank(sourceObject) && !fieldExists(sourceObject, completionField)) {
            issues.add('Completion field ' + completionField + ' does not exist on ' + sourceObject + '.');
        }
        return issues;
    }

    /** True if fieldApiName is a real field on objectApiName (describe-backed). */
    private static Boolean fieldExists(String objectApiName, String fieldApiName) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
        if (t == null) return false;
        return t.getDescribe().fields.getMap().containsKey(fieldApiName);
    }

    // ---- Template picker (live from TurboDocx) ----
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getTemplateOptions() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        try {
            Map<String, Object> resp = TurboSignHttpClient.listTemplates();
            for (Object o : extractList(resp)) {
                if (o instanceof Map<String, Object>) {
                    Map<String, Object> t = (Map<String, Object>) o;
                    Object id = t.get('id');
                    Object name = t.get('name') != null ? t.get('name') : t.get('title');
                    if (id != null) {
                        out.add(new Map<String, Object>{ 'value' => String.valueOf(id), 'label' => String.valueOf(name) });
                    }
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException('Could not load templates from TurboDocx: ' + e.getMessage());
        }
        return out;
    }

    /**
     * Placeholders the selected TurboDocx template already declares (parsed at upload), so the builder can
     * pre-fill a Variable Mapping row per token instead of making the admin retype every {placeholder}.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getTemplatePlaceholders(String templateId) {
        List<String> out = new List<String>();
        if (String.isBlank(templateId)) return out;
        try {
            Map<String, Object> resp = TurboSignHttpClient.getTemplate(templateId);
            if (resp == null) return out;
            // getJson already strips a lone {data:...}; tolerate {data:{results}}, {results:{}}, or the template itself.
            Map<String, Object> tmpl = resp;
            if (tmpl.get('data') instanceof Map<String, Object>) tmpl = (Map<String, Object>) tmpl.get('data');
            Object results = tmpl.get('results');
            if (results instanceof Map<String, Object>) {
                tmpl = (Map<String, Object>) results;
            } else if (results instanceof List<Object> && !((List<Object>) results).isEmpty()
                       && ((List<Object>) results)[0] instanceof Map<String, Object>) {
                tmpl = (Map<String, Object>) ((List<Object>) results)[0];
            }
            Object vars = tmpl.get('variables');
            if (vars instanceof List<Object>) {
                Set<String> seen = new Set<String>();
                for (Object o : (List<Object>) vars) {
                    if (o instanceof Map<String, Object>) {
                        Object ph = ((Map<String, Object>) o).get('placeholder');
                        String s = (ph == null) ? null : String.valueOf(ph);
                        if (String.isNotBlank(s) && !seen.contains(s)) { seen.add(s); out.add(s); }
                    }
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException('Could not load template fields: ' + e.getMessage());
        }
        return out;
    }

    /** CMDT records that deactivate a whole config (config + every child set Active__c = false). */
    @TestVisible
    private static List<Metadata.CustomMetadata> buildDeactivation(String developerName) {
        List<Metadata.CustomMetadata> recs = new List<Metadata.CustomMetadata>();
        TurboSign_Config__mdt c = TurboSign_Config__mdt.getInstance(developerName);
        if (c == null) return recs;
        Metadata.CustomMetadata cfg = record('TurboSign_Config.' + developerName, c.MasterLabel);
        addVal(cfg, 'Active__c', false);
        recs.add(cfg);
        // Deactivate every child too (empty keep-set => all children are treated as removed).
        recs.addAll(deactivationRecordsFor(developerName, new Set<String>()));
        return recs;
    }

    /**
     * Gate for the config-mutation methods. They deploy Custom Metadata in system context, so class
     * access alone is too weak; require the TurboSign_Manage_Configuration custom permission (granted via
     * the TurboSign Admin permission set). The send/preview flow does NOT call this.
     */
    @TestVisible
    private static void requireConfigAdmin() {
        if (!FeatureManagement.checkPermission('TurboSign_Manage_Configuration')) {
            throw new AuraHandledException('You need the TurboSign Manage Configuration permission to change signing configurations.');
        }
    }

    /** Deactivate a config so it disappears from the send picker and the builder list (reversible). */
    @AuraEnabled
    public static Id deactivateConfig(String developerName) {
        requireConfigAdmin();
        if (String.isBlank(developerName)) throw new AuraHandledException('No config specified.');
        List<Metadata.CustomMetadata> recs = buildDeactivation(developerName);
        if (recs.isEmpty()) throw new AuraHandledException('Config not found: ' + developerName);
        Metadata.DeployContainer container = new Metadata.DeployContainer();
        for (Metadata.CustomMetadata md : recs) container.addMetadata(md);
        return Metadata.Operations.enqueueDeployment(container, new TurboSignConfigDeployCallback());
    }

    /** Suggest a valid Config API Name from a human label, so admins don't type the name twice. */
    @AuraEnabled(cacheable=true)
    public static String deriveApiName(String label) {
        return sanitize(label);
    }

    /** Active picklist values for a field so the builder can constrain the completion value; empty if the field isn't a picklist (UI then falls back to free text). */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getPicklistValues(String objectApiName, String fieldApiName) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) return out;
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
        if (t == null) return out;
        Schema.SObjectField f = t.getDescribe().fields.getMap().get(fieldApiName);
        if (f == null) return out;
        Schema.DescribeFieldResult d = f.getDescribe();
        if (!d.isAccessible()) return out; // FLS: don't enumerate values of a field the user can't read
        if (d.getType() != Schema.DisplayType.PICKLIST && d.getType() != Schema.DisplayType.MULTIPICKLIST) return out;
        for (Schema.PicklistEntry e : d.getPicklistValues()) {
            if (e.isActive()) out.add(new Map<String, Object>{ 'label' => e.getLabel(), 'value' => e.getValue() });
        }
        return out;
    }

    /** Sendable source objects for the builder's Source Object picker (queryable business objects, sorted). */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getObjectOptions() {
        Map<String, String> labelToApi = new Map<String, String>();
        List<String> labels = new List<String>();
        for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d = t.getDescribe();
            if (!d.isQueryable() || !d.isCreateable() || d.isCustomSetting()) continue;
            String api = d.getName();
            // Skip system shadow objects (standard AccountShare/AccountHistory... and custom __Share/__History...).
            if (api.endsWithIgnoreCase('Share') || api.endsWithIgnoreCase('History') || api.endsWithIgnoreCase('Feed')
                || api.endsWithIgnoreCase('Tag') || api.endsWith('__mdt') || api.endsWithIgnoreCase('ChangeEvent')) continue;
            String label = d.getLabel() + ' (' + api + ')';
            if (!labelToApi.containsKey(label)) { labelToApi.put(label, api); labels.add(label); }
        }
        labels.sort();
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (String label : labels) out.add(new Map<String, Object>{ 'label' => label, 'value' => labelToApi.get(label) });
        return out;
    }

    /**
     * Render the selected template and report which of the given anchor tokens are actually present, so an
     * admin can catch a mistyped/missing anchor in the builder before saving. Anchors are passed as
     * self-values (how they survive the merge); no record data is needed. Returns [{anchor, found, ...}].
     */
    @AuraEnabled
    public static List<Object> checkTemplateAnchors(String templateId, List<String> anchors) {
        if (String.isBlank(templateId) || anchors == null || anchors.isEmpty()) return new List<Object>();
        List<Object> variables = new List<Object>();
        List<Object> anchorList = new List<Object>();
        Set<String> uniq = new Set<String>();
        for (String a : anchors) {
            if (String.isNotBlank(a) && !uniq.contains(a)) {
                uniq.add(a);
                variables.add(new Map<String, Object>{ 'placeholder' => a, 'text' => a });
                anchorList.add(a);
            }
        }
        if (anchorList.isEmpty()) return new List<Object>();
        try {
            return TurboSignHttpClient.checkAnchors(new Map<String, Object>{
                'templateId' => templateId, 'variables' => variables, 'anchors' => anchorList });
        } catch (Exception e) {
            throw new AuraHandledException('Could not check anchors: ' + e.getMessage());
        }
    }

    @SuppressWarnings('PMD')
    private static List<Object> extractList(Map<String, Object> resp) {
        Object data = resp.get('data');
        if (data instanceof Map<String, Object>) {
            Object results = ((Map<String, Object>) data).get('results');
            if (results instanceof List<Object>) return (List<Object>) results;
            if (results instanceof Map<String, Object>) {
                for (Object v : ((Map<String, Object>) results).values()) {
                    if (v instanceof List<Object>) return (List<Object>) v;
                }
            }
        }
        if (resp.get('results') instanceof List<Object>) return (List<Object>) resp.get('results');
        return new List<Object>();
    }

    // ---- Existing configs (for the send picker + edit) ----
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> listConfigs(String sourceObject) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        String q = 'SELECT DeveloperName, MasterLabel, Source_SObject__c, Active__c, Deliverable_Template_Id__c '
                 + 'FROM TurboSign_Config__mdt WHERE Active__c = true';
        if (String.isNotBlank(sourceObject)) q += ' AND Source_SObject__c = :sourceObject';
        q += ' ORDER BY MasterLabel';
        for (TurboSign_Config__mdt c : Database.query(q)) {
            out.add(new Map<String, Object>{
                'value' => c.DeveloperName, 'label' => c.MasterLabel,
                'sourceObject' => c.Source_SObject__c, 'templateId' => c.Deliverable_Template_Id__c });
        }
        return out;
    }

    // ---- Save (writes the CMDT graph) ----
    @AuraEnabled
    public static Id saveConfig(String payloadJson) {
        requireConfigAdmin();
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        String dev = (String) p.get('developerName');

        List<Metadata.CustomMetadata> recs = buildMetadataRecords(payloadJson);
        Set<String> keep = new Set<String>();
        for (Metadata.CustomMetadata md : recs) keep.add(md.fullName);

        // Editing: children that used to exist but are no longer in the payload (removed/renamed rows)
        // must stop firing. The Apex Metadata API can only upsert (never delete) CMDT records, so we
        // deactivate the orphans instead; getConfig and TurboSignRequestBuilder read Active__c = true only.
        recs.addAll(deactivationRecordsFor(dev, keep));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        for (Metadata.CustomMetadata md : recs) container.addMetadata(md);
        // Callback records the async outcome so the LWC can surface a real success/failure (spec #7).
        return Metadata.Operations.enqueueDeployment(container, new TurboSignConfigDeployCallback());
    }

    /** Records an async CMDT deploy outcome, keyed by job id, for the LWC to poll. */
    // Admin-only (TurboSign_Manage_Configuration custom permission): reads TurboSign custom metadata,
    // which is configuration, not user data, and records/reads TurboSign_Log__c deploy outcomes.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static void logDeployResult(String jobId, String status, List<String> errors) {
        insert new TurboSign_Log__c(
            Operation__c = 'Config Deploy',
            Deploy_Job_Id__c = jobId,
            Request_Summary__c = status,
            Error_Message__c = (errors == null || errors.isEmpty()) ? null : String.join(errors, '; '),
            Occurred_On__c = System.now());
    }

    // Admin-only (TurboSign_Manage_Configuration custom permission): reads TurboSign custom metadata,
    // which is configuration, not user data, and records/reads TurboSign_Log__c deploy outcomes.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getConfigDeployStatus(String jobId) {
        if (String.isBlank(jobId)) return new Map<String, Object>{ 'status' => 'Pending' };
        List<TurboSign_Log__c> logs = [
            SELECT Request_Summary__c, Error_Message__c
            FROM TurboSign_Log__c WHERE Deploy_Job_Id__c = :jobId ORDER BY CreatedDate DESC LIMIT 1];
        if (logs.isEmpty()) return new Map<String, Object>{ 'status' => 'Pending' };
        return new Map<String, Object>{ 'status' => logs[0].Request_Summary__c, 'error' => logs[0].Error_Message__c };
    }

    /** Existing children of `dev` whose fullName is not in `keepFullNames`, as Active__c = false records. */
    // Admin-only (TurboSign_Manage_Configuration custom permission): reads TurboSign custom metadata,
    // which is configuration, not user data, and records/reads TurboSign_Log__c deploy outcomes.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static List<Metadata.CustomMetadata> deactivationRecordsFor(String dev, Set<String> keepFullNames) {
        List<Metadata.CustomMetadata> out = new List<Metadata.CustomMetadata>();
        if (String.isBlank(dev)) return out;
        TurboSign_Config__mdt cfg = TurboSign_Config__mdt.getInstance(dev);
        if (cfg == null) return out; // new config — nothing pre-existing to deactivate
        Id cid = cfg.Id;

        Map<String, String> existing = new Map<String, String>(); // fullName -> label
        for (TurboSign_Variable_Mapping__mdt v : [SELECT DeveloperName, MasterLabel FROM TurboSign_Variable_Mapping__mdt WHERE Config__c = :cid])
            existing.put('TurboSign_Variable_Mapping.' + v.DeveloperName, v.MasterLabel);
        for (TurboSign_Recipient_Rule__mdt r : [SELECT DeveloperName, MasterLabel FROM TurboSign_Recipient_Rule__mdt WHERE Config__c = :cid])
            existing.put('TurboSign_Recipient_Rule.' + r.DeveloperName, r.MasterLabel);
        for (TurboSign_Field_Rule__mdt fr : [SELECT DeveloperName, MasterLabel FROM TurboSign_Field_Rule__mdt WHERE Config__c = :cid])
            existing.put('TurboSign_Field_Rule.' + fr.DeveloperName, fr.MasterLabel);

        for (String fullName : existing.keySet()) {
            if (keepFullNames.contains(fullName)) continue;
            Metadata.CustomMetadata md = record(fullName, existing.get(fullName));
            addVal(md, 'Config__c', dev);
            addVal(md, 'Active__c', false);
            out.add(md);
        }
        return out;
    }

    /** Read a config and re-serialize it as a save payload under a new name/label (the pure part of cloning). */
    @TestVisible
    private static String cloneToPayload(String sourceDeveloperName, String newDeveloperName, String newLabel) {
        Map<String, Object> src = getConfig(sourceDeveloperName);
        if (src == null || src.isEmpty()) throw new AuraHandledException('Config not found: ' + sourceDeveloperName);
        src.put('developerName', newDeveloperName);
        src.put('label', String.isBlank(newLabel) ? newDeveloperName : newLabel);
        return JSON.serialize(src);
    }

    /** Duplicate an existing config to a new API name, copying every mapping/recipient/anchor/setting. */
    @AuraEnabled
    public static Id cloneConfig(String sourceDeveloperName, String newDeveloperName, String newLabel) {
        requireConfigAdmin();
        if (String.isBlank(newDeveloperName)) throw new AuraHandledException('A new API name is required for the copy.');
        return saveConfig(cloneToPayload(sourceDeveloperName, newDeveloperName, newLabel));
    }

    /** Pure payload -> CMDT records. Testable without a callout or a deploy. */
    public static List<Metadata.CustomMetadata> buildMetadataRecords(String payloadJson) {
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        String dev = (String) p.get('developerName');
        String label = (String) p.get('label');
        List<Metadata.CustomMetadata> out = new List<Metadata.CustomMetadata>();

        // Config
        Metadata.CustomMetadata cfg = record('TurboSign_Config.' + dev, label);
        addVal(cfg, 'Source_SObject__c', p.get('sourceObject'));
        addVal(cfg, 'Active__c', true);
        addVal(cfg, 'Deliverable_Template_Id__c', p.get('templateId'));
        addVal(cfg, 'Document_Name_Template__c', p.get('documentName'));
        addVal(cfg, 'Date_Format__c', p.get('dateFormat'));
        addVal(cfg, 'Completion_Field__c', p.get('completionField'));
        addVal(cfg, 'Completion_Value__c', p.get('completionValue'));
        out.add(cfg);

        // Variable mappings
        Set<String> used = new Set<String>();
        for (Object o : listOf(p.get('variables'))) {
            Map<String, Object> v = (Map<String, Object>) o;
            if (String.isBlank((String) v.get('placeholder'))) continue; // skip empty rows -> no "null" junk record
            String ph = String.valueOf(v.get('placeholder'));
            String suffix = uniqueSuffix(dev, sanitize(ph), used);
            Metadata.CustomMetadata m = record('TurboSign_Variable_Mapping.' + suffix, ph);
            addVal(m, 'Config__c', dev);
            addVal(m, 'Active__c', true);
            addVal(m, 'Placeholder__c', ph);
            if (v.get('sourceField') != null) addVal(m, 'Source_Field_Path__c', v.get('sourceField'));
            if (v.get('defaultValue') != null) addVal(m, 'Default_Value__c', v.get('defaultValue'));
            addVal(m, 'Required__c', boolOf(v.get('required'), false));
            addVal(m, 'Mime_Type__c', v.get('mimeType') != null ? v.get('mimeType') : 'text');
            out.add(m);
        }

        // Recipients
        for (Object o : listOf(p.get('recipients'))) {
            Map<String, Object> r = (Map<String, Object>) o;
            if (String.isBlank((String) r.get('role'))) continue; // skip empty rows
            String role = String.valueOf(r.get('role'));
            String suffix = uniqueSuffix(dev, sanitize(role), used);
            Metadata.CustomMetadata m = record('TurboSign_Recipient_Rule.' + suffix, role);
            addVal(m, 'Config__c', dev);
            addVal(m, 'Active__c', true);
            addVal(m, 'Role_Label__c', role);
            addVal(m, 'Name_Field_Path__c', r.get('nameField'));
            addVal(m, 'Email_Field_Path__c', r.get('emailField'));
            addVal(m, 'Static_Name__c', r.get('staticName'));
            addVal(m, 'Static_Email__c', r.get('staticEmail'));
            addVal(m, 'Signing_Order__c', toInt(r.get('order'), 1));
            addVal(m, 'Required__c', boolOf(r.get('required'), true));
            out.add(m);
        }

        // Field rules (signature/date/etc. anchors)
        for (Object o : listOf(p.get('fields'))) {
            Map<String, Object> f = (Map<String, Object>) o;
            if (String.isBlank((String) f.get('anchor'))) continue; // skip empty rows
            String anchor = String.valueOf(f.get('anchor'));
            String suffix = uniqueSuffix(dev, sanitize(anchor), used);
            Metadata.CustomMetadata m = record('TurboSign_Field_Rule.' + suffix, anchor);
            addVal(m, 'Config__c', dev);
            addVal(m, 'Active__c', true);
            addVal(m, 'Anchor__c', anchor);
            addVal(m, 'Field_Type__c', f.get('type'));
            addVal(m, 'Recipient_Role_Label__c', f.get('role'));
            addVal(m, 'Placement__c', f.get('placement') != null ? f.get('placement') : 'replace');
            addVal(m, 'Required__c', boolOf(f.get('required'), false));
            out.add(m);
        }
        return out;
    }

    // ---- helpers ----
    private static Metadata.CustomMetadata record(String fullName, String label) {
        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = fullName;
        md.label = String.isBlank(label) ? fullName.substringAfter('.') : label.abbreviate(40);
        return md;
    }
    private static void addVal(Metadata.CustomMetadata md, String field, Object value) {
        if (value == null) return;
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field; v.value = value;
        md.values.add(v);
    }
    private static List<Object> listOf(Object o) {
        return (o instanceof List<Object>) ? (List<Object>) o : new List<Object>();
    }
    private static String sanitize(String s) {
        if (String.isBlank(s)) return 'X';
        String out = s.replaceAll('[^A-Za-z0-9]', '_').replaceAll('_+', '_');
        out = out.removeStart('_').removeEnd('_');
        if (String.isBlank(out)) out = 'X';
        if (!Pattern.matches('[A-Za-z].*', out)) out = 'X_' + out;
        return out;
    }
    private static String uniqueSuffix(String dev, String base, Set<String> used) {
        // CMDT DeveloperName (fullName after the dot) maxes out at 40 chars, so cap and keep unique.
        String stem = dev + '_' + base;
        String candidate = cap(stem, 40);
        Integer n = 1;
        while (used.contains(candidate)) {
            String tail = '_' + n;
            candidate = cap(stem, 40 - tail.length()) + tail;
            n++;
        }
        used.add(candidate);
        return candidate;
    }
    private static String cap(String s, Integer max) {
        return s.length() <= max ? s : s.substring(0, max).removeEnd('_');
    }
    private static Integer toInt(Object o, Integer dflt) {
        if (o == null) return dflt;
        try { return Integer.valueOf(String.valueOf(o)); } catch (Exception e) { return dflt; }
    }
    private static Boolean boolOf(Object o, Boolean dflt) {
        if (o == null) return dflt;
        if (o instanceof Boolean) return (Boolean) o;
        return Boolean.valueOf(String.valueOf(o));
    }

    // ---- v2: load an existing config back into the builder (edit) ----
    // Admin-only (TurboSign_Manage_Configuration custom permission): reads TurboSign custom metadata,
    // which is configuration, not user data, and records/reads TurboSign_Log__c deploy outcomes.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getConfig(String developerName) {
        TurboSign_Config__mdt c = TurboSign_Config__mdt.getInstance(developerName);
        if (c == null) return new Map<String, Object>();
        Id cid = c.Id;
        Map<String, Object> out = new Map<String, Object>{
            'developerName' => c.DeveloperName,
            'label'         => c.MasterLabel,
            'sourceObject'  => c.Source_SObject__c,
            'templateId'    => c.Deliverable_Template_Id__c,
            'documentName'  => c.Document_Name_Template__c,
            'dateFormat'    => c.Date_Format__c,
            'completionField' => c.Completion_Field__c,
            'completionValue' => c.Completion_Value__c
        };

        List<Object> vars = new List<Object>();
        for (TurboSign_Variable_Mapping__mdt v : [
                SELECT Placeholder__c, Source_Field_Path__c, Default_Value__c, Mime_Type__c, Required__c
                FROM TurboSign_Variable_Mapping__mdt WHERE Config__c = :cid AND Active__c = true]) {
            vars.add(new Map<String, Object>{
                'placeholder' => v.Placeholder__c, 'sourceField' => v.Source_Field_Path__c,
                'defaultValue' => v.Default_Value__c, 'mimeType' => v.Mime_Type__c, 'required' => v.Required__c });
        }
        out.put('variables', vars);

        List<Object> recips = new List<Object>();
        for (TurboSign_Recipient_Rule__mdt r : [
                SELECT Role_Label__c, Name_Field_Path__c, Email_Field_Path__c, Static_Name__c, Static_Email__c, Signing_Order__c, Required__c
                FROM TurboSign_Recipient_Rule__mdt WHERE Config__c = :cid AND Active__c = true ORDER BY Signing_Order__c]) {
            recips.add(new Map<String, Object>{
                'role' => r.Role_Label__c, 'nameField' => r.Name_Field_Path__c, 'emailField' => r.Email_Field_Path__c,
                'staticName' => r.Static_Name__c, 'staticEmail' => r.Static_Email__c,
                'order' => r.Signing_Order__c, 'required' => r.Required__c });
        }
        out.put('recipients', recips);

        List<Object> flds = new List<Object>();
        for (TurboSign_Field_Rule__mdt f : [
                SELECT Anchor__c, Field_Type__c, Recipient_Role_Label__c, Required__c, Placement__c
                FROM TurboSign_Field_Rule__mdt WHERE Config__c = :cid AND Active__c = true]) {
            flds.add(new Map<String, Object>{
                'anchor' => f.Anchor__c, 'type' => f.Field_Type__c,
                'role' => f.Recipient_Role_Label__c, 'required' => f.Required__c,
                'placement' => f.Placement__c });
        }
        out.put('fields', flds);
        return out;
    }

    // ---- v2: field options for the pickers (incl. single-target reference fields for path traversal) ----
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getFieldOptions(String objectApiName) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(objectApiName)) return out;
        // Scoped describe — not getGlobalDescribe(), which walks every object in the org.
        Schema.DescribeSObjectResult dsr;
        try {
            List<Schema.DescribeSObjectResult> results = Schema.describeSObjects(
                new List<String>{ objectApiName }, SObjectDescribeOptions.DEFERRED);
            if (results.isEmpty()) return out;
            dsr = results[0];
        } catch (Exception e) {
            return out; // unknown/invalid object name
        }
        if (!dsr.isAccessible()) return out; // CRUD/FLS: don't leak schema the running user can't see
        for (Schema.SObjectField sf : dsr.fields.getMap().values()) {
            Schema.DescribeFieldResult d = sf.getDescribe();
            if (!d.isAccessible()) continue; // per-field FLS
            Map<String, Object> f = new Map<String, Object>{
                'label' => d.getLabel(),
                'value' => d.getName(),
                'type' => String.valueOf(d.getType()),
                'updateable' => d.isUpdateable() };
            List<Schema.SObjectType> refs = d.getReferenceTo();
            // Only expand single-target lookups; polymorphic (Owner/What/Who) is ambiguous — leave flat.
            if (d.getType() == Schema.DisplayType.REFERENCE && refs.size() == 1) {
                f.put('isReference', true);
                f.put('referenceTo', refs[0].getDescribe().getName());
                f.put('relationshipName', d.getRelationshipName());
            }
            out.add(f);
        }
        return out;
    }

}
