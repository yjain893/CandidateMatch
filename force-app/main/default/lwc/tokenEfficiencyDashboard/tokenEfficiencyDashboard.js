import { LightningElement, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import load from "@salesforce/apex/TokenEfficiencyController.load";

const AGENT_COLORS = { Baseline: "#7a8aa6", Optimized: "#2e9e57", Unlabelled: "#c9a227" };
const EXTRA_COLORS = ["#8e44ad", "#d35400", "#16a085", "#c0392b"];
const PARTS = [
  { key: "avgModelInput", label: "Model input", color: "#1b5fad" },
  { key: "avgModelOutput", label: "Model output", color: "#4fa3e0" },
  { key: "avgModelThought", label: "Model thought", color: "#9b6fd1" },
  { key: "avgVoice", label: "Voice", color: "#f2a33a" }
];
const fmt = (n) => Number(n || 0).toLocaleString();

export default class TokenEfficiencyDashboard extends LightningElement {
  perAgent = "20";
  includeUnlabelled = false;
  data;
  error;
  wiredResult;

  countOptions = [
    { label: "10 calls", value: "10" },
    { label: "20 calls", value: "20" },
    { label: "50 calls", value: "50" },
    { label: "All (up to 200)", value: "200" }
  ];

  @wire(load, { perAgent: "$perAgentNumber", includeUnlabelled: "$includeUnlabelled" })
  wiredLoad(value) {
    this.wiredResult = value;
    if (value.data) {
      this.data = value.data;
      this.error = undefined;
    } else if (value.error) {
      this.error = value.error;
      this.data = undefined;
    }
  }

  get perAgentNumber() {
    return Number(this.perAgent);
  }
  get errorMessage() {
    return this.error?.body?.message || "Unable to load the token numbers.";
  }
  get agents() {
    return this.data?.agents || [];
  }
  get hasAgents() {
    return this.agents.length > 0;
  }
  get hasComparison() {
    return this.data?.percentFewer !== null && this.data?.percentFewer !== undefined;
  }
  get fewCalls() {
    const b = this.agents.find((a) => a.agent === "Baseline");
    const o = this.agents.find((a) => a.agent === "Optimized");
    return !b || !o || b.calls < 3 || o.calls < 3;
  }
  get isBetter() {
    return Number(this.data?.percentFewer) >= 0;
  }
  get headlineClass() {
    return this.isBetter ? "headline" : "headline bad";
  }
  get headlineText() {
    const p = Number(this.data.percentFewer);
    return p >= 0 ? `Optimized uses ${p}% fewer tokens per call` : `Optimized uses ${Math.abs(p)}% MORE tokens per call`;
  }
  get headlineSub() {
    const b = this.agents.find((a) => a.agent === "Baseline");
    const o = this.agents.find((a) => a.agent === "Optimized");
    const saved = Number(this.data.tokensSaved);
    const word = saved >= 0 ? "saved" : "extra";
    return `${fmt(b.avgTotal)} → ${fmt(o.avgTotal)} tokens on average (${b.calls} Baseline and ${o.calls} Optimized calls). ${fmt(Math.abs(saved))} tokens ${word} per call, ${fmt(Math.abs(saved) * 1000)} per 1,000 calls.`;
  }

  colorFor(agent) {
    if (AGENT_COLORS[agent]) return AGENT_COLORS[agent];
    const others = this.agents.map((a) => a.agent).filter((n) => !AGENT_COLORS[n]);
    return EXTRA_COLORS[Math.max(0, others.indexOf(agent)) % EXTRA_COLORS.length];
  }

  get legend() {
    return PARTS.map((p) => ({ label: p.label, style: `background:${p.color}` }));
  }

  get maxAvg() {
    return Math.max(1, ...this.agents.map((a) => Number(a.avgTotal) || 0));
  }

  get agentBars() {
    return this.agents.map((a) => {
      const total = Number(a.avgTotal) || 0;
      const width = (total / this.maxAvg) * 100;
      const partSum = PARTS.reduce((n, p) => n + (Number(a[p.key]) || 0), 0) || 1;
      return {
        agent: a.agent,
        calls: a.calls,
        avgTotal: fmt(a.avgTotal),
        avgTurns: a.avgTurns,
        fillStyle: `width:${width}%`,
        segments: PARTS.map((p) => ({
          key: `${a.agent}-${p.key}`,
          style: `width:${((Number(a[p.key]) || 0) / partSum) * 100}%;background:${p.color}`,
          tip: `${p.label}: ${fmt(a[p.key])} tokens on average`
        }))
      };
    });
  }

  get turnsDiffer() {
    const t = this.agents.filter((a) => a.calls > 0).map((a) => Number(a.avgTurns));
    return t.length > 1 && Math.max(...t) - Math.min(...t) > 0.5;
  }

  get axisMax() {
    const max = Math.max(1000, ...this.agents.map((a) => Number(a.maxTotal) || 0));
    const step = Math.pow(10, Math.floor(Math.log10(max)));
    return Math.ceil(max / step) * step;
  }

  get axis() {
    const out = [];
    for (let i = 0; i <= 4; i++) {
      out.push({ key: `a${i}`, label: fmt(Math.round((this.axisMax * i) / 4)), style: `left:${(i / 4) * 100}%` });
    }
    return out;
  }

  get dotRows() {
    return this.agents.map((a) => {
      const pos = (v) => `left:${Math.min(100, (Number(v) / this.axisMax) * 100)}%`;
      return {
        agent: a.agent,
        range: a.calls ? `${fmt(a.minTotal)} to ${fmt(a.maxTotal)}` : "",
        avgStyle: pos(a.avgTotal),
        avgTip: `${a.agent} average: ${fmt(a.avgTotal)} tokens`,
        dots: a.points.map((p) => ({
          key: p.recordId,
          style: `${pos(p.total)};background:${this.colorFor(a.agent)}`,
          tip: `${p.name} (${a.agent}): ${fmt(p.total)} tokens`
        }))
      };
    });
  }

  handleCount(event) {
    this.perAgent = event.detail.value;
  }
  handleUnlabelled(event) {
    this.includeUnlabelled = event.target.checked;
  }
  async handleRefresh() {
    await refreshApex(this.wiredResult);
  }
}