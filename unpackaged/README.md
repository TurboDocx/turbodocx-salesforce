# Example TurboSign setup (Service Agreement)

This folder holds an example TurboSign setup: a `TurboSign_Config__mdt` record named `Example_Agreement`
and its child records. It sends a Service Agreement from an Opportunity. The Apex tests build their
sends from `Example_Agreement`, so these records must be in the org before you run the tests.

The folder is `unpackagedMetadata` (see `sfdx-project.json`). CI and
`sf package version create --code-coverage` deploy it next to the package so the tests can run, but it
never ships to subscribers.

## What's in it

| Record | What it does |
| --- | --- |
| `TurboSign_Config.Example_Agreement` | Opportunity, active, document name "Service Agreement", template id `REPLACE_WITH_YOUR_TEMPLATE_ID` |
| `TurboSign_Variable_Mapping.Example_Agreement_ClientName` | `{ClientName}` from `Account.Name` |
| `TurboSign_Variable_Mapping.Example_Agreement_EffectiveDate` | `{EffectiveDate}` from the Opportunity's `CloseDate`, formatted for the sender's locale |
| `TurboSign_Recipient_Rule.Example_Agreement_Signer` | role `Signer`, name from `Owner.Name`, email from `Owner.Email`, signing order 1, required |
| `TurboSign_Field_Rule.Example_Agreement_sig` | `{sig}` is a signature field for `Signer`, required |
| `TurboSign_Field_Rule.Example_Agreement_date` | `{date}` is a date field for `Signer`, not required |

Every record is active.

The records are exactly what TurboSign Setup writes for this setup: the same API names, labels and
values. So if you open the example in TurboSign Setup and save it, Setup updates these records instead of
adding a second set next to them.

- The only values a rep sees are `{ClientName}` and `{EffectiveDate}`.
- The signing spots `{sig}` and `{date}` sit in the template as plain tokens. Each one has a field rule,
  and the send fills the token in so it survives the merge.
- Field rules carry no width or height. Signature fields are required, other fields are optional.

The recipient role is `Signer`. Earlier pre-release versions of this example called it `Client`. Nothing
needs migrating: the role is only a label that links the recipient rule to its field rules, and both
use `Signer`.

**The example sends to the Opportunity's owner**, so you can test the full flow on yourself. For real
sends, on your copy (see below), point the signer's name and email paths at a field on your record that
leads to the customer. For example, with a custom Contact lookup on Opportunity, use `Contact__r.Name` and `Contact__r.Email`.

## Set it up

1. Deploy the package and the records as shipped:

   ```bash
   sf project deploy start --source-dir force-app --source-dir unpackaged --target-org <your-org>
   ```

   A plain `sf project deploy start` skips this folder, because `unpackaged/` is not a package
   directory. Name it with `--source-dir`.
2. In TurboDocx, go to **Templates**, upload `sample/Service Agreement.docx`, and copy its template ID.
   The sample is a short agreement that holds `{ClientName}`, `{EffectiveDate}`, `{sig}` and `{date}`.
3. In **TurboSign Setup**, open the example, click **Duplicate**, and set the template ID on the copy.

The Apex tests mock every callout, so they pass with the example's placeholder template ID. A real send
needs a real template ID, which is why you send from the copy.

## Don't edit the example; copy it

Deploy `unpackaged/` for the first install and whenever you deploy with Apex tests (every production
deploy runs them): the tests check that the example is exactly as shipped. Each of those deploys puts
the example back as shipped, so it undoes any change you made to it in TurboSign Setup, such as the
template ID or deactivating it.

To use the example for real sends, open it in **TurboSign Setup**, click **Duplicate**, and set your
template and recipients on the copy. Leave the example itself as it is.

## Upgrade an org that has an older version of this example

Older versions of this example used other record names: `Example_SignatureAnchor`, `Example_DateAnchor`,
`Example_ClientName` and `Example_EffectiveDate` (variables), `Example_Client` (recipient rule), and
`Example_ClientSig` and `Example_ClientDate` (field rules). Deploying the current records does not delete
them, and the old ones are still read as part of `Example_Agreement`, so the tests fail and the deploy
rolls back. Upgrade with one deploy that deletes the old records first and then deploys the package and
the example:

```bash
rm -rf example-upgrade
sf project convert source --source-dir force-app --source-dir unpackaged --output-dir example-upgrade
cp unpackaged/destructive/destructiveChangesPre.xml example-upgrade/
sf project deploy start --metadata-dir example-upgrade --ignore-warnings --target-org <your-org>
```

The first three commands only build the deploy in `example-upgrade/` (git ignores it); the last
is the deploy, and it runs the Apex tests in production. `destructiveChangesPre.xml` lists the old
names, and the deploy deletes them before it deploys the new records, so the tests never see them. Your
org probably has only some of the old records. `--ignore-warnings` lets the deploy delete the ones that
exist and skip the rest; without it, any missing record ("No CustomMetadata named ...") fails the whole
deploy.

Why not `--pre-destructive-changes` with `--source-dir`? The CLI accepts that flag only with
`--manifest`, and a manifest can't name the records in `unpackaged/`, because it is not a package
directory: the deploy fails with "was named in package.xml, but was not found". A deploy from a
Metadata API folder carries `destructiveChangesPre.xml` inside it instead.
