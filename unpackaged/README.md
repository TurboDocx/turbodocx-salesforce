# Test fixtures: example TurboSign config

These records are `unpackagedMetadata` (see `sfdx-project.json`): the Apex tests build sends from
`Example_Agreement`, so CI and `sf package version create --code-coverage` deploy them next to the
package, but they never ship to subscribers.

## Example CMDT config (Service Agreement)

These are example `TurboSign_Config__mdt` + child records wiring a sample Service Agreement
template to an Opportunity send. The **types** deploy with the package; these **records** are a
sample seed. If a custom metadata record deploy fails in your org, create the records in
Setup > Custom Metadata Types > Manage Records > New instead.

Recipient email resolves from `Owner.Email` (the Opportunity owner) so no custom email field is needed.

The template holds the signing spots as plain tokens, `{sig}` and `{date}`, the same way a setup built
in TurboSign Setup does: each has a field rule, and the send fills the token in so it survives the merge.
The only values a rep sees are `{ClientName}` and `{EffectiveDate}`.
