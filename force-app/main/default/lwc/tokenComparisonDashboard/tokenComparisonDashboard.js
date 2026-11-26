import { LightningElement, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import load from "@salesforce/apex/TokenComparisonController.load";

const AGENT_COLORS = { Baseline: "#7a8aa6", Optimized: "#2e9e57", Unlabelled: "#c9a227" };
const EXTRA_COLORS = ["#8e44ad", "#d35400", "#16a085", "#c0392b"];
const PARTS = [
  { key: "modelInput", label: "Model input", color: "#1b5fad" },
  { key: "modelOutput", label: "Model output", color: "#4fa3e0" },
  { key: "modelThought", label: "Model thought", color: "#9b6fd1" },
  { key: "voiceInput", label: "Voice input", color: "#f2a33a" },
  { key: "voiceOutput", label: "Voice output", color: "#e0612e" }
];

export default class TokenComparisonDashboard extends LightningElement {
  agent = "";
  maxBars = "30";
  view = "total";
  data;
  error;
  wiredResult;

  countOptions = [
    { label: "10 calls", value: "10" },
    { label: "30 calls", value: "30" },
    { label: "60 calls", value: "60" },
    { label: "100 calls", value: "100" }
  ];
  viewOptions = [
    { label: "Total, coloured by agent", value: "total" },
    { label: "Breakdown (input, output, thought, voice)", value: "breakdown" }
  ];

  @wire(load, { agent: "$agent", maxBars: "$maxBarsNumber" })
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

  get maxBarsNumber() {
    return Number(this.maxBars);
  }
  get errorMessage() {
    return this.error?.body?.message || "Unable to load the token numbers.";
  }
  get agentOptions() {
    const names = this.data?.agents || [];
    return [{ label: "All voice agents", value: "" }, ...names.map((n) => ({ label: n, value: n }))];
  }
  get rows() {
    return this.data?.bars || [];
  }
  get hasBars() {
    return this.rows.length > 0;
  }
  get hasSummaries() {
    return (this.data?.summaries || []).length > 0;
  }
  get hasComparison() {
    return this.data?.percentFewer !== null && this.data?.percentFewer !== undefined;
  }
  get comparisonText() {
    const p = Number(this.data.percentFewer);
    return p >= 0 ? `${p}% fewer` : `${Math.abs(p)}% more`;
  }

  colorFor(agent) {
    if (AGENT_COLORS[agent]) return AGENT_COLORS[agent];
    const others = (this.data?.agents || []).filter((a) => !AGENT_COLORS[a]);
    return EXTRA_COLORS[Math.max(0, others.indexOf(agent)) % EXTRA_COLORS.length];
  }

  get summaryTiles() {
    return (this.data?.summaries || [])
      .slice()
      .sort((a, b) => a.agent.localeCompare(b.agent))
      .map((s) => ({
        ...s,
        avgTotal: Number(s.avgTotal).toLocaleString(),
        avgModelInput: Number(s.avgModelInput).toLocaleString(),
        avgModelOutput: Number(s.avgModelOutput).toLocaleString(),
        avgModelThought: Number(s.avgModelThought).toLocaleString(),
        avgVoice: Number(s.avgVoice).toLocaleString(),
        dotStyle: `background:${this.colorFor(s.agent)}`
      }));
  }

  get legend() {
    if (this.view === "breakdown") {
      return PARTS.map((p) => ({ label: p.label, style: `background:${p.color}` }));
    }
    const seen = [...new Set(this.rows.map((r) => r.agent))];
    return seen.map((a) => ({ label: a, style: `background:${this.colorFor(a)}` }));
  }

  get maxTotal() {
    const max = Math.max(0, ...this.rows.map((r) => Number(r.total) || 0));
    if (max === 0) return 1000;
    const step = Math.pow(10, Math.floor(Math.log10(max)));
    return Math.ceil(max / step) * step;
  }

  // Five horizontal guide lines with their numbers (0 at the bottom).
  get ticks() {
    const list = [];
    for (let i = 0; i <= 4; i++) {
      const pct = (i / 4) * 100;
      list.push({
        key: `t${i}`,
        label: Math.round((this.maxTotal * i) / 4).toLocaleString(),
        style: `bottom:${pct}%`,
        lineStyle: `bottom:${pct}%`
      });
    }
    return list;
  }

  get bars() {
    return this.rows.map((row) => {
      const total = Number(row.total) || 0;
      const tip =
        `${row.name} (${row.agent})\nTotal ${total.toLocaleString()}\n` +
        `Model in ${Number(row.modelInput).toLocaleString()}, out ${Number(row.modelOutput).toLocaleString()}, thought ${Number(row.modelThought).toLocaleString()}\n` +
        `Voice in ${Number(row.voiceInput).toLocaleString()}, out ${Number(row.voiceOutput).toLocaleString()}`;
      const segments =
        this.view === "breakdown"
          ? PARTS.map((p) => ({ key: `${row.recordId}-${p.key}`, style: `flex:${Number(row[p.key]) || 0} 0 0;background:${p.color}` }))
          : [{ key: `${row.recordId}-t`, style: `flex:1 0 0;background:${this.colorFor(row.agent)}` }];
      return {
        key: row.recordId,
        label: row.name,
        tip,
        stackStyle: `height:${Math.max((total / this.maxTotal) * 100, 0.5)}%`,
        segments
      };
    });
  }

  handleAgent(event) {
    this.agent = event.detail.value;
  }
  handleCount(event) {
    this.maxBars = event.detail.value;
  }
  handleView(event) {
    this.view = event.detail.value;
  }
  async handleRefresh() {
    await refreshApex(this.wiredResult);
  }
}
