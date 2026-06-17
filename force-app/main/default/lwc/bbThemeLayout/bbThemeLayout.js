import { LightningElement, wire, api } from 'lwc';
import { CartSummaryAdapter } from 'commerce/cartApi';
import { SessionContextAdapter } from 'commerce/contextApi';

const BASE = '/beanbrew';

export default class BbThemeLayout extends LightningElement {
    @api announcement = 'Free white-glove install on every machine — this week only.';
    cartCount = 0;
    isLoggedIn = false;

    @wire(CartSummaryAdapter)
    wiredCart({ data }) {
        if (data && data.totalProductCount != null) this.cartCount = data.totalProductCount;
    }

    @wire(SessionContextAdapter)
    wiredSession({ data }) {
        if (data) this.isLoggedIn = !!data.isLoggedIn;
    }

    get homeUrl() { return BASE + '/'; }
    get productsUrl() { return BASE + '/category/products/0ZGfj000000IRGHGA4'; }
    get cartUrl() { return BASE + '/cart'; }
    get searchUrl() { return BASE + '/search'; }
    get accountUrl() { return this.isLoggedIn ? BASE + '/myprofile' : BASE + '/login'; }
    get accountLabel() { return this.isLoggedIn ? 'My Account' : 'Log In'; }
    get hasItems() { return this.cartCount > 0; }
}
