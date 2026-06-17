import { LightningElement, api } from 'lwc';

export default class BbBrandStory extends LightningElement {
    @api kicker = 'Our promise';
    @api headline = 'We sell the machine — then we stay for the espresso.';
    @api body = 'Anyone can ship a box. Bean & Brew installs, plumbs, and dials in every machine on site, then trains your team until the shots run sweet. Fifteen years of parts and labor mean the relationship starts at checkout — it does not end there.';
    @api ctaLabel = 'Meet the install team';
    @api ctaUrl = '/beanbrew/';
}
