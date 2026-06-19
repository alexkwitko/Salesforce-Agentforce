import { LightningElement } from 'lwc';

const PHRASES = [
    'Freshly engineered',
    'Installed for life',
    '15-year warranty',
    'Barista-grade pressure',
    'White-glove delivery',
    'Roaster-tuned',
    'Café-proven'
];

export default class BbMarquee extends LightningElement {
    // duplicated so the CSS translateX(-50%) loop is seamless
    get items() {
        const doubled = [...PHRASES, ...PHRASES];
        return doubled.map((text, key) => ({ key, text }));
    }
}
