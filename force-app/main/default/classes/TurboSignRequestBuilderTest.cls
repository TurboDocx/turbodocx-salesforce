@IsTest
private class TurboSignRequestBuilderTest {

    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Acme QA');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'QA Opp', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = a.Id);
        insert o;
        return o;
    }

    private static Map<String, Object> byPlaceholder(List<Object> vars, String placeholder) {
        for (Object o : vars) {
            Map<String, Object> v = (Map<String, Object>) o;
            if (v.get('placeholder') == placeholder) return v;
        }
        return null;
    }

    @IsTest
    static void previewReturnsEditablePrefilledVariablesAndAnchors() {
        Opportunity o = makeOpp();
        Test.startTest();
        Map<String, Object> pv = TurboSignRequestBuilder.preview(o.Id, 'Example_Agreement');
        Test.stopTest();

        List<Object> vars = (List<Object>) pv.get('variables');
        Map<String, Object> client = byPlaceholder(vars, '{ClientName}');
        System.assertNotEquals(null, client, '{ClientName} present in preview');
        System.assertEquals('Acme QA', client.get('value'), 'prefilled from Account.Name');
        System.assertEquals('Client Name', client.get('label'), 'humanized label');
        System.assert(client.containsKey('editable'), 'editable flag surfaced');
        System.assertEquals('Account.Name', client.get('source'), 'source field path surfaced for traceability');
        System.assertEquals('Account', client.get('sourceObject'), 'source object surfaced');

        System.assert(!((List<Object>) pv.get('recipients')).isEmpty(), 'recipients resolved');
        System.assert(!((List<Object>) pv.get('anchors')).isEmpty(), 'configured anchors returned for QA');
        System.assertNotEquals(null, pv.get('templateId'), 'templateId surfaced for the backend anchor check');
    }

    @IsTest
    static void previewSurfacesFriendlyProvenanceLabels() {
        Opportunity o = makeOpp();
        Test.startTest();
        Map<String, Object> pv = TurboSignRequestBuilder.preview(o.Id, 'Example_Agreement');
        Test.stopTest();

        // Field provenance uses Salesforce field labels, not the raw path (Account.Name).
        Map<String, Object> client = byPlaceholder((List<Object>) pv.get('variables'), '{ClientName}');
        System.assertEquals('Account · Account Name', client.get('sourceLabel'),
            'related-record field shows "Relationship · Field" using org labels, with the "Id" suffix trimmed');

        // Recipient provenance is humanized the same way (Owner.Name / Owner.Email).
        Map<String, Object> r0 = (Map<String, Object>) ((List<Object>) pv.get('recipients'))[0];
        System.assertEquals('Owner · Full Name', r0.get('nameSourceLabel'), 'signer name provenance humanized');
        System.assertEquals('Owner · Email', r0.get('emailSourceLabel'), 'signer email provenance humanized');
    }

    @IsTest
    static void formatsDatesAndCurrencyNatively() {
        // A configured Date_Format__c pattern renders dates that way (currency/number come from native
        // SOQL FORMAT() at query time, which the platform localizes; see nativeFormatPaths).
        System.assertEquals('September 15, 2026',
            TurboSignRequestBuilder.applyDatePattern(Date.newInstance(2026, 9, 15), 'MMMM d, yyyy'),
            'configured date pattern applied');

        Schema.SObjectType oppType = Opportunity.SObjectType;
        List<TurboSign_Variable_Mapping__mdt> maps = new List<TurboSign_Variable_Mapping__mdt>{
            new TurboSign_Variable_Mapping__mdt(Source_Field_Path__c = 'Amount'),    // currency
            new TurboSign_Variable_Mapping__mdt(Source_Field_Path__c = 'CloseDate'), // date
            new TurboSign_Variable_Mapping__mdt(Source_Field_Path__c = 'Name')       // text
        };

        // No custom pattern: currency AND date are FORMAT()-wrapped (native locale); text never is.
        Set<String> nativeDefault = TurboSignRequestBuilder.nativeFormatPaths(oppType, maps, false);
        System.assert(nativeDefault.contains('Amount'), 'currency localized natively');
        System.assert(nativeDefault.contains('CloseDate'), 'date localized natively when no pattern');
        System.assert(!nativeDefault.contains('Name'), 'text is never FORMAT()-wrapped');

        // With a custom date pattern: dates come back raw so the pattern applies; currency stays native.
        Set<String> withPattern = TurboSignRequestBuilder.nativeFormatPaths(oppType, maps, true);
        System.assert(withPattern.contains('Amount'), 'currency still localized natively');
        System.assert(!withPattern.contains('CloseDate'), 'date left raw so the custom pattern applies');
    }

    @IsTest
    static void injectsAnchorSelfValuesSoTheySurviveTheMerge() {
        List<Object> vars = new List<Object>{
            new Map<String, Object>{ 'placeholder' => '{ClientName}', 'text' => 'Acme', 'mimeType' => 'text' } };
        List<TurboSign_Field_Rule__mdt> rules = new List<TurboSign_Field_Rule__mdt>{
            new TurboSign_Field_Rule__mdt(Anchor__c = '{sig}', Recipient_Role_Label__c = 'Signer'),
            new TurboSign_Field_Rule__mdt(Anchor__c = '{date}', Recipient_Role_Label__c = 'Signer') };

        TurboSignRequestBuilder.injectAnchorSelfValues(vars, rules, new Set<String>{ '{ClientName}' }, new Set<String>{ 'Signer' });

        Map<String, String> byPh = new Map<String, String>();
        for (Object o : vars) { Map<String, Object> m = (Map<String, Object>) o; byPh.put((String) m.get('placeholder'), (String) m.get('text')); }
        System.assertEquals('{sig}', byPh.get('{sig}'), 'anchor injected as its own value so the merge keeps it');
        System.assertEquals('{date}', byPh.get('{date}'), 'second anchor injected too');
        System.assertEquals('Acme', byPh.get('{ClientName}'), 'existing mapped variable untouched');
    }

    @IsTest
    static void doesNotDoubleInjectAnAlreadyMappedAnchor() {
        List<Object> vars = new List<Object>();
        List<TurboSign_Field_Rule__mdt> rules = new List<TurboSign_Field_Rule__mdt>{
            new TurboSign_Field_Rule__mdt(Anchor__c = '{sig}', Recipient_Role_Label__c = 'Signer') };
        // {sig} is already an explicit mapping -> injection must not duplicate it.
        TurboSignRequestBuilder.injectAnchorSelfValues(vars, rules, new Set<String>{ '{sig}' }, new Set<String>{ 'Signer' });
        System.assertEquals(0, vars.size(), 'an admin-mapped anchor is not injected again');
    }

    @IsTest
    static void pickPrefersOverrideThenStaticThenField() {
        Map<String, Object> vals = new Map<String, Object>{ 'Account.Email' => 'field@x.com' };
        System.assertEquals('ovr@x.com', TurboSignRequestBuilder.pick('ovr@x.com', 'static@x.com', 'Account.Email', vals), 'override wins');
        System.assertEquals('static@x.com', TurboSignRequestBuilder.pick(null, 'static@x.com', 'Account.Email', vals), 'static beats field');
        System.assertEquals('field@x.com', TurboSignRequestBuilder.pick('', null, 'Account.Email', vals), 'field used when no override/static');
        System.assertEquals(null, TurboSignRequestBuilder.pick(null, null, 'Missing', vals), 'nothing resolvable -> null');
    }

    @IsTest
    static void resolveDocumentNameResolvesFieldAndDateTokens() {
        Account a = new Account(Name = 'Acme Living'); insert a;
        Opportunity o = new Opportunity(Name = 'Op', StageName = 'Prospecting',
            CloseDate = Date.today().addDays(10), AccountId = a.Id);
        insert o;

        String name = TurboSignRequestBuilder.resolveDocumentName('Lease - {Account.Name} - {date}', o.Id, 'yyyy');

        System.assert(name.contains('Acme Living'), 'field token resolves from the record: ' + name);
        System.assert(name.contains(String.valueOf(Date.today().year())), 'date token resolves: ' + name);
        System.assert(!name.contains('{'), 'no unresolved tokens remain: ' + name);
    }

    @IsTest
    static void skipsAnchorWhoseRecipientWasDropped() {
        List<Object> vars = new List<Object>();
        List<TurboSign_Field_Rule__mdt> rules = new List<TurboSign_Field_Rule__mdt>{
            new TurboSign_Field_Rule__mdt(Anchor__c = '{sig}', Recipient_Role_Label__c = 'Signer'),
            new TurboSign_Field_Rule__mdt(Anchor__c = '{cosign}', Recipient_Role_Label__c = 'Cosigner') };
        // Only Signer resolved an email; Cosigner was dropped (§7.3). Its anchor must NOT be merged,
        // or the document keeps a literal "{cosign}" with no signature box.
        TurboSignRequestBuilder.injectAnchorSelfValues(vars, rules, new Set<String>(), new Set<String>{ 'Signer' });

        Map<String, String> byPh = new Map<String, String>();
        for (Object o : vars) { Map<String, Object> m = (Map<String, Object>) o; byPh.put((String) m.get('placeholder'), (String) m.get('text')); }
        System.assertEquals('{sig}', byPh.get('{sig}'), 'surviving anchor still injected');
        System.assert(!byPh.containsKey('{cosign}'), 'dropped-recipient anchor must not be injected as a literal token');
    }

    @IsTest
    static void buildAppliesRepEditsOverResolvedValues() {
        Opportunity o = makeOpp();
        Map<String, String> overrides = new Map<String, String>{ '{ClientName}' => 'Overridden Inc' };

        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement', overrides);
        Test.stopTest();

        Map<String, Object> client = byPlaceholder(req.variables, '{ClientName}');
        System.assertNotEquals(null, client, '{ClientName} in built variables');
        System.assertEquals('Overridden Inc', client.get('text'), 'rep edit wins over the resolved Account.Name');
    }

    // #38: a blank value (e.g. no second resident) must still generate, leaving that spot empty. The
    // backend only accepts empty text on a variable flagged isDisabled.
    @IsTest
    static void blankValueIsSentDisabledSoTheSendStillGenerates() {
        Opportunity o = makeOpp();
        Map<String, String> overrides = new Map<String, String>{ '{ClientName}' => '' };

        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement', overrides);
        Test.stopTest();

        Map<String, Object> client = byPlaceholder(req.variables, '{ClientName}');
        System.assertEquals('', client.get('text'), 'blank stays blank in the document');
        System.assertEquals(true, client.get('isDisabled'), 'blank values are flagged so the backend accepts them');
    }

    @IsTest
    static void filledValueIsNotDisabled() {
        Opportunity o = makeOpp();

        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement');
        Test.stopTest();

        Map<String, Object> client = byPlaceholder(req.variables, '{ClientName}');
        System.assertEquals('Acme QA', client.get('text'), 'resolved from Account.Name');
        System.assertNotEquals(true, client.get('isDisabled'), 'only blank values are disabled');
    }

    @IsTest
    static void previewRecipientsIncludeSourcePaths() {
        Opportunity o = makeOpp();
        Test.startTest();
        Map<String, Object> pv = TurboSignRequestBuilder.preview(o.Id, 'Example_Agreement');
        Test.stopTest();
        List<Object> recips = (List<Object>) pv.get('recipients');
        System.assert(!recips.isEmpty(), 'a signer is present');
        Map<String, Object> r0 = (Map<String, Object>) recips[0];
        System.assertEquals('Owner.Email', r0.get('emailSource'), 'signer email source surfaced');
        System.assertEquals('Owner.Name', r0.get('nameSource'), 'signer name source surfaced');
    }

    // The example's {EffectiveDate} follows the Opportunity's close date, formatted for the user's locale.
    @IsTest
    static void exampleEffectiveDateIsTheCloseDate() {
        Opportunity o = makeOpp();
        Opportunity formatted = [SELECT FORMAT(CloseDate) fmt FROM Opportunity WHERE Id = :o.Id];
        String expected = (String) formatted.get('fmt');
        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement');
        Test.stopTest();
        System.assertEquals(expected, byPlaceholder(req.variables, '{EffectiveDate}').get('text'),
            '{EffectiveDate} comes from CloseDate');
    }

    @IsTest
    static void buildAppliesSignerOverrides() {
        Opportunity o = makeOpp();
        Map<String, Map<String, String>> recOvr = new Map<String, Map<String, String>>{
            'Signer' => new Map<String, String>{ 'email' => 'override@example.com', 'name' => 'Override Person' } };

        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement', null, recOvr);
        Test.stopTest();

        Boolean found = false;
        for (Object ro : req.recipients) {
            Map<String, Object> r = (Map<String, Object>) ro;
            if (r.get('email') == 'override@example.com') { found = true; System.assertEquals('Override Person', r.get('name')); }
        }
        System.assert(found, 'rep-edited signer email + name win over the resolved Owner fields');
    }

    @IsTest
    static void twoArgBuildStillResolvesFromRecord() {
        Opportunity o = makeOpp();
        Test.startTest();
        TurboSignService.SendRequest req = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement');
        Test.stopTest();
        Map<String, Object> client = byPlaceholder(req.variables, '{ClientName}');
        System.assertEquals('Acme QA', client.get('text'), 'no overrides -> resolved record value unchanged');
    }

    // Review: dropping an optional signer must not leave a gap; the backend requires 1..n.
    @IsTest
    static void signingOrderIsRenumberedWithoutGaps() {
        List<Object> recips = new List<Object>{
            new Map<String, Object>{ 'signingOrder' => 1 }, new Map<String, Object>{ 'signingOrder' => 3 } };
        TurboSignRequestBuilder.renumberSigningOrder(recips);
        System.assertEquals(1, ((Map<String, Object>) recips[0]).get('signingOrder'), 'first stays 1');
        System.assertEquals(2, ((Map<String, Object>) recips[1]).get('signingOrder'), '3 closes the gap to 2');

        List<Object> sameStep = new List<Object>{ new Map<String, Object>{ 'signingOrder' => 2 },
            new Map<String, Object>{ 'signingOrder' => 2 }, new Map<String, Object>{ 'signingOrder' => 5 } };
        TurboSignRequestBuilder.renumberSigningOrder(sameStep);
        System.assertEquals(1, ((Map<String, Object>) sameStep[1]).get('signingOrder'), 'parallel signers keep sharing a step');
        System.assertEquals(2, ((Map<String, Object>) sameStep[2]).get('signingOrder'), 'next step follows densely');
    }

    // Review: a REQUIRED mapping that resolves blank blocks the send before any callout; optional blanks
    // still go out disabled (#38).
    @IsTest
    static void blankRequiredValueBlocksTheSend() {
        TurboSign_Variable_Mapping__mdt rent = new TurboSign_Variable_Mapping__mdt(Placeholder__c = '{MonthlyRent}', Required__c = true);
        String msg;
        try { TurboSignRequestBuilder.variableFor(rent, ''); } catch (TurboSignHttpClient.ApiException e) { msg = e.getMessage(); }
        System.assert(msg != null && msg.contains('{MonthlyRent}'), 'names the missing required value, got: ' + msg);

        TurboSign_Variable_Mapping__mdt second = new TurboSign_Variable_Mapping__mdt(Placeholder__c = '{SecondRent}', Required__c = false);
        System.assertEquals(true, TurboSignRequestBuilder.variableFor(second, '').get('isDisabled'), 'optional blank is disabled');
    }

    // Review: the backend rejects optional signature/initial fields, so they are always sent required.
    @IsTest
    static void signatureAndInitialAreAlwaysRequired() {
        System.assertEquals(true, TurboSignRequestBuilder.fieldRequired('signature', false), 'signature forced required');
        System.assertEquals(true, TurboSignRequestBuilder.fieldRequired('initial', null), 'initial forced required');
        System.assertEquals(false, TurboSignRequestBuilder.fieldRequired('checkbox', false), 'checkbox may be optional');
    }

    // Review: never email a signer as "signer_104"; fall back to their email address.
    @IsTest
    static void signerWithoutANameIsAddressedByEmail() {
        System.assertEquals('pat@example.com', TurboSignRequestBuilder.displayName(null, 'pat@example.com'), 'email fallback');
        System.assertEquals('Pat Lee', TurboSignRequestBuilder.displayName('Pat Lee', 'pat@example.com'), 'name wins');
    }

    // Review: a bad Date_Format__c must not break sends, and only matters when the name uses {date}.
    @IsTest
    static void badDateFormatDoesNotBreakTheDocumentName() {
        System.assertEquals('Lease', TurboSignRequestBuilder.resolveDocumentName('Lease', null, 'MMMM Do, YYYY'),
            'pattern ignored when the name has no {date}');
        String named = TurboSignRequestBuilder.resolveDocumentName('Lease {date}', null, 'yyyy-MM-ddTHH:mm');
        System.assert(named.startsWith('Lease '), 'falls back instead of throwing, got: ' + named);
    }

    // #45 review: the preview needs only templateId, name and variables, so a signer with no email must not
    // stop it. A required signer keeps its anchors (the send's document will have them once the rep adds the
    // email); an optional one is dropped exactly as the send drops it.
    private static TurboSignRequestBuilder.RecipientParams signerWithoutEmail(Boolean required, Boolean forPreview) {
        TurboSignRequestBuilder.RecipientParams p = new TurboSignRequestBuilder.RecipientParams();
        p.rules = new List<TurboSign_Recipient_Rule__mdt>{ new TurboSign_Recipient_Rule__mdt(
            Role_Label__c = 'Signer', Email_Field_Path__c = 'Contact__r.Email', Name_Field_Path__c = 'Contact__r.Name',
            Signing_Order__c = 1, Required__c = required) };
        p.vals = new Map<String, Object>();
        p.forPreview = forPreview;
        return p;
    }

    @IsTest
    static void previewKeepsTheAnchorsOfARequiredSignerWithoutAnEmail() {
        TurboSignRequestBuilder.ResolvedRecipients r = TurboSignRequestBuilder.resolveRecipients(signerWithoutEmail(true, true));
        System.assert(r.anchorRoles.contains('Signer'), 'the required signer\'s anchors render as the send will');
        System.assert(r.recipients.isEmpty(), 'nobody to address without an email');
    }

    @IsTest
    static void previewDropsAnOptionalSignerWithoutAnEmailLikeTheSend() {
        TurboSignRequestBuilder.ResolvedRecipients preview = TurboSignRequestBuilder.resolveRecipients(signerWithoutEmail(false, true));
        TurboSignRequestBuilder.ResolvedRecipients send = TurboSignRequestBuilder.resolveRecipients(signerWithoutEmail(false, false));
        System.assert(!preview.anchorRoles.contains('Signer'), 'dropped signer: its anchors are not merged');
        System.assertEquals(send.anchorRoles, preview.anchorRoles, 'preview and send agree on a dropped optional signer');
    }

    @IsTest
    static void sendStillStopsOnARequiredSignerWithoutAnEmail() {
        String msg;
        try {
            TurboSignRequestBuilder.resolveRecipients(signerWithoutEmail(true, false));
        } catch (TurboSignHttpClient.ApiException e) {
            msg = e.getMessage();
        }
        System.assertEquals('Signer 1 has no email on this record.', msg, 'the send still asks for the email');
    }

    @IsTest
    static void previewBuildsTheSameDeliverableAsTheSend() {
        Opportunity o = makeOpp();
        TurboSignRequestBuilder.BuildParams p = new TurboSignRequestBuilder.BuildParams();
        p.recordId = o.Id;
        p.configDeveloperName = 'Example_Agreement';
        p.overrides = new Map<String, String>{ '{ClientName}' => 'Edited Inc' };

        Test.startTest();
        TurboSignService.SendRequest preview = TurboSignRequestBuilder.buildForPreview(p);
        TurboSignService.SendRequest send = TurboSignRequestBuilder.build(o.Id, 'Example_Agreement', p.overrides, null);
        Test.stopTest();

        System.assertEquals(send.templateId, preview.templateId, 'same template');
        System.assertEquals(send.documentName, preview.documentName, 'same name');
        System.assertEquals(JSON.serialize(send.variables), JSON.serialize(preview.variables), 'same variables, anchors included');
    }
}
