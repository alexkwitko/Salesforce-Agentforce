import { LightningElement } from 'lwc';

export default class BbValueProps extends LightningElement {
    props = [
        { key: 'install', icon: 'M3 11l9-8 9 8M5 9.5V21h14V9.5', title: 'Pro installation', copy: 'Certified techs install, plumb & calibrate on site.' },
        { key: 'warranty', icon: 'M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z', title: 'Lifetime backing', copy: '15-year parts & labor. Real humans, real fast.' },
        { key: 'ship', icon: 'M3 7h11v8H3zM14 10h4l3 3v2h-7M5.5 19a1.5 1.5 0 100-3 1.5 1.5 0 000 3zM17.5 19a1.5 1.5 0 100-3 1.5 1.5 0 000 3z', title: 'Freight included', copy: 'White-glove freight & haul-away on every machine.' },
        { key: 'beans', icon: 'M12 3c3 2 3 6 0 9-3-3-3-7 0-9zM7 21c2-1 3-3 3-5M17 21c-2-1-3-3-3-5', title: 'Dialed-in support', copy: 'Free virtual barista session to dial in your setup.' }
    ];
}
