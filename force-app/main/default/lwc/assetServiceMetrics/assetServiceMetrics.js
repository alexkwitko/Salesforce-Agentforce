import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMetrics from '@salesforce/apex/AssetServiceMetricsService.getMetrics';
import refreshMetrics from '@salesforce/apex/AssetServiceMetricsService.refreshMetrics';

const DASH = '—';

export default class AssetServiceMetrics extends LightningElement {
    @api recordId;

    metrics;
    error;
    loading = false;
    _wired;

    @wire(getMetrics, { recordId: '$recordId' })
    wiredMetrics(result) {
        this._wired = result;
        if (result.data) {
            this.metrics = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = this.reduceError(result.error);
        }
    }

    get hasAsset() {
        return !!(this.metrics && this.metrics.hasAsset);
    }
    get noAsset() {
        return !!(this.metrics && !this.metrics.hasAsset);
    }
    get hasError() {
        return !!this.error;
    }

    // ---- display getters (offline rule: keep template logic in getters) ----
    get callRateDisplay() {
        return this.numOrDash(this.metrics && this.metrics.callRate);
    }
    get ftftDisplay() {
        const v = this.metrics && this.metrics.fixRightFirstTime;
        return v === null || v === undefined ? DASH : `${v}%`;
    }
    get mttrDisplay() {
        return this.numOrDash(this.metrics && this.metrics.mttrDays);
    }
    get repeatDisplay() {
        return this.metrics ? this.metrics.repeatVisits : DASH;
    }
    get totalDisplay() {
        return this.metrics ? this.metrics.totalCalls : DASH;
    }
    get openDisplay() {
        return this.metrics ? this.metrics.openWorkOrders : DASH;
    }

    // FTFT colour band
    get ftftClass() {
        const v = this.metrics && this.metrics.fixRightFirstTime;
        let c = 'kpi-value';
        if (v === null || v === undefined) return `${c} kpi-neutral`;
        if (v >= 90) return `${c} kpi-good`;
        if (v >= 75) return `${c} kpi-warn`;
        return `${c} kpi-bad`;
    }
    get openClass() {
        const v = this.metrics ? this.metrics.openWorkOrders : 0;
        return v > 0 ? 'kpi-value kpi-warn' : 'kpi-value';
    }

    get statusBadgeClass() {
        return 'slds-badge slds-m-left_x-small';
    }

    handleRefresh() {
        this.loading = true;
        refreshMetrics({ recordId: this.recordId })
            .then(() => refreshApex(this._wired))
            .then(() => this.toast('Asset Metrics', 'Reliability metrics recalculated.', 'success'))
            .catch((e) => this.toast('Error', this.reduceError(e), 'error'))
            .finally(() => {
                this.loading = false;
            });
    }

    numOrDash(v) {
        return v === null || v === undefined ? DASH : v;
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    reduceError(e) {
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return 'Unknown error';
    }
}
