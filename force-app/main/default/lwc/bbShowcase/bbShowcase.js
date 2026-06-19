import { LightningElement } from 'lwc';

const BASE = '/beanbrew/product/';
const PRODUCTS = [
    { key: 'm', name: 'Pro Espresso Machine', tag: 'Dual boiler · PID', price: '$2,199', id: '01tfj00000CrFwTAAV', slug: 'bean-brew-pro-espresso-machine', tone: 'a' },
    { key: 'g', name: 'Commercial Burr Grinder', tag: '64mm flat burrs', price: '$899', id: '01tfj00000CrFwUAAV', slug: 'bean-brew-commercial-burr-grinder', tone: 'b' },
    { key: 'f', name: 'Water Filtration System', tag: 'Scale-free, always', price: '$549', id: '01tfj00000CrFwVAAV', slug: 'bean-brew-water-filtration-system', tone: 'c' },
    { key: 'k', name: 'Milk Frother', tag: 'Microfoam in 20s', price: '$129', id: '01tfj00000CrFwWAAV', slug: 'bean-brew-milk-frother', tone: 'd' }
];

export default class BbShowcase extends LightningElement {
    products = PRODUCTS.map((p) => ({
        ...p,
        url: BASE + p.slug + '/' + p.id,
        cls: 'pc pc--' + p.tone
    }));
    _io = false;

    onTilt(event) {
        const card = event.currentTarget;
        const r = card.getBoundingClientRect();
        const px = (event.clientX - r.left) / r.width;
        const py = (event.clientY - r.top) / r.height;
        const rx = (0.5 - py) * 9;
        const ry = (px - 0.5) * 12;
        card.style.transform = `perspective(900px) rotateX(${rx.toFixed(2)}deg) rotateY(${ry.toFixed(2)}deg) translateY(-6px)`;
        card.style.setProperty('--mx', (px * 100).toFixed(1) + '%');
        card.style.setProperty('--my', (py * 100).toFixed(1) + '%');
    }

    offTilt(event) {
        const card = event.currentTarget;
        card.style.transform = '';
    }

    renderedCallback() {
        if (this._io) return;
        this._io = true;
        const els = this.template.querySelectorAll('.pc');
        if (!('IntersectionObserver' in window) || !els.length) {
            els.forEach((el) => el.classList.add('is-in'));
            return;
        }
        const io = new IntersectionObserver(
            (entries, obs) => entries.forEach((e) => {
                if (e.isIntersecting) { e.target.classList.add('is-in'); obs.unobserve(e.target); }
            }),
            { threshold: 0.2 }
        );
        els.forEach((el) => io.observe(el));
    }
}
