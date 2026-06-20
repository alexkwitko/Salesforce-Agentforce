import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import assist from '@salesforce/apex/CaseSummaryAI.assist';

export default class CaseAssistant extends LightningElement {
    @api recordId;
    aiText;
    loading = false;
    mode;

    get hasAi() {
        return this.aiText != null;
    }
    get heading() {
        return this.mode === 'reply' ? 'Draft reply (edit before sending)' : 'Case summary (edit before saving)';
    }

    summarize() {
        this.run('summary');
    }
    draftReply() {
        this.run('reply');
    }

    run(mode) {
        this.loading = true;
        this.aiText = undefined;
        this.mode = mode;
        assist({ caseId: this.recordId, mode })
            .then((r) => {
                this.aiText = r;
            })
            .catch((e) => {
                const msg = e && e.body && e.body.message ? e.body.message : 'Generation failed';
                this.dispatchEvent(new ShowToastEvent({ title: 'Einstein', message: msg, variant: 'error' }));
            })
            .finally(() => {
                this.loading = false;
            });
    }
}
