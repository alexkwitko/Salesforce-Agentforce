import { LightningElement, api } from 'lwc';

const BASE = '/beanbrew/product/x/';

export default class BbFeaturedCollection extends LightningElement {
    @api heading = 'The flagship lineup';
    @api subheading = 'Hand-picked machines and gear our techs install every week.';

    products = [
        { id: '01tfj00000CrFwTAAV', name: 'Pro Espresso Machine', tag: 'Bestseller', price: '$2,199', blurb: 'Dual boiler. PID-perfect.', tone: 'a' },
        { id: '01tfj00000CrFwUAAV', name: 'Commercial Burr Grinder', tag: 'Café-grade', price: '$899', blurb: '64mm flat burrs, stepless.', tone: 'b' },
        { id: '01tfj00000CrFwVAAV', name: 'Water Filtration System', tag: 'Protects your machine', price: '$549', blurb: 'Scale-free, better crema.', tone: 'c' },
        { id: '01tfj00000CrFwWAAV', name: 'Milk Frother', tag: 'Latte art ready', price: '$129', blurb: 'Microfoam in 20 seconds.', tone: 'd' },
        { id: '01tfj00000CrFwXAAV', name: 'Knock Box', tag: 'Essential', price: '$39', blurb: 'Walnut + stainless core.', tone: 'e' },
        { id: '01tfj00000CrFwYAAV', name: 'Descaling Kit', tag: 'Keep it dialed', price: '$24', blurb: 'Food-safe, 6-month supply.', tone: 'f' }
    ];

    get cards() {
        return this.products.map((p) => ({
            ...p,
            url: BASE + p.id,
            initial: p.name.charAt(0),
            toneClass: `card__art card__art--${p.tone}`
        }));
    }
}
