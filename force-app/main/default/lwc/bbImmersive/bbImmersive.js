import { LightningElement, api } from 'lwc';

export default class BbImmersive extends LightningElement {
    @api ctaLabel = 'Meet the lineup';
    @api ctaUrl = '/beanbrew/category/products/0ZGfj000000IRGHGA4';
    _observed = false;

    renderedCallback() {
        if (this._observed) return;
        this._observed = true;
        const root = this.template.querySelector('.imm');
        if (!root) return;
        if (!('IntersectionObserver' in window)) {
            root.classList.add('is-in');
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
            { threshold: 0.3 }
        );
        io.observe(root);
    }
}
