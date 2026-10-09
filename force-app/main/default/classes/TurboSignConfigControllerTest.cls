@IsTest
private class TurboSignConfigControllerTest {

    private static String samplePayload() {
        return '{'
            + '"developerName":"Test_Config","label":"Test Config","sourceObject":"Opportunity",'
            + '"templateId":"tpl-123","documentName":"Agreement","dateFormat":"MMMM d, yyyy",'
            + '"completionField":"StageName","completionValue":"Closed Won",'
            + '"variables":[{"placeholder":"{ClientName}","sourceField":"Account.Name"},'
            + '{"placeholder":"{EffectiveDate}","defaultValue":"Aug 17, 2026"}],'
            + '"recipients":[{"role":"Client","nameField":"Owner.Name","emailField":"Owner.Email","order":1,"required":true}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"Client","required":true},'
            + '{"anchor":"{date}","type":"date","role":"Client","required":false}]'
            + '}';
    }

    @IsTest
    static void validateConfigFlagsTheCommonMistakes() {
        // Missing template, a placeholder with no field, a duplicate role + order, and an anchor whose role
        // has no recipient — all should be reported.
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"",'
            + '"variables":[{"placeholder":"{Name}","sourceField":"Account.Name"},{"placeholder":"{City}"}],'
            + '"recipients":[{"role":"Client","nameField":"Owner.Name","emailField":"Owner.Email","order":1},'
            + '{"role":"Client","nameField":"Owner.Name","emailField":"Owner.Email","order":1}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"Witness"}]}';
        List<String> issues = TurboSignConfigController.validateConfig(payload, new List<String>{ '{Name}', '{City}' });
        String all = String.join(issues, ' | ');
        System.assert(all.containsIgnoreCase('template'), 'missing template flagged: ' + all);
        System.assert(all.contains('{City}'), 'unmapped placeholder flagged');
        System.assert(all.contains('share the same internal id') && all.contains('Client'), 'duplicate role flagged');
        System.assert(all.containsIgnoreCase('order'), 'duplicate signing order flagged');
        System.assert(all.contains('Witness'), 'anchor role with no recipient flagged');
    }

    @IsTest
    static void previewPayloadResolvesMappingsAgainstARecord() {
        Account a = new Account(Name = 'Acme Preview');
        insert a;
        Opportunity o = new Opportunity(Name = 'Prev Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(10), AccountId = a.Id);
        insert o;
        String payload = '{"variables":[{"placeholder":"{ClientName}","sourceField":"Account.Name"},'
            + '{"placeholder":"{Note}","defaultValue":"Static text"}]}';
        List<Object> rows = TurboSignConfigController.previewPayload(o.Id, payload);
        Map<String, String> byPh = new Map<String, String>();
        for (Object ro : rows) { Map<String, Object> r = (Map<String, Object>) ro; byPh.put((String) r.get('placeholder'), (String) r.get('value')); }
        System.assertEquals('Acme Preview', byPh.get('{ClientName}'), 'field mapping resolves live from the record');
        System.assertEquals('Static text', byPh.get('{Note}'), 'a default value shows when there is no field mapping');
    }

    @IsTest
    static void bestFieldMatchPicksTheClosestFieldByLabel() {
        List<Map<String, Object>> opts = new List<Map<String, Object>>{
            new Map<String, Object>{ 'label' => 'Full Name (Name)', 'value' => 'X.Name' },
            new Map<String, Object>{ 'label' => 'Email (Email)', 'value' => 'X.Email' },
            new Map<String, Object>{ 'label' => 'First Name (FirstName)', 'value' => 'X.FirstName' }
        };
        System.assertEquals('X.Email', TurboSignConfigController.bestFieldMatch('Email', opts), 'email token matches the email field');
        System.assertEquals('X.FirstName', TurboSignConfigController.bestFieldMatch('First Name', opts), 'first name matches FirstName over Full Name');
        System.assertEquals('', TurboSignConfigController.bestFieldMatch('Zzz Nonsense', opts), 'no overlap -> no suggestion');
        System.assertEquals('', TurboSignConfigController.bestFieldMatch('Email', new List<Map<String, Object>>()), 'no options -> blank');
    }

    @IsTest
    static void validateConfigPassesACleanConfig() {
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"tpl-1",'
            + '"variables":[{"placeholder":"{Name}","sourceField":"Account.Name"}],'
            + '"recipients":[{"role":"Client","nameField":"Owner.Name","emailField":"Owner.Email","order":1}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"Client"}]}';
        System.assertEquals(0, TurboSignConfigController.validateConfig(payload, new List<String>{ '{Name}' }).size(),
            'a well-formed config has no issues');
    }

    @IsTest
    static void getTemplatePlaceholdersReturnsTemplateTokens() {
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());
        Test.startTest();
        List<String> phs = TurboSignConfigController.getTemplatePlaceholders('tpl-1');
        Test.stopTest();
        // The builder pre-fills a mapping row per placeholder the template already declares.
        System.assertEquals(new List<String>{ '{ClientName}', '{EffectiveDate}' }, phs,
            'placeholders come straight from the template detail so the admin need not retype them');
    }

    @IsTest
    static void getPicklistValuesConstrainsPicklistFieldsOnly() {
        // A picklist field (StageName) returns its values, so the completion value is a dropdown.
        List<Map<String, Object>> stages = TurboSignConfigController.getPicklistValues('Opportunity', 'StageName');
        System.assert(!stages.isEmpty(), 'StageName is a picklist -> values returned');
        Set<String> vals = new Set<String>();
        for (Map<String, Object> s : stages) vals.add(String.valueOf(s.get('value')));
        System.assert(vals.contains('Closed Won'), 'standard stage value present');
        // A non-picklist field returns nothing, so the UI falls back to free text.
        System.assertEquals(0, TurboSignConfigController.getPicklistValues('Opportunity', 'Name').size(),
            'Name is text -> no constraint, free-form entry');
        // Blank / unknown inputs are safe.
        System.assertEquals(0, TurboSignConfigController.getPicklistValues('', 'StageName').size());
        System.assertEquals(0, TurboSignConfigController.getPicklistValues('Opportunity', 'Not_A_Field__c').size());
    }

    @IsTest
    static void deactivationTurnsConfigAndChildrenInactive() {
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildDeactivation('Example_Agreement');
        System.assert(!recs.isEmpty(), 'deactivation records built for an existing config');
        Metadata.CustomMetadata cfg = byFullName(recs, 'TurboSign_Config.Example_Agreement');
        System.assertNotEquals(null, cfg, 'the config record is included');
        System.assertEquals(false, val(cfg, 'Active__c'), 'config is deactivated so it leaves the picker');
        Metadata.CustomMetadata child = byFullName(recs, 'TurboSign_Variable_Mapping.');
        System.assertNotEquals(null, child, 'children are included');
        System.assertEquals(false, val(child, 'Active__c'), 'children are deactivated too');
    }

    @IsTest
    static void deriveApiNameFromLabelProducesAValidName() {
        System.assertEquals('Senior_Living_Lease', TurboSignConfigController.deriveApiName('Senior Living Lease'),
            'spaces become underscores');
        System.assertEquals('Weird_Name', TurboSignConfigController.deriveApiName('  Weird--Name__ '),
            'punctuation collapses, no leading/trailing underscores');
        System.assert(TurboSignConfigController.deriveApiName('123 Contract').startsWith('X'),
            'a name must start with a letter');
        System.assertEquals('X', TurboSignConfigController.deriveApiName(''), 'blank label -> safe placeholder');
    }

    @IsTest
    static void childDeveloperNamesRespectFortyCharLimit() {
        // A long config name plus long child identifiers must not blow the CMDT fullName 40-char cap
        // (this is what made a duplicate to a longer name fail to deploy).
        String payload = '{"developerName":"Senior_Living_Lease_ES","label":"x","sourceObject":"Opportunity","templateId":"t",'
            + '"variables":[{"placeholder":"{ResponsiblePartyName}","sourceField":"Primary_Contact__r.Name"}],'
            + '"recipients":[{"role":"Facility Representative","nameField":"Owner.Name","emailField":"Owner.Email","order":1}],'
            + '"fields":[{"anchor":"{facility_sig}","type":"signature","role":"Facility Representative"}]}';
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildMetadataRecords(payload);
        for (Metadata.CustomMetadata m : recs) {
            String devName = m.fullName.substringAfter('.');
            System.assert(devName.length() <= 40, 'child dev name within 40: ' + devName + ' (' + devName.length() + ')');
        }
    }

    @IsTest
    static void cloneToPayloadRenamesAndCopiesEverything() {
        // Clone the org's Example_Agreement config under a new name.
        String payload = TurboSignConfigController.cloneToPayload('Example_Agreement', 'Cloned_Agreement', 'Cloned Agreement');
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payload);
        System.assertEquals('Cloned_Agreement', p.get('developerName'), 'new API name');
        System.assertEquals('Cloned Agreement', p.get('label'), 'new label');
        System.assertNotEquals(null, p.get('templateId'), 'template carried over from the source');

        // Building the clone payload yields a config under the new name with children re-parented to it.
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildMetadataRecords(payload);
        System.assertNotEquals(null, byFullName(recs, 'TurboSign_Config.Cloned_Agreement'), 'config built under the new name');
        Metadata.CustomMetadata vm = byFullName(recs, 'TurboSign_Variable_Mapping.');
        System.assertNotEquals(null, vm, 'the copy has the source variable mappings');
        System.assertEquals('Cloned_Agreement', val(vm, 'Config__c'), 'children reference the clone, not the source');
    }

    @IsTest
    static void getObjectOptionsListsBusinessObjectsNotSystemOnes() {
        List<Map<String, Object>> opts = TurboSignConfigController.getObjectOptions();
        System.assert(!opts.isEmpty(), 'returns selectable objects');
        Set<String> apis = new Set<String>();
        for (Map<String, Object> o : opts) apis.add(String.valueOf(o.get('value')));
        System.assert(apis.contains('Opportunity'), 'a real business object is selectable instead of free text');
        for (String a : apis) {
            System.assert(!a.endsWith('__mdt') && !a.endsWithIgnoreCase('Share') && !a.endsWithIgnoreCase('History')
                && !a.endsWithIgnoreCase('Feed'), 'system shadow objects are filtered out: ' + a);
        }
    }

    @IsTest
    static void checkTemplateAnchorsReportsFoundAndMissing() {
        Test.setMock(HttpCalloutMock.class, new TurboSignRouterMock());
        Test.startTest();
        List<Object> rep = TurboSignConfigController.checkTemplateAnchors('tpl-1', new List<String>{ '{sig}', '{date}' });
        Test.stopTest();
        System.assertEquals(2, rep.size(), 'a result per anchor');
        Map<String, Object> a0 = (Map<String, Object>) rep[0];
        System.assertEquals('{sig}', a0.get('anchor'));
        System.assertEquals(true, a0.get('found'), 'sig is present in the template');
        Map<String, Object> a1 = (Map<String, Object>) rep[1];
        System.assertEquals(false, a1.get('found'), 'date is flagged missing so the admin fixes it before saving');
    }

    @IsTest
    static void getTemplatePlaceholdersBlankIdIsEmpty() {
        System.assertEquals(0, TurboSignConfigController.getTemplatePlaceholders('').size(), 'no template -> nothing to prefill');
    }

    @IsTest
    static void validateConfigFlagsBlankRoleAnchorLongNameAndBadCompletionField() {
        String longName = 'A';
        for (Integer i = 0; i < 40; i++) longName += 'A'; // 41 chars -> over the CMDT fullName cap
        String payload = '{"developerName":"' + longName + '","label":"x","sourceObject":"Opportunity","templateId":"t",'
            + '"completionField":"Not_A_Real_Field__c",'
            + '"variables":[],'
            + '"recipients":[{"role":"Signer","order":1}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":""}]}';
        List<String> issues = TurboSignConfigController.validateConfig(payload, new List<String>());
        String all = String.join(issues, ' | ');
        System.assert(all.containsIgnoreCase('no recipient role'), 'blank-role anchor flagged: ' + all);
        System.assert(all.contains('40 characters'), 'over-long API name flagged: ' + all);
        System.assert(all.containsIgnoreCase('Completion field') && all.contains('Not_A_Real_Field__c'),
            'nonexistent completion field flagged: ' + all);
    }

    @IsTest
    static void validateConfigFlagsASignerWithNoField() {
        // signer_1 has a signature field; signer_2 has none -> only signer_2 is flagged.
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"t",'
            + '"variables":[],'
            + '"recipients":[{"role":"signer_1","nameField":"Account.Name","order":1},{"role":"signer_2","nameField":"Owner.Name","order":2}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"signer_1"}]}';
        List<String> issues = TurboSignConfigController.validateConfig(payload, new List<String>());
        String all = String.join(issues, ' | ');
        System.assert(all.containsIgnoreCase('no required signature field'), 'a signer with no field is flagged: ' + all);
        System.assert(all.contains('Signer 2'), 'the fieldless signer is named by position: ' + all);
        System.assert(!all.contains('Signer 1 has'), 'the signer that has a field is not flagged: ' + all);
    }

    @IsTest
    static void previewPayloadFallsBackToDefaultWhenFieldResolvesNull() {
        Account a = new Account(Name = 'Acme'); insert a;
        Opportunity o = new Opportunity(Name = 'Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(5), AccountId = a.Id);
        insert o;
        // Description is a real, readable field but null on this record -> preview shows the default, like the send.
        String payload = '{"variables":[{"placeholder":"{Desc}","sourceField":"Description","defaultValue":"Fallback text"}]}';
        List<Object> rows = TurboSignConfigController.previewPayload(o.Id, payload);
        Map<String, String> byPh = new Map<String, String>();
        for (Object ro : rows) { Map<String, Object> r = (Map<String, Object>) ro; byPh.put((String) r.get('placeholder'), (String) r.get('value')); }
        System.assertEquals('Fallback text', byPh.get('{Desc}'), 'a mapped field that resolves null falls back to the default');
    }

    @IsTest
    static void buildMetadataRecordsSkipsEmptyRows() {
        // Rows with the identifying key absent (placeholder/role/anchor) must not persist a "null" junk record.
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"t",'
            + '"variables":[{"placeholder":"{Real}","sourceField":"Account.Name"},{"sourceField":"Account.Name"}],'
            + '"recipients":[{"role":"Signer","order":1},{"order":2}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"Signer"},{"type":"date"}]}';
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildMetadataRecords(payload);
        Integer vmCount = 0, rrCount = 0, frCount = 0;
        for (Metadata.CustomMetadata m : recs) {
            if (m.fullName.startsWith('TurboSign_Variable_Mapping.')) vmCount++;
            else if (m.fullName.startsWith('TurboSign_Recipient_Rule.')) rrCount++;
            else if (m.fullName.startsWith('TurboSign_Field_Rule.')) frCount++;
        }
        // Only the one real row of each type survives; the key-less empty rows build no shell record.
        System.assertEquals(1, vmCount, 'empty variable row produced no shell record');
        System.assertEquals(1, rrCount, 'empty recipient row produced no shell record');
        System.assertEquals(1, frCount, 'empty field row produced no shell record');
        System.assertNotEquals(null, byFullName(recs, 'TurboSign_Variable_Mapping.'), 'the real variable row is still built');
    }

    // The gate is the first statement in each method, so any throw from a non-permitted user is the gate.
    // (AuraHandledException.getMessage() is opaque in tests, so we assert on the throw, not its text.)
    @IsTest
    static void requireConfigAdminGatesOnTheCustomPermission() {
        User u = TurboSignTestRep.user();
        System.runAs(u) {
            Boolean blocked = false;
            try { TurboSignConfigController.requireConfigAdmin(); }
            catch (Exception e) { blocked = true; }
            System.assert(blocked, 'a user without the custom permission is blocked');
        }
        grantConfigAdmin(u.Id);
        System.runAs(u) {
            Boolean threw = false;
            try { TurboSignConfigController.requireConfigAdmin(); } // granted -> must not throw
            catch (Exception e) { threw = true; }
            System.assert(!threw, 'a user with the custom permission passes the gate');
        }
    }

    @IsTest
    static void saveConfigRequiresConfigAdminPermission() {
        User u = TurboSignTestRep.user();
        System.runAs(u) {
            Boolean blocked = false;
            try { TurboSignConfigController.saveConfig(samplePayload()); }
            catch (Exception e) { blocked = true; }
            System.assert(blocked, 'saveConfig is gated by the config-admin permission');
        }
    }

    @IsTest
    static void deactivateAndCloneRequireConfigAdminPermission() {
        User u = TurboSignTestRep.user();
        System.runAs(u) {
            Boolean deBlocked = false, clBlocked = false;
            try { TurboSignConfigController.deactivateConfig('Example_Agreement'); }
            catch (Exception e) { deBlocked = true; }
            try { TurboSignConfigController.cloneConfig('Example_Agreement', 'Nope_Copy', 'x'); }
            catch (Exception e) { clBlocked = true; }
            System.assert(deBlocked, 'deactivateConfig is gated');
            System.assert(clBlocked, 'cloneConfig is gated');
        }
    }

    private static void grantConfigAdmin(Id userId) {
        PermissionSet ps = new PermissionSet(Name = 'TS_Cfg_Admin_Test', Label = 'TS Cfg Admin Test');
        insert ps;
        CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'TurboSign_Manage_Configuration' LIMIT 1];
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
    }

    private static Object val(Metadata.CustomMetadata md, String field) {
        for (Metadata.CustomMetadataValue v : md.values) {
            if (v.field == field) return v.value;
        }
        return null;
    }
    private static Metadata.CustomMetadata byFullName(List<Metadata.CustomMetadata> recs, String prefix) {
        for (Metadata.CustomMetadata m : recs) { if (m.fullName.startsWith(prefix)) return m; }
        return null;
    }

    @IsTest
    static void buildsFullCmdtGraphFromPayload() {
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildMetadataRecords(samplePayload());

        // 1 config + 2 variable mappings + 1 recipient + 2 field rules = 6
        System.assertEquals(6, recs.size(), 'full CMDT graph built');

        Metadata.CustomMetadata cfg = byFullName(recs, 'TurboSign_Config.Test_Config');
        System.assertNotEquals(null, cfg, 'config record present');
        System.assertEquals('Opportunity', val(cfg, 'Source_SObject__c'));
        System.assertEquals('tpl-123', val(cfg, 'Deliverable_Template_Id__c'));
        System.assertEquals(true, val(cfg, 'Active__c'));
        System.assertEquals('StageName', val(cfg, 'Completion_Field__c'), 'completion field written');
        System.assertEquals('Closed Won', val(cfg, 'Completion_Value__c'), 'completion value written');
        System.assertEquals('MMMM d, yyyy', val(cfg, 'Date_Format__c'), 'date format written so the builder no longer blanks it on save');

        Metadata.CustomMetadata vm = byFullName(recs, 'TurboSign_Variable_Mapping.Test_Config');
        System.assertNotEquals(null, vm, 'variable mapping present');
        System.assertEquals('Test_Config', val(vm, 'Config__c'), 'child references config by developer name');
        System.assertEquals(true, val(vm, 'Active__c'), 'new children are active');

        Metadata.CustomMetadata rr = byFullName(recs, 'TurboSign_Recipient_Rule.Test_Config');
        System.assertNotEquals(null, rr, 'recipient rule present');
        System.assertEquals('Owner.Email', val(rr, 'Email_Field_Path__c'));
        System.assertEquals('Client', val(rr, 'Role_Label__c'));

        Metadata.CustomMetadata fr = byFullName(recs, 'TurboSign_Field_Rule.Test_Config');
        System.assertNotEquals(null, fr, 'field rule present');
        System.assertEquals('{sig}', val(fr, 'Anchor__c'));
        System.assertEquals('signature', val(fr, 'Field_Type__c'));
        System.assertEquals('Client', val(fr, 'Recipient_Role_Label__c'));
    }

    @IsTest
    static void sanitizesDeveloperNames() {
        // Field rules keyed by sanitized anchor — {sig} -> sig, {date} -> date; must be unique + valid
        List<Metadata.CustomMetadata> recs = TurboSignConfigController.buildMetadataRecords(samplePayload());
        Set<String> names = new Set<String>();
        for (Metadata.CustomMetadata m : recs) {
            String dn = m.fullName.substringAfter('.');
            System.assert(Pattern.matches('[A-Za-z][A-Za-z0-9_]*', dn), 'valid CMDT dev name: ' + dn);
            System.assert(!names.contains(m.fullName), 'unique fullName: ' + m.fullName);
            names.add(m.fullName);
        }
    }

    // ---- v2: getConfig (load an existing config back into the builder) ----
    @IsTest
    static void getConfigReadsTheCmdtGraphBack() {
        Map<String, Object> cfg = TurboSignConfigController.getConfig('Example_Agreement');
        System.assertEquals('Example_Agreement', cfg.get('developerName'));
        System.assertEquals('Opportunity', cfg.get('sourceObject'));
        System.assertNotEquals(null, cfg.get('templateId'), 'template id present');
        System.assert(cfg.containsKey('completionField'), 'completion field surfaced for edit');
        System.assert(cfg.containsKey('completionValue'), 'completion value surfaced for edit');

        List<Object> vars = (List<Object>) cfg.get('variables');
        System.assert(vars.size() >= 2, 'variable mappings loaded');
        Boolean foundClientName = false;
        for (Object o : vars) {
            Map<String, Object> v = (Map<String, Object>) o;
            if (v.get('placeholder') == '{ClientName}') { foundClientName = true; System.assertEquals('Account.Name', v.get('sourceField')); }
        }
        System.assert(foundClientName, 'ClientName mapping round-tripped');

        List<Object> recips = (List<Object>) cfg.get('recipients');
        System.assertEquals(1, recips.size());
        System.assertEquals('Owner.Email', ((Map<String, Object>) recips[0]).get('emailField'));
        System.assertEquals('Signer', ((Map<String, Object>) recips[0]).get('role'));

        List<Object> flds = (List<Object>) cfg.get('fields');
        Boolean foundSig = false;
        for (Object o : flds) {
            Map<String, Object> f = (Map<String, Object>) o;
            if (f.get('anchor') == '{sig}') { foundSig = true; System.assertEquals('signature', f.get('type')); System.assertEquals('Signer', f.get('role')); }
        }
        System.assert(foundSig, 'signature field rule round-tripped');
    }

    // Saving the example in TurboSign Setup must overwrite the deployed records, not add a second set
    // beside them. So the deployed records carry exactly the names, labels and values Setup writes for
    // the same setup. The payload is written out here, not read back from the org, so it is an
    // independent statement of the example's shape.
    @IsTest
    static void exampleRecordsAreExactlyWhatTurboSignSetupWrites() {
        String payload = JSON.serialize(new Map<String, Object>{
            'developerName' => 'Example_Agreement', 'label' => 'Example Agreement',
            'sourceObject' => 'Opportunity', 'templateId' => 'REPLACE_WITH_YOUR_TEMPLATE_ID',
            'documentName' => 'Service Agreement',
            'variables' => new List<Object>{
                new Map<String, Object>{ 'placeholder' => '{ClientName}', 'sourceField' => 'Account.Name', 'mimeType' => 'text' },
                new Map<String, Object>{ 'placeholder' => '{EffectiveDate}', 'sourceField' => 'CloseDate', 'mimeType' => 'text' } },
            'recipients' => new List<Object>{
                new Map<String, Object>{ 'role' => 'Signer', 'nameField' => 'Owner.Name', 'emailField' => 'Owner.Email',
                    'order' => 1, 'required' => true } },
            'fields' => new List<Object>{
                new Map<String, Object>{ 'anchor' => '{sig}', 'type' => 'signature', 'role' => 'Signer', 'required' => true, 'placement' => 'replace' },
                new Map<String, Object>{ 'anchor' => '{date}', 'type' => 'date', 'role' => 'Signer', 'required' => false, 'placement' => 'replace' } }
        });
        List<Metadata.CustomMetadata> expected = TurboSignConfigController.buildMetadataRecords(payload);

        Map<String, Set<String>> deployedByType = new Map<String, Set<String>>{
            'TurboSign_Variable_Mapping' => exampleChildNames([SELECT DeveloperName, Active__c FROM TurboSign_Variable_Mapping__mdt
                WHERE Config__r.DeveloperName = 'Example_Agreement']),
            'TurboSign_Recipient_Rule' => exampleChildNames([SELECT DeveloperName, Active__c FROM TurboSign_Recipient_Rule__mdt
                WHERE Config__r.DeveloperName = 'Example_Agreement']),
            'TurboSign_Field_Rule' => exampleChildNames([SELECT DeveloperName, Active__c FROM TurboSign_Field_Rule__mdt
                WHERE Config__r.DeveloperName = 'Example_Agreement']) };

        Map<String, Set<String>> expectedByType = new Map<String, Set<String>>{
            'TurboSign_Variable_Mapping' => new Set<String>(), 'TurboSign_Recipient_Rule' => new Set<String>(),
            'TurboSign_Field_Rule' => new Set<String>() };
        for (Metadata.CustomMetadata md : expected) {
            String type = md.fullName.substringBefore('.');
            if (expectedByType.containsKey(type)) expectedByType.get(type).add(md.fullName.substringAfter('.'));
        }
        System.assertEquals(expectedByType, deployedByType, 'the deployed children are the ones Setup writes, and no others');

        Set<String> types = new Set<String>();
        for (Metadata.CustomMetadata md : expected) types.add(md.fullName.substringBefore('.') + '__mdt');
        Map<String, Map<String, Schema.SObjectField>> fieldsByType = new Map<String, Map<String, Schema.SObjectField>>();
        for (Schema.DescribeSObjectResult d : Schema.describeSObjects(new List<String>(types)))
            fieldsByType.put(d.getName(), d.fields.getMap());
        for (Metadata.CustomMetadata md : expected)
            assertDeployedMatches(md, fieldsByType.get(md.fullName.substringBefore('.') + '__mdt'));
    }

    // TurboSign Setup deactivates a row it no longer needs and never deletes it, and a deploy of the
    // example does not delete it either. So an admin who added a field to the example in Setup and took
    // it out again leaves an inactive row behind, which must not fail the next deploy's tests.
    @IsTest
    static void exampleChildNamesIgnoreInactiveRows() {
        List<TurboSign_Field_Rule__mdt> rows = (List<TurboSign_Field_Rule__mdt>) JSON.deserialize(
            '[{"DeveloperName":"Example_Agreement_sig","Active__c":true},'
            + '{"DeveloperName":"Example_Agreement_initials","Active__c":false}]',
            List<TurboSign_Field_Rule__mdt>.class);
        System.assertEquals(new Set<String>{ 'Example_Agreement_sig' }, exampleChildNames(rows),
            'only active rows count');
    }

    /** The names of the example's active child records; Setup deactivates rows, it never deletes them. */
    private static Set<String> exampleChildNames(List<SObject> rows) {
        Set<String> names = new Set<String>();
        for (SObject r : rows) if (r.get('Active__c') == true) names.add((String) r.get('DeveloperName'));
        return names;
    }

    /** The deployed record named md.fullName has md's label and values, and defaults for what Setup leaves out. */
    private static void assertDeployedMatches(Metadata.CustomMetadata md, Map<String, Schema.SObjectField> fields) {
        String sobj = md.fullName.substringBefore('.') + '__mdt';
        String dev = md.fullName.substringAfter('.');
        List<String> custom = new List<String>();
        Map<String, Object> defaults = new Map<String, Object>();
        for (Schema.SObjectField f : fields.values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isCustom()) { custom.add(d.getName()); defaults.put(d.getName(), d.getDefaultValue()); }
        }
        String q = 'SELECT MasterLabel, ' + String.join(custom, ', ')
            + (custom.contains('Config__c') ? ', Config__r.DeveloperName' : '')
            + ' FROM ' + sobj + ' WHERE DeveloperName = :dev';
        List<SObject> rows = Database.query(q);
        System.assertEquals(1, rows.size(), md.fullName + ' is deployed');
        SObject row = rows[0];
        System.assertEquals(md.label, row.get('MasterLabel'), md.fullName + ' label');

        Map<String, Object> written = new Map<String, Object>();
        for (Metadata.CustomMetadataValue v : md.values) written.put(v.field, v.value);
        System.assertEquals(true, written.get('Active__c'), md.fullName + ': Setup writes Active__c');
        for (String f : custom) {
            Object actual = f == 'Config__c' ? row.getSObject('Config__r').get('DeveloperName') : row.get(f);
            if (!written.containsKey(f)) {
                // Setup leaves the field out, so its deploy gets the field's default (or nothing).
                Object dflt = defaults.get(f);
                System.assert(actual == null || actual == dflt || (dflt == null && actual == false),
                    md.fullName + '.' + f + ' is ' + actual + ', but Setup leaves it out (default ' + dflt + ')');
            } else if (actual instanceof Decimal) {
                System.assertEquals(Decimal.valueOf(String.valueOf(written.get(f))), (Decimal) actual, md.fullName + '.' + f);
            } else {
                System.assertEquals(written.get(f), actual, md.fullName + '.' + f);
            }
        }
    }

    // ---- v2: getFieldOptions (drives the field pickers incl. reference traversal) ----
    @IsTest
    static void getFieldOptionsReturnsFieldsAndReferences() {
        List<Map<String, Object>> fields = TurboSignConfigController.getFieldOptions('Opportunity');
        System.assert(!fields.isEmpty(), 'fields returned');
        Boolean foundStage = false, foundAccountRef = false;
        for (Map<String, Object> f : fields) {
            if (f.get('value') == 'StageName') foundStage = true;
            if (f.get('value') == 'AccountId') {
                foundAccountRef = true;
                System.assertEquals(true, f.get('isReference'), 'AccountId is a reference');
                System.assertEquals('Account', f.get('referenceTo'), 'AccountId points to Account');
                System.assertEquals('Account', f.get('relationshipName'), 'relationship name for path building');
            }
        }
        System.assert(foundStage, 'plain field present');
        System.assert(foundAccountRef, 'reference field present with target for path traversal');
    }

    // ---- #7: async deploy status is logged and readable ----
    @IsTest
    static void deployStatusIsLoggedAndReadable() {
        TurboSignConfigController.logDeployResult('0AfTESTJOB000001', 'Failed', new List<String>{ 'TurboSign_Config.X: boom' });
        Map<String, Object> s = TurboSignConfigController.getConfigDeployStatus('0AfTESTJOB000001');
        System.assertEquals('Failed', s.get('status'));
        System.assert(String.valueOf(s.get('error')).contains('boom'), 'error surfaced to the caller');
    }

    @IsTest
    static void deployStatusUnknownJobIsPending() {
        System.assertEquals('Pending', TurboSignConfigController.getConfigDeployStatus('0AfNOPE000000001').get('status'));
        System.assertEquals('Pending', TurboSignConfigController.getConfigDeployStatus('').get('status'));
    }

    // ---- #1: editing a config deactivates children no longer in the payload ----
    @IsTest
    static void deactivatesOrphanedChildrenNotInNewPayload() {
        // Example_Agreement has existing children; an empty keep-set marks them all for deactivation.
        List<Metadata.CustomMetadata> deact = TurboSignConfigController.deactivationRecordsFor('Example_Agreement', new Set<String>());
        System.assert(!deact.isEmpty(), 'existing children scheduled for deactivation');
        for (Metadata.CustomMetadata md : deact) {
            System.assertEquals(false, val(md, 'Active__c'), md.fullName + ' deactivated');
        }
        // Keeping them all deactivates nothing.
        Set<String> keepAll = new Set<String>();
        for (Metadata.CustomMetadata md : deact) keepAll.add(md.fullName);
        System.assertEquals(0, TurboSignConfigController.deactivationRecordsFor('Example_Agreement', keepAll).size(),
            'nothing deactivated when every existing child is kept');
    }

    @IsTest
    static void deactivationForUnknownConfigIsEmpty() {
        System.assertEquals(0, TurboSignConfigController.deactivationRecordsFor('No_Such_Config', new Set<String>()).size());
    }

    @IsTest
    static void getFieldOptionsFlagsUpdateability() {
        Map<String, Object> byName = fieldsByName('Opportunity');
        System.assertEquals(true, ((Map<String, Object>) byName.get('StageName')).get('updateable'), 'writable field flagged updateable');
        System.assertEquals(false, ((Map<String, Object>) byName.get('CreatedDate')).get('updateable'), 'system field flagged non-updateable');
    }

    @IsTest
    static void getFieldOptionsDoesNotExpandPolymorphicReferences() {
        // Task.WhatId references many objects — ambiguous, must NOT be expanded as a single relationship path
        Map<String, Object> byName = fieldsByName('Task');
        Map<String, Object> whatId = (Map<String, Object>) byName.get('WhatId');
        System.assertNotEquals(null, whatId, 'WhatId present');
        System.assertNotEquals(true, whatId.get('isReference'), 'polymorphic WhatId not expanded');
    }

    @IsTest
    static void getConfigUnknownDeveloperNameReturnsEmpty() {
        System.assertEquals(true, TurboSignConfigController.getConfig('No_Such_Config').isEmpty(), 'unknown config -> empty map');
    }

    @IsTest
    static void listConfigsReturnsActiveConfigsForObject() {
        List<Map<String, Object>> cfgs = TurboSignConfigController.listConfigs('Opportunity');
        Boolean foundExample = false;
        for (Map<String, Object> c : cfgs) if (c.get('value') == 'Example_Agreement') foundExample = true;
        System.assert(foundExample, 'active Opportunity config listed');
        // an object with no configs returns empty, not an error
        System.assertEquals(0, TurboSignConfigController.listConfigs('Contact').size(), 'no configs for object -> empty');
    }

    @IsTest
    static void getFieldOptionsUnknownObjectReturnsEmpty() {
        System.assertEquals(0, TurboSignConfigController.getFieldOptions('No_Such_Object__x').size(), 'unknown object -> empty, no exception');
        System.assertEquals(0, TurboSignConfigController.getFieldOptions('').size(), 'blank object -> empty');
    }

    private static Map<String, Object> fieldsByName(String obj) {
        Map<String, Object> m = new Map<String, Object>();
        for (Map<String, Object> f : TurboSignConfigController.getFieldOptions(obj)) m.put((String) f.get('value'), f);
        return m;
    }


    // Review: a signing token that sits in the template as text ({sig}) counts as mapped.
    @IsTest
    static void signingTokenInTheTemplateCountsAsMapped() {
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"tpl-1",'
            + '"variables":[{"placeholder":"{Name}","sourceField":"Account.Name"}],'
            + '"recipients":[{"role":"Client","nameField":"Owner.Name","emailField":"Owner.Email","order":1}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"Client","required":true}]}';
        System.assertEquals(0, TurboSignConfigController.validateConfig(payload, new List<String>{ '{Name}', '{sig}' }).size(),
            '{sig} is placed as a signing field, so it is not an unmapped placeholder');
    }

    // Review: only required fields give a signer somewhere to sign; signature/initial can't be optional.
    @IsTest
    static void optionalSignatureAndOptionalOnlySignerAreFlagged() {
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"tpl-1",'
            + '"variables":[],'
            + '"recipients":[{"role":"A","nameField":"Owner.Name","emailField":"Owner.Email","order":1},'
            + '{"role":"B","nameField":"Owner.Name","emailField":"Owner.Email","order":2}],'
            + '"fields":[{"anchor":"{sigA}","type":"signature","role":"A","required":false},'
            + '{"anchor":"{boxB}","type":"checkbox","role":"B","required":false}]}';
        String all = String.join(TurboSignConfigController.validateConfig(payload, new List<String>()), ' | ');
        System.assert(all.contains('{sigA}') && all.contains('optional'), 'optional signature flagged, got: ' + all);
        System.assert(all.contains('Signer 2'), 'a signer with only optional fields has nowhere to sign, got: ' + all);
    }

    @IsTest
    static void invalidDateFormatIsFlagged() {
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"tpl-1",'
            + '"dateFormat":"yyyy-MM-ddTHH:mm","variables":[],'
            + '"recipients":[{"role":"A","nameField":"Owner.Name","emailField":"Owner.Email","order":1}],'
            + '"fields":[{"anchor":"{sig}","type":"signature","role":"A"}]}';
        String all = String.join(TurboSignConfigController.validateConfig(payload, new List<String>()), ' | ');
        System.assert(all.contains('Date format'), 'bad pattern flagged before save, got: ' + all);
    }

    @IsTest
    static void variableRequiredFlagIsSaved() {
        String payload = '{"developerName":"C","label":"C","sourceObject":"Opportunity","templateId":"tpl-1",'
            + '"variables":[{"placeholder":"{Rent}","sourceField":"Amount","required":true},'
            + '{"placeholder":"{Second}","sourceField":"Amount","required":false}],"recipients":[],"fields":[]}';
        Map<String, Object> reqByLabel = new Map<String, Object>();
        for (Metadata.CustomMetadata m : TurboSignConfigController.buildMetadataRecords(payload)) {
            for (Metadata.CustomMetadataValue v : m.values) if (v.field == 'Required__c') reqByLabel.put(m.label, v.value);
        }
        System.assertEquals(true, reqByLabel.get('{Rent}'), 'required data token persisted');
        System.assertEquals(false, reqByLabel.get('{Second}'), 'optional data token persisted');
    }
}
