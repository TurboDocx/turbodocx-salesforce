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
| `TurboSign_Variable_Mapping.Example_ClientName` | `{ClientName}` from `Account.Name` |
| `TurboSign_Variable_Mapping.Example_EffectiveDate` | `{EffectiveDate}` with the default value "August 16, 2026" |
| `TurboSign_Recipient_Rule.Example_Client` | role `Signer`, name from `Owner.Name`, email from `Owner.Email`, signing order 1, required |
| `TurboSign_Field_Rule.Example_ClientSig` | `{sig}` is a signature field for `Signer`, required |
| `TurboSign_Field_Rule.Example_ClientDate` | `{date}` is a date field for `Signer`, not required |

The records have the same shape as a setup built in TurboSign Setup:

- The only values a rep sees are `{ClientName}` and `{EffectiveDate}`.
- The signing spots `{sig}` and `{date}` sit in the template as plain tokens. Each one has a field rule,
  and the send fills the token in so it survives the merge.
- Field rules carry no width or height. Signature fields are required, other fields are optional.

**The example sends to the Opportunity's owner**, so you can test the full flow on yourself. For real
sends, point the signer's name and email paths at a field on your record that leads to the customer.
For example, with a custom Contact lookup on Opportunity, use `Contact__r.Name` and `Contact__r.Email`.

## Set it up

1. In TurboDocx, go to **Templates**, upload `sample/Service Agreement.docx`, and copy its template ID.
   The sample is a short agreement that holds `{ClientName}`, `{EffectiveDate}`, `{sig}` and `{date}`.
2. Paste the template ID into `Deliverable_Template_Id__c` in
   `main/default/customMetadata/TurboSign_Config.Example_Agreement.md-meta.xml`. You can also deploy
   first and set the template in TurboSign Setup afterwards.
3. Deploy the records:

   ```bash
   sf project deploy start --source-dir unpackaged --target-org <your-org>
   ```

   A plain `sf project deploy start` skips this folder, because `unpackaged/` is not a package
   directory. Name it with `--source-dir`.

The Apex tests mock every callout, so they pass with the placeholder template ID. A real send needs a
real template ID.

## Remove records from an older version of this example

Older versions of this example used two extra variables, `Example_SignatureAnchor` and
`Example_DateAnchor`. Deploying the current records does not delete them. If your org has them, run:

```bash
sf project deploy start \
  --manifest unpackaged/destructive/package.xml \
  --post-destructive-changes unpackaged/destructive/destructiveChanges.xml \
  --target-org <your-org>
```

`package.xml` is empty on purpose: the deploy needs a manifest, and this one only deletes. If your org
never had those records, the command fails with "No CustomMetadata named ..." and changes nothing.
