import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOptions from '@salesforce/apex/CandidateMatcherController.getOptions';
import getJobFilters from '@salesforce/apex/CandidateMatcherController.getJobFilters';
import startMatching from '@salesforce/apex/CandidateMatcherController.startMatching';
import countMatches from '@salesforce/apex/CandidateMatcherV2Controller.countMatches';
import getJobSkills from '@salesforce/apex/CandidateMatcherV2Controller.getJobSkills';
import getResults from '@salesforce/apex/CandidateMatcherV2Controller.getResults';

const POLL_MS = 4000;
const MAX_POLLS = 450;              // 30 minutes at 4 seconds
const SLOW_AFTER_MS = 120000;       // no candidate finished for 2 minutes: tell the user it is slow
const COUNT_DEBOUNCE_MS = 350;      // wait until the user stops changing filters before counting
const SECONDS_PER_CANDIDATE = 5;    // placeholder for "About N min to score": set it to the real measured seconds per candidate
const PENDING = ['Queued for scoring', 'Scoring', 'Reading resume'];
const MODE_ICONS = { Remote: 'utility:home', 'On-site': 'utility:company', Hybrid: 'utility:sync' };
const DATE_WINDOWS = [                // days from today, same values as CandidateMatcherV2Controller.DATE_WINDOWS
    { days: 0, label: 'Immediately' },
    { days: 14, label: 'Within 2 weeks' },
    { days: 31, label: 'Within 1 month' },
    { days: 62, label: 'Within 2 months' }
];
const GREEN = '#2e844a';
const AMBER = '#fe9339';
const GREY = '#9a9ea3';

export default class CandidateMatcherV2 extends NavigationMixin(LightningElement) {
    // ----- filters (pre-filled from the job, editable by the user) -----
    jobId;
    jobLoading = false;
    workModeOptions = [];
    roleOptions = [];
    workModes = [];
    cities = '';
    maxSalary = null;
    roles = [];
    rolesOpen = false;
    roleSearch = '';

    // ----- skills (listed from the job, required ones start selected) and date available -----
    requiredSkills = [];
    niceSkills = [];
    selectedSkills = [];
    availableDays = null;           // null = any date, 0 = available now, 14 = within 2 weeks ...

    // ----- live "N candidates match" and the number next to every skill and date -----
    matchCount = 0;
    matchKnown = false;             // false: cannot be counted because too many candidates fit the other filters
    poolCount = 0;                  // fit the work mode, city, salary and role filters
    skillMatched = 0;               // also have every selected skill (before the date)
    facetsKnown = false;
    tooBroad = false;
    skillFacets = {};               // skill name -> candidates left if it were added (selected: left if it were removed)
    dateFacets = {};                // days -> candidates with the selected skills available within that many days
    notParsed = 0;
    cappedCount = false;
    cap = 200;
    counting = false;
    countKnown = false;
    countTimer;
    countSeq = 0;

    // ----- results -----
    rawRows = [];
    total = 0;
    finished = 0;                   // candidates that are no longer waiting (scored or failed)
    scoredCount = 0;
    failedCount = 0;
    inProgress = 0;
    startNote = '';
    emptyMessage = '';
    busy = false;
    runKey;
    polls = 0;
    timer;

    // ----- progress feedback while candidates are scored in the background -----
    phase = 'idle';                 // idle | preparing | scoring | done | stopped
    elapsedText = '0:00';
    etaText = '';
    slow = false;
    runStartedAt = 0;
    scoringStartedAt = 0;
    initialFinished = 0;
    lastFinished = 0;
    lastProgressAt = 0;
    tickTimer;

    // ----- how the list is shown -----
    search = '';
    sort = 'best';
    openId = null;

    sortOptions = [
        { label: 'Best match', value: 'best' },
        { label: 'Most experience', value: 'exp' },
        { label: 'Lowest salary', value: 'sal' }
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
        clearTimeout(this.countTimer);
    }

    // =====================================================================================================
    //  Filter panel
    // =====================================================================================================
    get workModeTiles() {
        return this.workModeOptions.map((o) => {
            const selected = this.workModes.includes(o.value);
            return {
                value: o.value,
                label: o.label,
                icon: MODE_ICONS[o.value] || 'utility:user',
                className: selected ? 'tile tile-on' : 'tile',
                pressed: String(selected)
            };
        });
    }
    get roleRows() {
        const q = this.roleSearch.trim().toLowerCase();
        return this.roleOptions
            .filter((o) => !q || o.label.toLowerCase().includes(q))
            .map((o) => {
                const selected = this.roles.includes(o.value);
                return {
                    value: o.value,
                    label: o.label,
                    className: selected ? 'option option-on' : 'option',
                    ariaSelected: String(selected)
                };
            });
    }
    get noRoleRows() {
        return this.roleRows.length === 0;
    }
    get roleChips() {
        return this.roles.map((r) => {
            const opt = this.roleOptions.find((o) => o.value === r);
            const label = opt ? opt.label : r;
            return { value: r, label, removeLabel: `Remove ${label}` };
        });
    }
    get hasRoles() {
        return this.roles.length > 0;
    }
    get roleCount() {
        return String(this.roles.length);
    }
    get roleButtonLabel() {
        return this.hasRoles ? 'Select more roles' : 'Select role types';
    }
    get rolesExpanded() {
        return String(this.rolesOpen);
    }
    get filtersJson() {
        return JSON.stringify({
            workModes: this.workModes,
            cities: this.cities,
            maxSalary: this.maxSalary,
            roleTypes: this.roles,
            jobId: this.jobId,                                            // the server reads this job's skill map (other names for each skill)
            skills: this.selectedSkills,
            skillOptions: [...this.requiredSkills, ...this.niceSkills],   // so the server can count every skill on screen
            availableWithinDays: this.availableDays
        });
    }
    get applyDisabled() {
        return !this.jobId || this.busy || this.isRunning || this.skillsBlocked || this.noMatches;
    }
    /** Everything was counted and nobody matches: the screen explains why instead of showing zeros. */
    get noMatches() {
        return this.countKnown && this.matchKnown && this.matchCount === 0;
    }
    /** Candidates fit the other filters, skills are selected, and not one candidate has all of them. */
    get skillsEmptyTheList() {
        return this.facetsKnown && this.poolCount > 0 && this.selectedSkills.length > 0 && this.skillMatched === 0;
    }
    get applyLabel() {
        return this.isRunning ? 'Scoring...' : 'Apply filters';
    }
    /** Skills are selected but there are too many candidates to check them: the filters must be narrowed first. */
    get skillsBlocked() {
        return this.countKnown && this.tooBroad && this.selectedSkills.length > 0;
    }
    get notParsedText() {
        return !this.counting && this.countKnown && this.notParsed
            ? `${this.notParsed} more match but their resumes are not parsed yet.`
            : '';
    }

    // ----- the count and what it is made of (pinned above the buttons) -----
    get showSummary() {
        return !!this.jobId && (this.countKnown || this.counting);
    }
    get summaryClass() {
        if (this.counting) {
            return 'sum sum-busy';
        }
        return this.noMatches ? 'sum sum-none' : 'sum';
    }
    get summaryNumber() {
        if (!this.countKnown || this.noMatches) {
            return '';
        }
        return this.formatCount(this.matchKnown ? this.matchCount : this.poolCount);
    }
    get summaryLabel() {
        if (!this.countKnown) {
            return 'Counting...';
        }
        if (this.noMatches) {
            return 'No candidates match all of these filters';
        }
        if (!this.matchKnown) {
            return 'candidates fit your other filters';
        }
        return this.matchCount === 1 ? 'candidate matches' : 'candidates match';
    }
    get summarySub() {
        if (!this.countKnown) {
            return '';
        }
        if (!this.matchKnown) {
            return 'That is too many to check their skills. Narrow the city, work mode, salary or role types.';
        }
        if (this.noMatches) {
            return this.noMatchReason;
        }
        return `of ${this.formatCount(this.poolCount)} that fit your other filters`;
    }
    /** Which filter empties the list: the other filters, the skills, or the date. */
    get noMatchReason() {
        if (this.poolCount === 0) {
            return 'Nobody fits the work mode, city, salary and role filters. Loosen one of them.';
        }
        const fit = `${this.formatCount(this.poolCount)} ${this.poolCount === 1 ? 'candidate fits' : 'candidates fit'} your other filters`;
        const haveSkills = this.selectedSkills.length > 0 && this.facetsKnown;
        if (haveSkills && this.skillMatched === 0) {
            return `${fit}, but none has every selected skill.`;
        }
        if (this.availableDays !== null) {
            return haveSkills
                ? `${this.formatCount(this.skillMatched)} have every selected skill, but none is available by that date.`
                : `${fit}, but none is available by that date.`;
        }
        return `${fit}, but none matches the rest.`;
    }
    get summaryTime() {
        if (!this.countKnown || !this.matchKnown || this.matchCount === 0) {
            return '';
        }
        const seconds = Math.min(this.matchCount, this.cap) * SECONDS_PER_CANDIDATE;
        return `About ${Math.max(1, Math.round(seconds / 60))} min to score`;
    }
    get capWarnText() {
        return this.countKnown && this.cappedCount
            ? `${this.cap}+ candidates match. Only the first ${this.cap} will be scored.`
            : '';
    }

    // ----- skills -----
    get hasRequired() {
        return this.requiredSkills.length > 0;
    }
    get hasNice() {
        return this.niceSkills.length > 0;
    }
    get hasSkillRows() {
        return this.hasRequired || this.hasNice;
    }
    get skillsEmptyText() {
        if (!this.jobId) {
            return 'Pick a job to load its skills.';
        }
        return this.jobLoading
            ? 'Loading skills...'
            : 'No skills have been read from this job yet. They are extracted from the job description in the background.';
    }
    get countColumnHeader() {
        if (!this.facetsKnown || !this.matchKnown) {
            return '';
        }
        return this.noMatches ? '' : 'Candidates who have it';
    }
    get requiredRows() {
        return this.skillRows(this.requiredSkills);
    }
    get niceRows() {
        return this.skillRows(this.niceSkills);
    }
    /**
     * One row per skill. Selected: "All 66" (everyone listed has it). Not selected: "35 of 66", the candidates that would be left
     * if it were added. The bar shows the same share.
     */
    skillRows(names) {
        const total = this.matchCount;
        const known = this.facetsKnown && this.matchKnown;
        return names.map((name) => {
            const selected = this.selectedSkills.includes(name);
            const n = this.skillFacets[name];
            if (this.noMatches && known) {
                // Nobody matches, so any number here is either 0 or contradicts the message: the rows show only the selection.
                return {
                    name,
                    className: selected ? 'srow srow-on' : 'srow',
                    pressed: String(selected),
                    countText: '',
                    showBar: false,
                    barStyle: 'width:0%',
                    title: name
                };
            }
            const hasNumber = known && n !== undefined;
            let countText = '';
            let width = selected ? 100 : 0;
            let title = name;
            if (hasNumber && selected) {
                countText = `All ${this.formatCount(total)}`;
                title = `All ${this.formatCount(total)} matching candidates have ${name}. Removing it would give ${this.formatCount(n)} candidates.`;
            } else if (hasNumber) {
                countText = `${this.formatCount(n)} of ${this.formatCount(total)}`;
                width = total > 0 ? Math.round((100 * n) / total) : 0;
                title = `${this.formatCount(n)} of the ${this.formatCount(total)} matching candidates have ${name}. Adding it leaves ${this.formatCount(n)}.`;
            }
            const zero = hasNumber && !selected && n === 0;
            return {
                name,
                className: selected ? 'srow srow-on' : zero ? 'srow srow-zero' : 'srow',
                pressed: String(selected),
                countText,
                showBar: true,
                barStyle: `width:${width}%`,
                title
            };
        });
    }

    // ----- date available -----
    get dateTiles() {
        // when nobody has every selected skill, every tile would say 0, so the tiles show no numbers at all
        const skillsEmptyTheList = this.skillsEmptyTheList || (this.facetsKnown && this.poolCount === 0);
        return DATE_WINDOWS.map((w) => {
            const selected = this.availableDays === w.days;
            const n = this.dateFacets[w.days];
            const hasNumber = !!this.jobId && this.facetsKnown && n !== undefined && !skillsEmptyTheList;
            const zero = hasNumber && !selected && n === 0;
            let title = '';
            if (hasNumber) {
                const day = new Date();
                day.setDate(day.getDate() + w.days);
                const dayText = day.toLocaleDateString('en-CA', { month: 'short', day: 'numeric' });
                title = `Available by ${dayText}: ${this.formatCount(n)} of the ${this.formatCount(this.skillMatched)} candidates who have your selected skills.`;
            }
            return {
                key: String(w.days),
                days: w.days,
                label: w.label,
                className: selected ? 'tile tile-on' : zero ? 'tile tile-zero' : 'tile',
                pressed: String(selected),
                disabled: !this.jobId,
                hasSub: hasNumber,
                sub: hasNumber ? `${this.formatCount(n)} ${n === 1 ? 'candidate' : 'candidates'}` : '',
                title
            };
        });
    }

    // ----- job lookup: pre-fills the filters and the skills -----
    handleJobChange(event) {
        this.jobId = event.detail.recordId;
        this.stopPolling();
        this.resetRun();
        this.rawRows = [];
        this.total = 0;
        this.finished = 0;
        this.scoredCount = 0;
        this.failedCount = 0;
        this.inProgress = 0;
        this.startNote = '';
        this.emptyMessage = '';
        this.openId = null;
        this.rolesOpen = false;
        this.requiredSkills = [];
        this.niceSkills = [];
        this.selectedSkills = [];
        this.availableDays = null;
        this.resetCounts();
        if (!this.jobId) {
            this.jobLoading = false;
            this.clearFilters();
            return;
        }
        const jobId = this.jobId;
        this.jobLoading = true;
        this.counting = true;
        Promise.all([getJobFilters({ jobId }), getJobSkills({ jobId })])
            .then(([f, s]) => {
                if (jobId !== this.jobId) {
                    return;                             // another job was picked in the meantime
                }
                this.workModes = f.workModes || [];
                this.cities = f.city || '';
                this.maxSalary = f.maxSalary === undefined ? null : f.maxSalary;
                this.roles = f.roleTypes || [];
                this.requiredSkills = s.required || [];
                this.niceSkills = s.niceToHave || [];
                this.selectedSkills = [...this.requiredSkills];     // the job's required skills start selected
                this.jobLoading = false;
                this.scheduleCount();
            })
            .catch((e) => {
                if (jobId === this.jobId) {
                    this.jobLoading = false;
                    this.counting = false;
                }
                this.toast('Could not read the job', this.message(e), 'error');
            });
    }

    // ----- filter edits (do not touch the job record) -----
    handleModeClick(event) {
        const value = event.currentTarget.dataset.value;
        this.workModes = this.workModes.includes(value)
            ? this.workModes.filter((m) => m !== value)
            : [...this.workModes, value];
        this.scheduleCount();
    }
    handleCities(event) {
        this.cities = event.detail.value;
        this.scheduleCount();
    }
    handleSalary(event) {
        const v = event.detail.value;
        this.maxSalary = v === '' || v === null || v === undefined ? null : Number(v);
        this.scheduleCount();
    }
    toggleRoles() {
        this.rolesOpen = !this.rolesOpen;
        this.roleSearch = '';
    }
    closeRoles() {
        this.rolesOpen = false;
        this.roleSearch = '';
    }
    handleRolesKey(event) {
        if (event.key === 'Escape') {
            this.closeRoles();
        }
    }
    handleRoleSearch(event) {
        this.roleSearch = event.detail.value || '';
    }
    handleRoleToggle(event) {
        const value = event.currentTarget.dataset.value;
        this.roles = this.roles.includes(value) ? this.roles.filter((r) => r !== value) : [...this.roles, value];
        this.scheduleCount();
    }
    handleRoleRemove(event) {
        const value = event.currentTarget.dataset.value;
        this.roles = this.roles.filter((r) => r !== value);
        this.scheduleCount();
    }
    handleSkillClick(event) {
        const name = event.currentTarget.dataset.name;
        this.selectedSkills = this.selectedSkills.includes(name)
            ? this.selectedSkills.filter((s) => s !== name)
            : [...this.selectedSkills, name];
        this.scheduleCount();
    }
    handleDateClick(event) {
        const days = Number(event.currentTarget.dataset.days);
        this.availableDays = this.availableDays === days ? null : days;     // click the selected one again to clear it
        this.scheduleCount();
    }
    handleClear() {
        this.clearFilters();
        this.scheduleCount();
    }
    clearFilters() {
        this.workModes = [];
        this.cities = '';
        this.maxSalary = null;
        this.roles = [];
        this.roleSearch = '';
        this.selectedSkills = [];
        this.availableDays = null;
    }

    // ----- live count (waits until the user stops changing filters) -----
    resetCounts() {
        clearTimeout(this.countTimer);
        this.countSeq += 1;
        this.counting = false;
        this.countKnown = false;
        this.matchCount = 0;
        this.matchKnown = false;
        this.poolCount = 0;
        this.skillMatched = 0;
        this.facetsKnown = false;
        this.tooBroad = false;
        this.skillFacets = {};
        this.dateFacets = {};
        this.notParsed = 0;
        this.cappedCount = false;
    }
    scheduleCount() {
        clearTimeout(this.countTimer);
        this.countSeq += 1;                        // anything still on its way is out of date now
        if (!this.jobId) {
            this.counting = false;
            this.countKnown = false;
            return;
        }
        this.counting = true;
        this.countTimer = setTimeout(() => this.runCount(), COUNT_DEBOUNCE_MS);
    }
    runCount() {
        this.countSeq += 1;
        const seq = this.countSeq;
        countMatches({ filtersJson: this.filtersJson })
            .then((r) => {
                if (seq !== this.countSeq) {
                    return;
                }
                this.matchKnown = r.matched !== null && r.matched !== undefined;
                this.matchCount = this.matchKnown ? r.matched : 0;
                this.poolCount = r.pool || 0;
                this.skillMatched = r.skillMatched || 0;
                this.facetsKnown = r.facets === true;
                this.tooBroad = r.tooBroad === true;
                const bySkill = {};
                (r.skills || []).forEach((s) => { bySkill[s.name] = s.count; });
                this.skillFacets = bySkill;
                const byDays = {};
                (r.dates || []).forEach((d) => { byDays[d.days] = d.count; });
                this.dateFacets = byDays;
                this.notParsed = r.notParsed;
                this.cappedCount = r.capped;
                this.cap = r.cap || this.cap;
                this.counting = false;
                this.countKnown = true;
            })
            .catch(() => {
                if (seq === this.countSeq) {
                    this.counting = false;
                    this.countKnown = false;
                }
            });
    }

    // =====================================================================================================
    //  Apply filters, scoring and polling
    // =====================================================================================================
    handleApply() {
        this.busy = true;
        this.rolesOpen = false;
        this.stopPolling();
        this.rawRows = [];
        this.total = 0;
        this.openId = null;
        this.search = '';
        this.sort = 'best';
        this.startNote = '';
        this.emptyMessage = '';
        this.beginRun();
        startMatching({ jobId: this.jobId, filtersJson: this.filtersJson })
            .then((r) => {
                this.runKey = r.runKey;
                const hint = r.notParsed
                    ? `${r.notParsed} more candidates match the filters but their resumes are not parsed yet (or need review), so they are not shown`
                    : '';
                if (r.matched === 0) {
                    this.resetRun();
                    this.emptyMessage = 'No candidates with a parsed resume match these filters.';
                    this.startNote = hint ? `${hint}.` : '';
                    return;
                }
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
                this.rawRows = res.rows;
                this.total = res.total;
                this.inProgress = res.inProgress;
                this.finished = res.total - res.inProgress;
                this.scoredCount = res.scored;
                this.failedCount = res.failed;

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

    // ----- progress panel state -----
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
                    ? `${this.scoredCount} of ${this.total} candidates scored, ${this.failedCount} could not be scored. Open a candidate's details to see why.`
                    : `All ${this.total} candidates were scored. Click a name to open the candidate.`;
            case 'stopped':
                return 'Scoring is taking longer than expected, or the results could not be loaded. Click Apply filters to check again.';
            default: return '';
        }
    }
    get slowNote() {
        return 'This is taking longer than usual. The AI service may be busy. If a candidate fails, the reason is shown in their details.';
    }
    get panelClass() {
        let cls = `panel panel-${this.phase}`;
        if (this.phase === 'done' && this.failedCount) {
            cls += ' panel-warn';
        }
        return cls;
    }
    get endIconName() {
        return this.phase === 'done' && !this.failedCount ? 'utility:success' : 'utility:warning';
    }
    get endIconVariant() {
        return this.phase === 'done' && !this.failedCount ? 'success' : 'warning';
    }

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
                `${this.scoredCount} of ${this.total} candidates scored, ${this.failedCount} could not be scored. Open their details to see why.`,
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

    // =====================================================================================================
    //  Results: tiles, search, sort, cards
    // =====================================================================================================
    get hasRows() {
        return this.rawRows.length > 0;
    }
    get showKpis() {
        return this.total > 0;
    }
    get kpiScored() {
        return `${this.scoredCount} / ${this.total}`;
    }
    get topMatch() {
        const scored = this.rawRows.filter((r) => r.status === 'Scored' && r.score !== null && r.score !== undefined);
        if (scored.length === 0) {
            return '-';
        }
        // Several candidates can share the top score: name the strongest of them (skills, then experience, then name) and say how many tie.
        const best = scored.slice().sort((a, b) => this.compareMerit(a, b))[0];
        const tied = scored.filter((r) => Number(r.score) === Number(best.score)).length - 1;
        return tied > 0 ? `${best.name} +${tied} tied` : best.name;
    }

    handleSearch(event) {
        this.search = event.detail.value || '';
    }
    handleSort(event) {
        this.sort = event.detail.value;
    }
    toggleDetails(event) {
        const id = event.currentTarget.dataset.id;
        this.openId = this.openId === id ? null : id;
    }
    viewResume(event) {
        const docId = event.currentTarget.dataset.doc;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: docId }
        });
    }

    get visibleRows() {
        const q = this.search.trim().toLowerCase();
        let rows = this.rawRows.slice();
        if (q) {
            rows = rows.filter((r) => `${r.name} ${(r.matched || []).join(' ')}`.toLowerCase().includes(q));
        }
        rows.sort((a, b) => this.compareRows(a, b));
        return rows.map((r, i) => this.decorate(r, i));
    }
    get hasVisibleRows() {
        return this.visibleRows.length > 0;
    }
    get emptyText() {
        if (this.isRunning) {
            return '';
        }
        if (this.hasRows) {
            return this.hasVisibleRows ? '' : 'No candidate matches that search.';
        }
        return this.emptyMessage || (this.phase === 'idle' ? 'Pick a job, adjust the filters if you like, then click Apply filters.' : '');
    }

    compareRows(a, b) {
        const byName = a.name.localeCompare(b.name);
        const num = (v) => (v === null || v === undefined ? null : Number(v));
        const cmpNullsLast = (x, y, dir) => {
            if (x === null && y === null) { return 0; }
            if (x === null) { return 1; }
            if (y === null) { return -1; }
            return (x - y) * dir;
        };
        // Highest score first (rows that are not scored yet go last), then the stronger skills, then more relevant experience.
        // Also the tie-break for the other sorts.
        const byScore = this.compareMerit(a, b) || 0;
        let c = 0;
        if (this.sort === 'exp') {
            c = cmpNullsLast(num(a.experienceYears), num(b.experienceYears), -1);
        } else if (this.sort === 'sal') {
            c = cmpNullsLast(num(a.salary), num(b.salary), 1);
        } else {
            c = byScore;
        }
        return c || byScore || byName;
    }

    /** Best first: higher score, then higher skills score, then higher experience score. Rows that are not scored yet go last. 0 = tied. */
    compareMerit(a, b) {
        const num = (row, key) => (row.status === 'Scored' && row[key] !== null && row[key] !== undefined ? Number(row[key]) : null);
        for (const key of ['score', 'skillsScore', 'experienceScore']) {
            const x = num(a, key);
            const y = num(b, key);
            if (x === null && y === null) { continue; }
            if (x === null) { return 1; }
            if (y === null) { return -1; }
            if (x !== y) { return y - x; }
        }
        return 0;
    }

    /** Adds everything the card needs to show: ring, badges, bars, chips, the details text. */
    decorate(r, index) {
        const status = r.status || '';
        const pending = PENDING.includes(status);
        const failed = status.startsWith('Failed');
        const resumeReview = status.startsWith('Needs review');
        const scored = status === 'Scored';
        const score = scored && r.score !== null && r.score !== undefined ? Math.round(r.score) : null;

        let ringText = '…';
        let ringValue = 0;
        let ringColor = GREY;
        if (scored && score !== null) {
            ringText = String(score);
            ringValue = score;
            ringColor = score >= 80 ? GREEN : score >= 65 ? AMBER : GREY;
        } else if (failed || resumeReview) {
            ringText = '–';
        }

        const bars = [];
        if (scored) {
            [['skills', 'Skills', r.skillsScore], ['experience', 'Experience', r.experienceScore], ['education', 'Education', r.educationScore]]
                .forEach(([key, label, v]) => {
                    const value = v === null || v === undefined ? 0 : Math.round(v);
                    bars.push({ key, text: `${label} ${value}`, style: `width:${value}%` });
                });
        }

        let detailsText = '';
        if (scored) {
            detailsText = r.reasoning || 'No explanation was returned for this score.';
        } else if (failed) {
            detailsText = r.reasoning || 'The AI could not score this candidate.';
        } else if (resumeReview) {
            detailsText = 'The resume could not be read reliably, so this candidate was not scored. Open the candidate to review the resume.';
        }

        const isOpen = this.openId === r.contactId;
        return {
            contactId: r.contactId,
            name: r.name,
            nameUrl: r.nameUrl,
            metaText: [r.city, this.formatYears(r.experienceYears), this.formatSalary(r.salary)].filter(Boolean).join(' · '),
            isPending: pending,
            isFinal: !pending,
            ringStyle: `--p:${ringValue};--c:${ringColor}`,
            ringText,
            showTop: scored && index < 3 && this.sort === 'best' && !this.search.trim(),
            showCheck: scored && r.needsReview === true,
            showFailed: failed,
            showResumeReview: resumeReview,
            hasBars: bars.length > 0,
            bars,
            matchedChips: (r.matched || []).map((s) => ({ key: s, label: s })),
            missingChips: (r.missing || []).map((s) => ({ key: s, label: s })),
            hasMatched: (r.matched || []).length > 0,
            hasMissing: (r.missing || []).length > 0,
            isOpen,
            ariaExpanded: String(isOpen),
            chevronIcon: isOpen ? 'utility:chevronup' : 'utility:chevrondown',
            detailsText,
            hasResume: !!r.resumeDocId,
            resumeDocId: r.resumeDocId
        };
    }

    /** 90000 -> "$90,000" */
    formatSalary(v) {
        if (v === null || v === undefined) {
            return '';
        }
        return `$${Math.round(Number(v)).toLocaleString('en-US')}`;
    }
    formatYears(v) {
        if (v === null || v === undefined) {
            return '';
        }
        return `${Number(Number(v).toFixed(1))} yrs`;
    }
    /** 1234 -> "1,234" */
    formatCount(v) {
        return Number(v).toLocaleString('en-US');
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unknown error';
    }
}
