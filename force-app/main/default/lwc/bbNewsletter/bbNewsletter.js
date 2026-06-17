import { LightningElement, api, track } from 'lwc';

export default class BbNewsletter extends LightningElement {
    @api heading = 'Get the dial-in guide.';
    @api subhead = 'Join 40,000 baristas. Brewing tips, restock alerts, and members-only drops — no spam, ever.';
    @track email = '';
    @track done = false;

    handleInput(e) { this.email = e.target.value; }
    handleSubmit(e) {
        e.preventDefault();
        if (this.email && this.email.includes('@')) { this.done = true; }
    }
}
