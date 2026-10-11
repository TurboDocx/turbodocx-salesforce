/**
 * #45: the PDF viewer page accepts a document only from this org's own Salesforce hosts, never from another
 * tenant's Lightning or Experience Cloud origin.
 */
@IsTest
private class TurboSignPdfViewerControllerTest {
    private static List<String> allowed() {
        return (List<String>) JSON.deserialize(new TurboSignPdfViewerController().getAllowedOriginsJson(), List<String>.class);
    }

    @IsTest
    static void allowsThisOrgsLightningAndMyDomainOrigins() {
        List<String> origins = allowed();
        System.assert(origins.contains('https://' + DomainCreator.getLightningHostname().toLowerCase()),
            'allows the org Lightning origin, got ' + origins);
        System.assert(origins.contains('https://' + DomainCreator.getOrgMyDomainHostname().toLowerCase()),
            'allows the org My Domain origin, got ' + origins);
    }

    @IsTest
    static void everyAllowedOriginIsAnExactHttpsHost() {
        List<String> origins = allowed();
        System.assert(!origins.isEmpty(), 'allows at least this org, got ' + origins);
        for (String o : origins) {
            System.assert(o.startsWith('https://') && !o.substringAfter('https://').contains('/')
                && !o.contains('*') && o == o.toLowerCase(), 'an exact lowercase https origin, got ' + o);
        }
    }
}
