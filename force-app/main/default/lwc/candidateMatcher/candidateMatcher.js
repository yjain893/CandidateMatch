import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOptions from '@salesforce/apex/CandidateMatcherController.getOptions';
import getJobFilters from '@salesforce/apex/CandidateMatcherController.getJobFilters';
import startMatching from '@salesforce/apex/CandidateMatcherController.startMatching';
import getResults from '@salesforce/apex/CandidateMatcherController.getResults';

const POLL_MS = 5000;
const MAX_POLLS = 360; // 30 minutes

export default class CandidateMatcher extends LightningElement {
    jobId;
    workModeOptions = [];
    roleOptions = [];

    // filter values (pre-filled from the job, editable by the user)
    workModes = [];
    cities = '';
    maxSalary = null;
    roles = [];

    rows = [];
    summary = '';
    startNote = '';
    busy = false;
    runKey;
    polls = 0;
    timer;

    columns = [
        { label: 'Candidate', fieldName: 'nameUrl', type: 'url', initialWidth: 180,
          typeAttributes: { label: { fieldName: 'name' }, target: '_blank' } },
        { label: 'Score', fieldName: 'score', type: 'number', initialWidth: 80 },
        { label: 'Status', fieldName: 'status', wrapText: true, initialWidth: 190 },
        { label: 'Why', fieldName: 'reasoning', wrapText: true }
    ];

    connectedCallback() {
        getOptions()
            .then((o) => {
                this.workModeOptions = o.workModes;
                this.roleOptions = o.roleTypes;
            })
            .catch((e) => this.toast('Could not load filter options', this.message(e), 'error'));
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    get applyDisabled() {
        return !this.jobId || this.busy;
    }
    get hasRows() {
        return this.rows.length > 0;
    }

    // ----- job lookup: pre-fills the filters -----
    handleJobChange(event) {
        this.jobId = event.detail.recordId;
        this.stopPolling();
        this.rows = [];
        this.summary = '';
        this.startNote = '';
        if (!this.jobId) {
            this.handleClear();
            return;
        }
        getJobFilters({ jobId: this.jobId })
            .then((f) => {
                this.workModes = f.workModes || [];
                this.cities = f.city || '';
                this.maxSalary = f.maxSalary === undefined ? null : f.maxSalary;
                this.roles = f.roleTypes || [];
            })
            .catch((e) => this.toast('Could not read the job', this.message(e), 'error'));
    }

    // ----- filter edits (do not touch the job record) -----
    handleWorkModes(event) { this.workModes = event.detail.value; }
    handleCities(event) { this.cities = event.detail.value; }
    handleSalary(event) {
        const v = event.detail.value;
        this.maxSalary = v === '' || v === null || v === undefined ? null : Number(v);
    }
    handleRoles(event) { this.roles = event.detail.value; }

    handleClear() {
        this.workModes = [];
        this.cities = '';
        this.maxSalary = null;
        this.roles = [];
    }

    // ----- Apply filters -----
    handleApply() {
        this.busy = true;
        this.stopPolling();
        this.rows = [];
        const filters = {
            workModes: this.workModes,
            cities: this.cities,
            maxSalary: this.maxSalary,
            roleTypes: this.roles
        };
        startMatching({ jobId: this.jobId, filtersJson: JSON.stringify(filters) })
            .then((r) => {
                this.runKey = r.runKey;
                const hint = r.notParsed
                    ? `${r.notParsed} more candidates match the filters but their resumes are not parsed yet (or need review), so they are not shown`
                    : '';
                if (r.matched === 0) {
                    this.summary = 'No candidates with a parsed resume match these filters.';
                    this.startNote = hint ? `${hint}.` : '';
                    return;
                }
                this.startNote =
                    `${r.toScore} are being scored, ${r.cached} reused up-to-date scores` +
                    (hint ? `. ${hint}` : '') +
                    (r.capped ? `. Only the first ${r.cap} candidates were used: narrow the filters to see others.` : '.');
                this.polls = 0;
                this.poll();
            })
            .catch((e) => this.toast('Could not start matching', this.message(e), 'error'))
            .finally(() => { this.busy = false; });
    }

    poll() {
        getResults({ runKey: this.runKey })
            .then((res) => {
                this.rows = res.rows;
                this.summary = `${res.total} candidates | ${res.scored} scored | ${res.inProgress} in progress`;
                if (!res.done && this.polls < MAX_POLLS) {
                    this.polls += 1;
                    this.timer = setTimeout(() => this.poll(), POLL_MS);
                }
            })
            .catch((e) => this.toast('Could not load results', this.message(e), 'error'));
    }

    stopPolling() {
        if (this.timer) {
            clearTimeout(this.timer);
            this.timer = null;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unknown error';
    }
}
