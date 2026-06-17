import { LightningElement, api } from 'lwc';

export default class BbHero extends LightningElement {
    @api eyebrow = 'Commercial-grade espresso, delivered & installed';
    @api headline = 'Coffee worth\nthe craft.';
    @api subhead = 'Pro-grade machines, grinders, and filtration — engineered for cafés and serious home baristas. Installed by our techs, backed for life.';
    @api primaryLabel = 'Shop the collection';
    @api primaryUrl = '/beanbrew/category/products/0ZGfj000000IRGHGA4';
    @api secondaryLabel = 'Book an install consult';
    @api secondaryUrl = '/beanbrew/';

    get headlineLines() {
        return (this.headline || '').split('\n').map((t, i) => ({ key: i, text: t }));
    }
}
