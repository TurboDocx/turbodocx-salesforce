/**
 * Backs TurboSign_PdfViewer: the exact origins of this org's own Salesforce pages, so the viewer accepts a PDF
 * only from a page of this org and never from another tenant's Lightning or Experience Cloud origin.
 */
public with sharing class TurboSignPdfViewerController {
    /** JSON array of https://<host> origins: Lightning, My Domain, and Experience Cloud and Salesforce Sites when enabled. */
    public String getAllowedOriginsJson() {
        List<String> origins = new List<String>();
        addOrigin(origins, DomainCreator.getLightningHostname());
        addOrigin(origins, DomainCreator.getOrgMyDomainHostname());
        // These throw when the org has no Experience Cloud or Salesforce Sites; then there is nothing to allow.
        try {
            addOrigin(origins, DomainCreator.getExperienceCloudSitesHostname());
        } catch (Exception e) {
            System.debug(LoggingLevel.FINE, 'TurboSign viewer: no Experience Cloud sites hostname: ' + e.getMessage());
        }
        try {
            addOrigin(origins, DomainCreator.getSalesforceSitesHostname());
        } catch (Exception e) {
            System.debug(LoggingLevel.FINE, 'TurboSign viewer: no Salesforce Sites hostname: ' + e.getMessage());
        }
        return JSON.serialize(origins);
    }

    private static void addOrigin(List<String> origins, String hostname) {
        if (String.isBlank(hostname)) return;
        String origin = 'https://' + hostname.trim().toLowerCase();
        if (!origins.contains(origin)) origins.add(origin);
    }
}
