/**
 * Resolves dot-path field references (e.g. "Account.Name", "Apartment__r.Building__c")
 * against a source record via one dynamic SOQL query. Object-agnostic: never names a
 * customer-specific object or field (spec §2.1, §9.1).
 */
public with sharing class TurboSignFieldResolver {
    public class ResolveRequest {
        public Id recordId;
        public List<String> paths;
        // Paths to wrap in SOQL FORMAT() so the platform localizes them (currency, number, date) using
        // the running user's locale and the org/record currency. Others are selected raw.
        public Set<String> formatPaths;
    }

    // Only describe-validated paths reach the dynamic SELECT, and it runs in USER_MODE (see below).
    @SuppressWarnings('PMD.ApexSOQLInjection')
    public static Map<String, Object> resolve(ResolveRequest req) {
        Map<String, Object> out = new Map<String, Object>();
        if (req == null || req.recordId == null || req.paths == null || req.paths.isEmpty()) {
            return out;
        }
        String objectType = req.recordId.getSObjectType().getDescribe().getName();
        Set<String> unique = new Set<String>(req.paths);
        Set<String> fmt = req.formatPaths == null ? new Set<String>() : req.formatPaths;
        Id recId = req.recordId;
        // Default every requested path to null, then only fill the ones we can safely resolve.
        for (String path : req.paths) out.put(path, null);
        // Only paths that describe-validate (real relationships/fields the running user can read)
        // are interpolated into the SELECT. This closes both SOQL identifier injection and the FLS
        // read-through, and guarantees the USER_MODE query below never references an inaccessible field.
        List<String> selects = new List<String>();
        List<String> valid = new List<String>();
        for (String p : unique) {
            if (isResolvablePath(objectType, p)) {
                selects.add(fmt.contains(p) ? 'FORMAT(' + p + ')' : p);
                valid.add(p);
            }
        }
        if (valid.isEmpty()) return out;
        String soql = 'SELECT ' + String.join(selects, ', ')
            + ' FROM ' + objectType + ' WHERE Id = :recId LIMIT 1';
        SObject rec = Database.query(soql, AccessLevel.USER_MODE);
        for (String path : valid) {
            out.put(path, valueAtPath(rec, path));
        }
        return out;
    }

    /**
     * True only if every segment of the dot-path resolves to a real, readable relationship/field on the
     * traversed sObject. Rejects nonexistent fields and anything that isn't a plain identifier (e.g. an
     * injected subquery), and enforces field-level security via isAccessible() at each hop.
     */
    private static Boolean isResolvablePath(String objectType, String path) {
        if (String.isBlank(path)) return false;
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectType);
        if (t == null) return false;
        List<String> parts = path.split('\\.');
        for (Integer i = 0; i < parts.size(); i++) {
            String seg = parts[i];
            Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
            if (i < parts.size() - 1) {
                Schema.SObjectField rel = relationshipField(fields, seg);
                if (rel == null) return false;
                Schema.DescribeFieldResult d = rel.getDescribe();
                if (!d.isAccessible()) return false;
                List<Schema.SObjectType> refs = d.getReferenceTo();
                if (refs == null || refs.isEmpty()) return false;
                t = refs[0];
            } else {
                Schema.SObjectField f = fields.get(seg);
                if (f == null) return false;
                if (!f.getDescribe().isAccessible()) return false;
            }
        }
        return true;
    }

    /** Finds the field whose relationship name matches seg (e.g. "Account" -> AccountId), else null. */
    private static Schema.SObjectField relationshipField(Map<String, Schema.SObjectField> fields, String seg) {
        for (Schema.SObjectField f : fields.values()) {
            String rn = f.getDescribe().getRelationshipName();
            if (rn != null && rn.equalsIgnoreCase(seg)) return f;
        }
        return null;
    }

    private static Object valueAtPath(SObject rec, String path) {
        List<String> parts = path.split('\\.');
        SObject cursor = rec;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (cursor == null) return null;
            cursor = cursor.getSObject(parts[i]);
        }
        return cursor == null ? null : cursor.get(parts[parts.size() - 1]);
    }
}
