[![TurboDocx](https://raw.githubusercontent.com/TurboDocx/SDK/main/banner.png)](https://www.turbodocx.com)

<div align="center">

# TurboSign for Salesforce

**Send documents for e-signature from any Salesforce record and track the full signature lifecycle in place**

[![Salesforce](https://img.shields.io/badge/Salesforce-Unlocked%20Package-00A1E0?logo=salesforce&logoColor=white)](https://developer.salesforce.com/docs/platform/sfdx-dev/guide/sfdx-dev-unlocked-pkg-whats-a-package.html)
[![Apex](https://img.shields.io/badge/Apex-LWC-00A1E0?logo=salesforce&logoColor=white)](https://developer.salesforce.com/docs/platform/lwc/guide)
[![Discord](https://img.shields.io/badge/Discord-Join%20Us-7289DA?logo=discord&logoColor=white)](https://discord.gg/NYKwz4BcpX)
[![GitHub Stars](https://img.shields.io/github/stars/TurboDocx/turbodocx-salesforce?style=social)](https://github.com/TurboDocx/turbodocx-salesforce)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![X](https://img.shields.io/badge/X-@TurboDocx-000?logo=x&logoColor=white)](https://twitter.com/TurboDocx)

[Website](https://www.turbodocx.com) • [Documentation](https://docs.turbodocx.com/docs) • [Discord](https://discord.gg/NYKwz4BcpX) • [Blog](https://www.turbodocx.com/blog)

</div>

---

Distributable Salesforce package (unlocked, no namespace for v1) that lets a sales rep
send a document for e-signature through TurboSign from a Salesforce record and see the
full signature lifecycle written back onto that record.

**Install v1.1.1:** [Production or Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000oqUrAAI) • [Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000oqUrAAI)
Saving signed files back to Salesforce (new in 1.1.0) needs a TurboDocx update that is rolling out this week.
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
   the [Releases](https://github.com/TurboDocx/turbodocx-salesforce/releases) page; v1.1.1:
   [production or Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000oqUrAAI), [sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000oqUrAAI). Upgrades install over the old version;
   uninstall is one click.
2. **Deploy from source.** A developer deploys with the Salesforce CLI:

   ```bash
   sf project deploy start --source-dir force-app --source-dir unpackaged --target-org <alias>
   ```

   `unpackaged/` holds an example setup (a Service Agreement sent from an Opportunity) that the Apex
   tests build their sends from, so deploy it with the package: without it, a deploy that runs the
   tests fails. The example is active after the deploy and shows in the document picker. Every deploy
   that includes `unpackaged` puts the example back as shipped (placeholder template, active), so don't
   edit it: in **TurboSign Setup**, **Duplicate** it and change the copy. To upgrade an org that has
   records from an older version of the example, use the single deploy command in
   [unpackaged/README.md](unpackaged/README.md). See the
   [install guide](https://docs.turbodocx.com/docs/Integrations/turbosign-for-salesforce/install).

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

Lightning web component tests run locally with Jest: `npm install`, then `npm test`.

## Contributing

Issues and pull requests are welcome. Please include Apex tests with any change; the package must keep at least 75% code coverage.

## 🌐 Explore the TurboDocx Ecosystem

| Package | Links | Description |
|---------|-------|-------------|
| [TurboDocx SDKs](https://github.com/TurboDocx/SDK) | [![GitHub](https://img.shields.io/github/stars/turbodocx/sdk?style=social&label=Stars)](https://github.com/turbodocx/sdk) | Official SDKs for JavaScript, Python, PHP, Go, Java and Ruby |
| [@turbodocx/html-to-docx](https://github.com/TurboDocx/html-to-docx) | [![npm](https://img.shields.io/npm/v/@turbodocx/html-to-docx?logo=npm&logoColor=white&label=npm)](https://www.npmjs.com/package/@turbodocx/html-to-docx) [![GitHub](https://img.shields.io/github/stars/turbodocx/html-to-docx?style=social&label=Stars)](https://github.com/turbodocx/html-to-docx) | Convert HTML to DOCX with the fastest JavaScript library |
| [n8n-nodes-turbodocx](https://github.com/TurboDocx/n8n-nodes-turbodocx) | [![npm](https://img.shields.io/npm/v/@turbodocx/n8n-nodes-turbodocx?logo=npm&logoColor=white&label=npm)](https://www.npmjs.com/package/@turbodocx/n8n-nodes-turbodocx) [![GitHub](https://img.shields.io/github/stars/turbodocx/n8n-nodes-turbodocx?style=social&label=Stars)](https://github.com/turbodocx/n8n-nodes-turbodocx) | n8n community node for TurboDocx API & TurboSign |
| [TurboDocx Writer](https://appsource.microsoft.com/en-us/product/office/WA200007397) | [![AppSource](https://img.shields.io/badge/Microsoft-AppSource-blue?logo=microsoft)](https://appsource.microsoft.com/en-us/product/office/WA200007397) | Official Microsoft Word add-in for document automation |

## License

[MIT](LICENSE)

## Trademarks

TurboDocx and TurboSign are trademarks of TurboDocx. The MIT license does not grant rights to use these names or logos. If you fork this project, please give your fork a different name.

---

<div align="center">

**[Website](https://www.turbodocx.com)** • **[Documentation](https://docs.turbodocx.com/docs)** • **[Discord](https://discord.gg/NYKwz4BcpX)** • **[Twitter/X](https://twitter.com/TurboDocx)**

<sub>Built with ❤️ by the TurboDocx team</sub>

[![TurboDocx](https://raw.githubusercontent.com/TurboDocx/SDK/main/footer.png)](https://www.turbodocx.com)

</div>
