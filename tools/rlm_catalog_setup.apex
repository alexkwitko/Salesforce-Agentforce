// RLM subscription catalog foundation: selling models + product + priced entries
ProductSellingModel psmAnnual = new ProductSellingModel(
    Name = 'Coffee Club - Annual',
    SellingModelType = 'TermDefined',
    PricingTerm = 1,
    PricingTermUnit = 'Annual',
    Status = 'Active'
);
ProductSellingModel psmMonthly = new ProductSellingModel(
    Name = 'Coffee Club - Monthly',
    SellingModelType = 'Evergreen',
    PricingTerm = 1,
    PricingTermUnit = 'Months',
    Status = 'Active'
);
insert new List<ProductSellingModel>{ psmAnnual, psmMonthly };

Product2 p = new Product2(
    Name = 'Coffee Club Subscription',
    ProductCode = 'COFFEE-CLUB',
    IsActive = true,
    Family = 'Subscription',
    Description = 'Monthly curated specialty coffee delivered to your door.'
);
insert p;

// RLM requires a ProductSellingModelOption linking product+selling model before a PricebookEntry can use it
insert new List<ProductSellingModelOption>{
    new ProductSellingModelOption(Product2Id = p.Id, ProductSellingModelId = psmAnnual.Id),
    new ProductSellingModelOption(Product2Id = p.Id, ProductSellingModelId = psmMonthly.Id)
};

Id stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
PricebookEntry peAnnual = new PricebookEntry(
    Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 180, IsActive = true,
    ProductSellingModelId = psmAnnual.Id
);
PricebookEntry peMonthly = new PricebookEntry(
    Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 18, IsActive = true,
    ProductSellingModelId = psmMonthly.Id
);
insert new List<PricebookEntry>{ peAnnual, peMonthly };

System.debug('PSM_ANNUAL=' + psmAnnual.Id);
System.debug('PSM_MONTHLY=' + psmMonthly.Id);
System.debug('PRODUCT=' + p.Id);
System.debug('PE_ANNUAL=' + peAnnual.Id);
System.debug('PE_MONTHLY=' + peMonthly.Id);
System.debug('STD_PB=' + stdPb);
