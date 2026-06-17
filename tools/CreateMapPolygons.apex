String head = '<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark><Polygon><outerBoundaryIs><LinearRing><coordinates>';
String tail = '</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark></Document></kml>';
Map<String,String> coords = new Map<String,String>{
 'Kwitko Metro'      => '-122.55,37.83,0\n-122.35,37.83,0\n-122.35,37.45,0\n-122.55,37.45,0\n-122.55,37.83,0',
 'Bean & Brew Metro' => '-122.34,37.90,0\n-122.10,37.90,0\n-122.10,37.60,0\n-122.34,37.60,0\n-122.34,37.90,0',
 'Demo Territory'    => '-122.10,37.45,0\n-121.75,37.45,0\n-121.75,37.20,0\n-122.10,37.20,0\n-122.10,37.45,0'
};
Map<String,String> color = new Map<String,String>{
 'Kwitko Metro' => '#1E90FF', 'Bean & Brew Metro' => '#FF8C00', 'Demo Territory' => '#32CD32'
};
Map<String,Id> idByName = new Map<String,Id>();
for (ServiceTerritory st : [SELECT Id, Name FROM ServiceTerritory WHERE Name IN :coords.keySet()]) idByName.put(st.Name, st.Id);
List<FSL__Polygon__c> polys = new List<FSL__Polygon__c>();
for (String tn : coords.keySet()) {
  if (!idByName.containsKey(tn)) { System.debug('MISSING TERRITORY: '+tn); continue; }
  polys.add(new FSL__Polygon__c(Name=tn+' Zone', FSL__Color__c=color.get(tn),
     FSL__Service_Territory__c=idByName.get(tn), FSL__KML__c=head+coords.get(tn)+tail));
}
insert polys;
for (FSL__Polygon__c p : [SELECT Name, FSL__Service_Territory__r.Name, FSL__Mi_La__c, FSL__Ma_La__c, FSL__Mi_Lo__c, FSL__Ma_Lo__c, FSL__Color__c FROM FSL__Polygon__c WHERE Id IN :polys ORDER BY Name]) {
  System.debug('CREATED '+p.Name+' | terr='+p.FSL__Service_Territory__r.Name+' | color='+p.FSL__Color__c+' | bbox La['+p.FSL__Mi_La__c+'..'+p.FSL__Ma_La__c+'] Lo['+p.FSL__Mi_Lo__c+'..'+p.FSL__Ma_Lo__c+']');
}
