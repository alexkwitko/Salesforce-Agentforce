import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getBarcodeScanner } from 'lightning/mobileCapabilities';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import aiSummary from '@salesforce/apex/FieldVisitToolkit.aiSummary';
import collectPayment from '@salesforce/apex/FieldVisitToolkit.collectPayment';
import createLaborQuote from '@salesforce/apex/FieldVisitToolkit.createLaborQuote';
import createServiceReport from '@salesforce/apex/FieldVisitToolkit.createServiceReport';
import matchAssetBySerial from '@salesforce/apex/FieldVisitToolkit.matchAssetBySerial';
import WONUM from '@salesforce/schema/WorkOrder.WorkOrderNumber';
import SUBJECT from '@salesforce/schema/WorkOrder.Subject';
import STATUS from '@salesforce/schema/WorkOrder.Status';
import ACCT from '@salesforce/schema/WorkOrder.Account.Name';
import PAY from '@salesforce/schema/WorkOrder.Payment_Status__c';

const FIELDS = [WONUM, SUBJECT, STATUS, ACCT, PAY];

export default class FsVisitAssistant extends LightningElement {
    @api recordId;
    aiText; resultMsg; error; loading = false;
    payAmount; quoteHours = 2; quoteRate = 95;
    scanner;

    connectedCallback() { this.scanner = getBarcodeScanner(); }
    get scanAvailable() { return this.scanner && this.scanner.isAvailable(); }

    // Offline-safe display via LDS
    @wire(getRecord, { recordId: '$recordId', fields: FIELDS }) wo;
    get workOrderNumber() { return getFieldValue(this.wo.data, WONUM); }
    get subject() { return getFieldValue(this.wo.data, SUBJECT); }
    get status() { return getFieldValue(this.wo.data, STATUS); }
    get accountName() { return getFieldValue(this.wo.data, ACCT); }
    get paymentStatus() { return getFieldValue(this.wo.data, PAY) || 'Unpaid'; }
    get hasAi() { return this.aiText != null; }
    get hasResult() { return this.resultMsg != null; }

    handlePayAmount(e) { this.payAmount = e.target.value; }
    handleHours(e) { this.quoteHours = e.target.value; }

    brief() { this.runAi('brief'); }
    notes() { this.runAi('notes'); }
    runAi(mode) {
        this.start(); this.aiText = undefined;
        aiSummary({ workOrderId: this.recordId, mode })
            .then((r) => { this.aiText = r; })
            .catch((e) => this.fail(e)).finally(() => { this.loading = false; });
    }
    pay() {
        if (!this.payAmount) { this.toast('Enter an amount first', 'error'); return; }
        this.start();
        collectPayment({ workOrderId: this.recordId, amount: parseFloat(this.payAmount) })
            .then((a) => { this.resultMsg = 'Payment collected: $' + a; this.toast('Payment collected $' + a, 'success'); })
            .catch((e) => this.fail(e)).finally(() => { this.loading = false; });
    }
    quote() {
        this.start();
        createLaborQuote({ workOrderId: this.recordId, hours: parseFloat(this.quoteHours), rate: parseFloat(this.quoteRate) })
            .then((t) => { this.resultMsg = 'Quote created — total $' + t; this.toast('Quote $' + t, 'success'); })
            .catch((e) => this.fail(e)).finally(() => { this.loading = false; });
    }
    report() {
        this.start();
        createServiceReport({ workOrderId: this.recordId })
            .then((id) => { this.resultMsg = id ? 'Service report created (' + id + ')' : 'Report not generated'; if (id) this.toast('Service report created', 'success'); })
            .catch((e) => this.fail(e)).finally(() => { this.loading = false; });
    }
    scan() {
        if (!this.scanAvailable) { this.toast('Barcode scanner is only available in the mobile app', 'warning'); return; }
        this.start();
        this.scanner.beginCapture({ barcodeTypes: [this.scanner.barcodeTypes.QR, this.scanner.barcodeTypes.CODE_128] })
            .then((res) => matchAssetBySerial({ serialNumber: res.value })
                .then((name) => { this.resultMsg = name ? 'Asset matched: ' + name + ' (SN ' + res.value + ')' : 'No asset found for SN ' + res.value; }))
            .catch(() => { this.toast('Scan cancelled', 'warning'); })
            .finally(() => { this.scanner.endCapture(); this.loading = false; });
    }
    start() { this.loading = true; this.error = undefined; this.resultMsg = undefined; }
    fail(e) { this.error = (e && e.body && e.body.message) ? e.body.message : 'Action failed — AI/payment/quote need connectivity.'; }
    toast(m, v) { this.dispatchEvent(new ShowToastEvent({ message: m, variant: v })); }
}
