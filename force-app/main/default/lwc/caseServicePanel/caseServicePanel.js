import { LightningElement, api, wire } from 'lwc';
import getServiceInfo from '@salesforce/apex/CaseServicePanelController.getServiceInfo';

export default class CaseServicePanel extends LightningElement {
    @api recordId;
    info;
    error;
    now = Date.now();
    _timer;

    @wire(getServiceInfo, { caseId: '$recordId' })
    wired(result) {
        if (result.data) { this.info = result.data; this.error = undefined; }
        else if (result.error) { this.error = result.error; this.info = undefined; }
    }

    connectedCallback() {
        this._timer = setInterval(() => { this.now = Date.now(); }, 1000);
    }
    disconnectedCallback() {
        if (this._timer) { clearInterval(this._timer); }
    }

    get hasInfo() { return this.info != null; }

    get milestones() {
        if (!this.info || !this.info.milestones) { return []; }
        return this.info.milestones.map((m) => {
            const target = m.targetDate ? new Date(m.targetDate).getTime() : null;
            let countdown = '';
            let countdownClass = 'countdown';
            if (m.isCompleted) {
                countdown = m.completionDate ? 'Met ' + new Date(m.completionDate).toLocaleString() : 'Met';
                countdownClass = 'countdown met';
            } else if (target) {
                const diff = target - this.now;
                if (diff <= 0) { countdown = 'Overdue by ' + this.dur(-diff); countdownClass = 'countdown overdue'; }
                else { countdown = this.dur(diff) + ' left'; countdownClass = diff < 3600000 ? 'countdown soon' : 'countdown'; }
            }
            const badgeClass = 'slds-badge slds-m-left_x-small ' +
                (m.variant === 'success' ? 'slds-theme_success' : m.variant === 'error' ? 'slds-theme_error' : 'slds-badge_inverse');
            return { name: m.name, status: m.status, countdown, countdownClass, badgeClass };
        });
    }

    dur(ms) {
        const s = Math.floor(ms / 1000);
        const d = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        const m = Math.floor((s % 3600) / 60);
        const sec = s % 60;
        if (d > 0) { return `${d}d ${h}h ${m}m`; }
        if (h > 0) { return `${h}h ${m}m ${sec}s`; }
        return `${m}m ${sec}s`;
    }

    get accountUrl() { return this.info && this.info.accountId ? '/' + this.info.accountId : null; }
    get orderUrl() { return this.info && this.info.orderId ? '/' + this.info.orderId : null; }
    get contractUrl() { return this.info && this.info.contractId ? '/' + this.info.contractId : null; }
}
