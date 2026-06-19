import { LightningElement } from 'lwc';

const STEPS = [
    { key: 1, num: '01', title: 'Consult', body: 'Tell us your space, volume, and house blend. We spec the exact build — machine, grinder, filtration.' },
    { key: 2, num: '02', title: 'Install', body: 'Our techs deliver, plumb, and dial it in on-site. White-glove, in 72 hours.' },
    { key: 3, num: '03', title: 'Train', body: 'Hands-on barista training for your whole team — extraction, milk, maintenance.' },
    { key: 4, num: '04', title: 'Backed for life', body: '15-year parts & labor, remote diagnostics, and same-week service. Forever.' }
];

export default class BbProcess extends LightningElement {
    steps = STEPS;
    _observed = false;

    renderedCallback() {
        if (this._observed) return;
        this._observed = true;
        const els = this.template.querySelectorAll('.step');
        if (!('IntersectionObserver' in window) || !els.length) {
            els.forEach((el) => el.classList.add('is-in'));
            return;
        }
        const io = new IntersectionObserver(
            (entries, obs) => {
                entries.forEach((e) => {
                    if (e.isIntersecting) {
                        e.target.classList.add('is-in');
                        obs.unobserve(e.target);
                    }
                });
            },
            { threshold: 0.25 }
        );
        els.forEach((el) => io.observe(el));
    }
}
