[![TurboDocx](https://raw.githubusercontent.com/TurboDocx/SDK/main/banner.png)](https://www.turbodocx.com)

<div align="center">

# TurboSign for Salesforce

**Send documents for e-signature from any Salesforce record and track the full signature lifecycle in place**

[![Salesforce](https://img.shields.io/badge/Salesforce-Unlocked%20Package-00A1E0?logo=salesforce&logoColor=white)](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_unlocked_pkgs_intro.htm)
[![Apex](https://img.shields.io/badge/Apex-LWC-00A1E0?logo=salesforce&logoColor=white)](https://developer.salesforce.com/docs/platform/lwc/guide)
[![Discord](https://img.shields.io/badge/Discord-Join%20Us-7289DA?logo=discord&logoColor=white)](https://discord.gg/NYKwz4BcpX)
[![GitHub Stars](https://img.shields.io/github/stars/TurboDocx/turbosign-salesforce?style=social)](https://github.com/TurboDocx/turbosign-salesforce)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![X](https://img.shields.io/badge/X-@TurboDocx-000?logo=x&logoColor=white)](https://twitter.com/TurboDocx)

[Website](https://www.turbodocx.com) • [Documentation](https://docs.turbodocx.com/docs) • [Discord](https://discord.gg/NYKwz4BcpX) • [Blog](https://www.turbodocx.com/blog)

</div>

---

Distributable Salesforce package (unlocked, no namespace for v1) that lets a sales rep
send a document for e-signature through TurboSign from a Salesforce record and see the
full signature lifecycle written back onto that record.

**Install v1.0.0:** [Production or Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000mtqDAAQ) • [Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000mtqDAAQ)
Full admin guide: [TurboSign for Salesforce docs](https://docs.turbodocx.com/docs/Integrations/turbosign-for-salesforce).

## Connecting to TurboDocx

All callouts go through the `TurboDocx_API` Named Credential, which uses the
`TurboDocx API` External Credential (Custom protocol, Named Principal
`TurboDocxPrincipal`). Your API key and TurboDocx org id are stored encrypted on that
principal and merged into the `Authorization` and `x-rapiddocx-org-id` headers by the platform
at callout time. Neither lives in a field, custom setting, or source file, and Setup never
displays them after saving.

1. **API key and org id.** Setup → Named Credentials → External Credentials → **TurboDocx
   API**. In Principals, edit `TurboDocxPrincipal` and add two Authentication Parameters with
   exactly these names (case matters):
   - `ApiKey`: your TurboDocx API key
   - `OrgId`: your TurboDocx organization id

   Save. A missing or misnamed parameter fails every callout with
   `Field TurboDocx_API.<name> does not exist`. To rotate the key, edit its value; nothing else
   changes.
2. **Endpoint.** The `TurboDocx_API` Named Credential URL is your TurboDocx API base URL.
3. **Permission sets.** Assign **TurboSign Admin** to admins and **TurboSign User** to
   reps. Both grant access to the `TurboDocxPrincipal` principal and read on User External
   Credentials; without them, callouts fail with a credential error. Callouts run as whoever
   triggers them, so also assign **TurboSign User** to any integration or automation user whose
   Flows or data loads send, remind, or void envelopes.
4. **Check the connection.** Open the **TurboSign Setup** tab. If the template picker lists
   your TurboDocx templates, the key, org id, and endpoint are right; otherwise it shows the
   error (for example `401`).

## Installation and supported Salesforce editions

The Salesforce **edition** decides whether the app can run; the **install method** decides who
installs it. The app ships custom Apex, so it needs an edition that runs custom Apex.

| Edition | Supported |
|---|---|
| Enterprise, Unlimited, Performance, Developer Edition | Yes |
| Sandboxes of those editions | Yes |
| Professional, Group | No: custom Apex only runs there from an AppExchange security-reviewed managed package |
| Starter, Pro Suite, Essentials | Not supported; check with your Salesforce rep |

Install methods:

1. **Install link (unlocked package).** Any Salesforce admin opens the link, logs in, and picks
   **Install for Admins Only** (then assign the permission sets). Links for the latest version are on
   the [Releases](https://github.com/TurboDocx/turbosign-salesforce/releases) page; v1.0.0:
   [production or Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000mtqDAAQ), [sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000mtqDAAQ). Upgrades install over the old version;
   uninstall is one click.
2. **Deploy from source.** A developer deploys with the Salesforce CLI:

   ```bash
   sf project deploy start --source-dir force-app --target-org <alias>
   ```

   Production deploys run Apex tests and need 75% coverage. Upgrades and uninstall are manual.

Packaging doesn't change *who* can install the app; it changes whether the customer's admin can
do it themselves or someone has to deploy it for them. Reaching Professional Edition would need a
security-reviewed managed package on AppExchange, which is not planned. Either way, the installer
needs permission to install packages (System Administrator).

## Repository layout

- `force-app/`: the package (Apex classes, Lightning web components, custom objects, custom metadata types, permission sets).
- `unpackaged/`: example configuration records used by the Apex tests. They are deployed next to the package for testing and never ship to customers.
- `config/project-scratch-def.json`: scratch org definition for development.

## Development

```bash
sf org login web --alias myorg
sf project deploy start --source-dir force-app --target-org myorg
sf project deploy start --source-dir unpackaged --target-org myorg
sf apex run test --test-level RunLocalTests --code-coverage --target-org myorg --wait 30
```

## Contributing

Issues and pull requests are welcome. Please include Apex tests with any change; the package must keep at least 75% code coverage.

## License

[MIT](LICENSE)

## Trademarks

TurboDocx and TurboSign are trademarks of TurboDocx. The MIT license does not grant rights to use these names or logos. If you fork this project, please give your fork a different name.
