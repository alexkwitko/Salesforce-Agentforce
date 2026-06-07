/**
 * CoffeeAttributeBackfill — derives the structured coffee attribute axes
 * (Roast_Level__c, Bean_Type__c, Brew_Style__c, Is_Decaf__c, Is_Flavored__c)
 * from each product's Family + Name, so the recommendation engine can filter on
 * INDEPENDENT preference dimensions (decaf vs regular, single-origin vs blend,
 * espresso vs all-purpose, roast level) instead of one collapsed "family".
 *
 * Idempotent: re-running re-derives the same values. Only touches consumable-coffee
 * families; gear / gift sets / subscriptions are left null (not a single coffee).
 *
 * Run:  CoffeeAttributeBackfill.run();   (anonymous Apex)
 */
public without sharing class CoffeeAttributeBackfill {

    // Families that represent an actual drinkable coffee (carry bean attributes).
    private static final Set<String> COFFEE_FAMILIES = new Set<String>{
        'Single-Origin','Blends','Espresso','Decaf','Flavored'};

    public class Derived {
        public String roast;     // Light | Medium | Dark
        public String beanType;  // Single-Origin | Blend
        public String brew;      // Espresso | Cold Brew | All-Purpose
        public Boolean decaf;
        public Boolean flavored;
    }

    /** Pure derivation from family + name — unit-testable, no DML. */
    public static Derived derive(String family, String name) {
        String fam = family == null ? '' : family;
        String n = name == null ? '' : name.toLowerCase();
        Derived d = new Derived();

        // caffeine axis: cross-cuts everything (Family=Decaf OR name says decaf)
        d.decaf = (fam == 'Decaf') || n.contains('decaf');
        // flavored axis
        d.flavored = (fam == 'Flavored') || n.contains('flavored');

        // bean type: single-origin vs blend
        if (n.contains('blend')) {
            d.beanType = 'Blend';
        } else if (fam == 'Single-Origin') {
            d.beanType = 'Single-Origin';
        } else if (fam == 'Blends' || fam == 'Espresso' || fam == 'Flavored') {
            d.beanType = 'Blend';
        } else if (fam == 'Decaf') {
            // decaf single-origins ("Decaf Colombia") vs "Decaf House Blend" (caught above)
            d.beanType = 'Single-Origin';
        } else {
            d.beanType = null; // gift sets / subscriptions / gear
        }

        // brew style
        if (fam == 'Espresso' || n.contains('espresso')) {
            d.brew = 'Espresso';
        } else if (n.contains('cold brew')) {
            d.brew = 'Cold Brew';
        } else {
            d.brew = 'All-Purpose';
        }

        // roast level (explicit name wins; espresso defaults dark; else medium)
        if (n.contains('light')) {
            d.roast = 'Light';
        } else if (n.contains('dark') || n.contains('italian') || n.contains('french')) {
            d.roast = 'Dark';
        } else if (n.contains('medium')) {
            d.roast = 'Medium';
        } else if (fam == 'Espresso' || n.contains('espresso') || n.contains('ristretto')) {
            d.roast = 'Dark';
        } else {
            d.roast = 'Medium';
        }
        return d;
    }

    /** Backfill all coffee products. Returns a one-line summary. */
    public static String run() {
        List<Product2> ps = [
            SELECT Id, Name, Family, Roast_Level__c, Bean_Type__c, Brew_Style__c, Is_Decaf__c, Is_Flavored__c
            FROM Product2 WHERE Family IN :COFFEE_FAMILIES];
        for (Product2 p : ps) {
            Derived d = derive(p.Family, p.Name);
            p.Roast_Level__c = d.roast;
            p.Bean_Type__c   = d.beanType;
            p.Brew_Style__c  = d.brew;
            p.Is_Decaf__c    = d.decaf;
            p.Is_Flavored__c = d.flavored;
        }
        if (!ps.isEmpty()) update ps;
        return 'Backfilled ' + ps.size() + ' coffee products.';
    }
}
