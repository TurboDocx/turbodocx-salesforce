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

Older versions of this example used other record names: `Example_SignatureAnchor`, `Example_DateAnchor`,
`Example_ClientName` and `Example_EffectiveDate` (variables), `Example_Client` (recipient rule), and
`Example_ClientSig` and `Example_ClientDate` (field rules). Deploying the current records does not delete
them, and the old ones would still be read as part of `Example_Agreement`. After you deploy the current
records, run:

```bash
sf project deploy start \
  --manifest unpackaged/destructive/package.xml \
  --post-destructive-changes unpackaged/destructive/destructiveChanges.xml \
  --ignore-warnings \
  --target-org <your-org>
```

`package.xml` is empty on purpose: the deploy needs a manifest, and this one only deletes. Your org
probably has only some of the old records. `--ignore-warnings` lets the deploy delete the ones that exist
and skip the rest; without it, any missing record ("No CustomMetadata named ...") fails the whole deploy
and nothing is deleted.
