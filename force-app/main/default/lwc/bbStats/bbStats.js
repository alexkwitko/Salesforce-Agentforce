import { LightningElement } from 'lwc';

const STATS = [
    { key: 1, target: 2400, dec: 0, suffix: '+', label: 'cafés equipped' },
    { key: 2, target: 99.9, dec: 1, suffix: '%', label: 'service uptime' },
    { key: 3, target: 15, dec: 0, suffix: ' yr', label: 'parts & labor warranty' },
    { key: 4, target: 72, dec: 0, suffix: ' hr', label: 'white-glove install' }
];

export default class BbStats extends LightningElement {
    stats = STATS;
    _io = false;

    renderedCallback() {
        if (this._io) return;
        this._io = true;
        const root = this.template.querySelector('.stats');
        if (!root) return;
        if (!('IntersectionObserver' in window)) { this.run(); return; }
        const io = new IntersectionObserver((entries, obs) => {
            entries.forEach((e) => { if (e.isIntersecting) { this.run(); obs.disconnect(); } });
        }, { threshold: 0.4 });
        io.observe(root);
    }

    run() {
        const els = [...this.template.querySelectorAll('.stat__num')];
        els.forEach((el) => {
            const target = parseFloat(el.dataset.target);
            const dec = parseInt(el.dataset.dec || '0', 10);
            const dur = 1500;
            let start = null;
            const fmt = (v) => {
                return dec ? v.toFixed(dec) : Math.round(v).toLocaleString();
            };
            const step = (ts) => {
                if (start === null) start = ts;
                const p = Math.min((ts - start) / dur, 1);
                const eased = 1 - Math.pow(1 - p, 3);
                el.textContent = fmt(target * eased);
                if (p < 1) {
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    requestAnimationFrame(step);
                } else { el.textContent = fmt(target); }
            };
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            requestAnimationFrame(step);
        });
    }
}
