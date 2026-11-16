import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOptions from '@salesforce/apex/CandidateMatcherController.getOptions';
import getJobFilters from '@salesforce/apex/CandidateMatcherController.getJobFilters';
import startMatching from '@salesforce/apex/CandidateMatcherController.startMatching';
import getResults from '@salesforce/apex/CandidateMatcherController.getResults';

const POLL_MS = 4000;
const MAX_POLLS = 450;            // 30 minutes at 4 seconds
const SLOW_AFTER_MS = 120000;     // no candidate finished for 2 minutes: tell the user it is slow
const PENDING = ['Queued for scoring', 'Scoring', 'Reading resume'];

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

    // progress feedback while candidates are scored in the background
    phase = 'idle';               // idle | preparing | scoring | done | stopped
    total = 0;
    finished = 0;                 // candidates that are no longer waiting (scored or failed)
    scoredCount = 0;
    failedCount = 0;
    inProgress = 0;
    elapsedText = '0:00';
    etaText = '';
    slow = false;
    runStartedAt = 0;
    scoringStartedAt = 0;
    initialFinished = 0;
    lastFinished = 0;
    lastProgressAt = 0;
    tickTimer;

    columns = [
        { label: 'Candidate', fieldName: 'nameUrl', type: 'url', initialWidth: 180,
          typeAttributes: { label: { fieldName: 'name' }, target: '_blank' } },
        { label: 'Score', fieldName: 'scoreText', type: 'text', initialWidth: 80,
          cellAttributes: { alignment: 'right', class: { fieldName: 'scoreClass' } } },
        { label: 'Status', fieldName: 'statusLabel', wrapText: true, initialWidth: 210,
          cellAttributes: { iconName: { fieldName: 'statusIcon' }, iconPosition: 'left',
                            iconAlternativeText: { fieldName: 'statusLabel' }, class: { fieldName: 'statusClass' } } },
        { label: 'Why', fieldName: 'why', wrapText: true, cellAttributes: { class: { fieldName: 'whyClass' } } }
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
        this.stopTicking();
    }

    // ----- state used by the template -----
    get isRunning() {
        return this.phase === 'preparing' || this.phase === 'scoring';
    }
    get isScoring() {
        return this.phase === 'scoring';
    }
    get showPanel() {
        return this.phase !== 'idle';
    }
    get showTime() {
        return this.isRunning || this.phase === 'done';
    }
    get applyDisabled() {
        return !this.jobId || this.busy || this.isRunning;
    }
    get applyLabel() {
        return this.isRunning ? 'Scoring...' : 'Apply filters';
    }
    get hasRows() {
        return this.rows.length > 0;
    }
    get showPlaceholder() {
        return !this.hasRows && !this.summary && !this.showPanel;
    }

    get progressValue() {
        return this.total ? Math.round((this.finished * 100) / this.total) : 0;
    }
    get progressLabel() {
        return `${this.finished} of ${this.total} candidates done`;
    }
    get timeText() {
        return this.etaText ? `Elapsed ${this.elapsedText} · ${this.etaText}` : `Elapsed ${this.elapsedText}`;
    }

    get headline() {
        switch (this.phase) {
            case 'preparing': return 'Getting ready...';
            case 'scoring': return `Scoring ${this.total} candidate${this.total === 1 ? '' : 's'} in the background`;
            case 'done': return this.failedCount ? 'Scoring finished, with some problems' : 'Scoring complete';
            case 'stopped': return 'Stopped waiting for results';
            default: return '';
        }
    }
    get subline() {
        switch (this.phase) {
            case 'preparing':
                return 'Reading the job requirements and finding the candidates that match your filters.';
            case 'scoring':
                return 'The AI is reading each resume and comparing it with the job. You can stay on this page: results appear below automatically, so there is no need to refresh.';
            case 'done':
                return this.failedCount
                    ? `${this.scoredCount} of ${this.total} candidates scored, ${this.failedCount} could not be scored. The reason is shown in the Status and Why columns.`
                    : `All ${this.total} candidates were scored. Click a name to open the candidate.`;
            case 'stopped':
                return 'Scoring is taking longer than expected, or the results could not be loaded. Click Apply filters to check again.';
            default: return '';
        }
    }
    get slowNote() {
        return 'This is taking longer than usual. The AI service may be busy. If a candidate fails, the reason is shown in the Status and Why columns.';
    }

    get panelClass() {
        let cls = `panel slds-m-bottom_small panel_${this.phase}`;
        if (this.phase === 'done' && this.failedCount) {
            cls += ' panel_warn';
        }
        return cls;
    }
    get endIconName() {
        if (this.phase === 'done') {
            return this.failedCount ? 'utility:warning' : 'utility:success';
        }
        return 'utility:warning';
    }
    get endIconVariant() {
        return this.phase === 'done' && !this.failedCount ? 'success' : 'warning';
    }

    // ----- job lookup: pre-fills the filters -----
    handleJobChange(event) {
        this.jobId = event.detail.recordId;
        this.stopPolling();
        this.resetRun();
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
        this.summary = '';
        this.startNote = '';
        this.beginRun();
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
                    this.resetRun();
                    this.summary = 'No candidates with a parsed resume match these filters.';
                    this.startNote = hint ? `${hint}.` : '';
                    return;
                }
                // Only warnings are shown here (no "N are being scored / reused" counts)
                const notes = [];
                if (hint) { notes.push(hint); }
                if (r.capped) { notes.push(`Only the first ${r.cap} candidates were used: narrow the filters to see others`); }
                this.startNote = notes.length ? `${notes.join('. ')}.` : '';
                this.polls = 0;
                this.poll();
            })
            .catch((e) => {
                this.resetRun();
                this.toast('Could not start matching', this.message(e), 'error');
            })
            .finally(() => { this.busy = false; });
    }

    poll() {
        getResults({ runKey: this.runKey })
            .then((res) => {
                this.rows = res.rows.map((r) => this.decorate(r));
                this.summary = `${res.total} candidates | ${res.scored} scored | ${res.inProgress} in progress`;
                this.total = res.total;
                this.inProgress = res.inProgress;
                this.finished = res.total - res.inProgress;
                this.scoredCount = res.scored;
                this.failedCount = res.rows.filter((r) => (r.status || '').startsWith('Failed')).length;

                if (this.phase === 'preparing') {
                    this.phase = 'scoring';
                    this.scoringStartedAt = Date.now();
                    this.initialFinished = this.finished;     // scores that were already up to date do not count as work done
                    this.lastFinished = this.finished;
                    this.lastProgressAt = Date.now();
                }
                if (this.finished > this.lastFinished) {
                    this.lastFinished = this.finished;
                    this.lastProgressAt = Date.now();
                }
                this.tick();

                if (res.done) {
                    this.finishRun();
                } else if (this.polls < MAX_POLLS) {
                    this.polls += 1;
                    this.timer = setTimeout(() => this.poll(), POLL_MS);
                } else {
                    this.phase = 'stopped';
                    this.stopTicking();
                }
            })
            .catch((e) => {
                this.phase = 'stopped';
                this.stopTicking();
                this.toast('Could not load results', this.message(e), 'error');
            });
    }

    stopPolling() {
        if (this.timer) {
            clearTimeout(this.timer);
            this.timer = null;
        }
    }

    // ----- progress feedback -----
    beginRun() {
        const now = Date.now();
        this.phase = 'preparing';
        this.total = 0;
        this.finished = 0;
        this.scoredCount = 0;
        this.failedCount = 0;
        this.inProgress = 0;
        this.etaText = '';
        this.slow = false;
        this.runStartedAt = now;
        this.lastProgressAt = now;
        this.elapsedText = '0:00';
        this.stopTicking();
        this.tickTimer = setInterval(() => this.tick(), 1000);
    }

    resetRun() {
        this.phase = 'idle';
        this.slow = false;
        this.etaText = '';
        this.stopTicking();
    }

    finishRun() {
        this.tick();
        this.phase = 'done';
        this.slow = false;
        this.etaText = '';
        this.stopTicking();
        if (this.failedCount) {
            this.toast('Scoring finished',
                `${this.scoredCount} of ${this.total} candidates scored, ${this.failedCount} could not be scored. See the Status and Why columns.`,
                'warning');
        } else {
            this.toast('Scoring complete', `All ${this.total} candidates were scored in ${this.elapsedText}.`, 'success');
        }
    }

    stopTicking() {
        if (this.tickTimer) {
            clearInterval(this.tickTimer);
            this.tickTimer = null;
        }
    }

    tick() {
        const now = Date.now();
        this.elapsedText = this.formatTime(Math.floor((now - this.runStartedAt) / 1000));
        this.slow = this.phase === 'scoring' && this.inProgress > 0 && now - this.lastProgressAt > SLOW_AFTER_MS;
        this.etaText = this.estimate(now);
    }

    /** Rough time left, from how fast candidates finished since scoring started. Empty until there is enough to go on. */
    estimate(now) {
        const doneSince = this.finished - this.initialFinished;
        const secondsSince = (now - this.scoringStartedAt) / 1000;
        if (this.phase !== 'scoring' || this.inProgress === 0 || doneSince < 2 || secondsSince < 15) {
            return '';
        }
        const secondsLeft = (this.inProgress * secondsSince) / doneSince;
        if (secondsLeft < 60) {
            return 'less than a minute left';
        }
        const minutes = Math.ceil(secondsLeft / 60);
        return minutes > 120 ? '' : `about ${minutes} min left`;
    }

    formatTime(totalSeconds) {
        const m = Math.floor(totalSeconds / 60);
        const s = totalSeconds % 60;
        return `${m}:${String(s).padStart(2, '0')}`;
    }

    /** Adds the display fields the table needs: a clear status, an icon and a friendly text for rows still waiting. */
    decorate(r) {
        const st = r.status || '';
        const pending = PENDING.includes(st);
        const failed = st.startsWith('Failed');
        const attention = st.startsWith('Needs review') || st === 'Scored (please check)';
        let statusLabel = st;
        let statusIcon = 'utility:success';
        let statusClass = '';
        if (pending) {
            statusLabel = 'Waiting to be scored';
            statusIcon = 'utility:clock';
            statusClass = 'slds-text-color_weak';
        } else if (failed) {
            statusIcon = 'utility:error';
            statusClass = 'slds-text-color_error';
        } else if (attention) {
            statusIcon = 'utility:warning';
        }
        let scoreText = '';
        if (pending) {
            scoreText = '—';
        } else if (r.score !== null && r.score !== undefined) {
            scoreText = String(r.score);
        }
        return {
            ...r,
            statusLabel,
            statusIcon,
            statusClass,
            scoreText,
            scoreClass: pending ? 'slds-text-color_weak' : '',
            why: pending ? 'In the queue. This row updates by itself as soon as the AI has scored the candidate.' : r.reasoning,
            whyClass: pending ? 'slds-text-color_weak' : ''
        };
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unknown error';
    }
}
