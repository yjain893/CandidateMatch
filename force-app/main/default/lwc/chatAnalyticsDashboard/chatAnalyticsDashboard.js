import { LightningElement, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import getDashboard from "@salesforce/apex/ChatAnalyticsDashboardController.getDashboard";
import getConversationDetail from "@salesforce/apex/ChatAnalyticsDashboardController.getConversationDetail";
import { refreshApex } from "@salesforce/apex";

export default class ChatAnalyticsDashboard extends NavigationMixin(LightningElement) {
  data; error; wiredResult; selectedDetail; detailError; showDetail = false;
  showAllIntents = false; showAllRows = false; showAllFailures = false;
  filters = { analyzedFrom: "", analyzedTo: "", botResolutionStatus: "", escalatedToHuman: "", finalResolutionBy: "" };
  statusOptions = [{ label: "All statuses", value: "" }, { label: "Resolved", value: "Resolved" }, { label: "Partially Resolved", value: "Partially Resolved" }, { label: "Not Resolved", value: "Not Resolved" }, { label: "Indeterminate", value: "Indeterminate" }];
  booleanOptions = [{ label: "All conversations", value: "" }, { label: "Escalated to human", value: "true" }, { label: "Not escalated", value: "false" }];
  finalOptions = [{ label: "All outcomes", value: "" }, { label: "Bot", value: "Bot" }, { label: "Human Agent", value: "Human Agent" }, { label: "Unresolved", value: "Unresolved" }, { label: "Indeterminate", value: "Indeterminate" }];
  @wire(getDashboard, { analyzedFrom: "$filters.analyzedFrom", analyzedTo: "$filters.analyzedTo", botResolutionStatus: "$filters.botResolutionStatus", escalatedToHuman: "$filters.escalatedToHuman", finalResolutionBy: "$filters.finalResolutionBy" })
  wiredDashboard(value) { this.wiredResult = value; if (value.data) { this.data = value.data; this.error = undefined; } else if (value.error) { this.error = value.error; this.data = undefined; } }
  get summary() {
    const raw = this.data?.summary || {};
    const out = { ...raw };
    // Show percentages with at most 1 decimal so they fit in the boxes and bars.
    Object.keys(out).forEach((k) => { if (/percent/i.test(k) && out[k] !== null && out[k] !== undefined && out[k] !== "" && !isNaN(Number(out[k]))) out[k] = Math.round(Number(out[k]) * 10) / 10; });
    return out;
  }
  get rows() { return this.data?.rows || []; }
  get hasRows() { return this.rows.length > 0; }
  get errorMessage() { return this.error?.body?.message || "Unable to load conversation analytics."; }
  bar(label, count, percent, className) { percent = Math.round((Number(percent) || 0) * 10) / 10; return { label, count, percent, className, style: `width:${Math.max(0, Math.min(100, percent || 0))}%` }; }
  get statusBars() { const s=this.summary; return [this.bar("Resolved",s.botResolvedCount||0,s.botResolvedPercent||0,"bar good"),this.bar("Partially resolved",s.partiallyResolvedCount||0,s.partiallyResolvedPercent||0,"bar partial"),this.bar("Not resolved",s.botNotResolvedCount||0,s.botNotResolvedPercent||0,"bar not-resolved"),this.bar("Indeterminate",s.indeterminateCount||0,((s.indeterminateCount||0)/(s.totalConversations||1))*100,"bar neutral")]; }
  get escalationBars() { const s=this.summary; return [this.bar("Bot-only / not escalated",(s.totalConversations||0)-(s.escalatedCount||0),100-(s.escalatedPercent||0),"bar blue"),this.bar("Escalated to human",s.escalatedCount||0,s.escalatedPercent||0,"bar orange")]; }
  get finalBars() { const totals={ Bot:0,"Human Agent":0,Unresolved:0,Indeterminate:0 }; this.rows.forEach(r=>{ totals[r.finalResolutionBy] = (totals[r.finalResolutionBy] || 0)+1; }); const n=this.rows.length||1; return Object.keys(totals).map(k=>this.bar(k,totals[k],totals[k]*100/n,"bar purple")); }

  // Top 5 customer intents, grouped by issue category (the analysis fills it in), with a count and one example sentence.
  get intentGroups() {
    const map = new Map();
    this.rows.forEach((r) => {
      const key = (r.issueCategory || "Other").trim() || "Other";
      const g = map.get(key) || { key, label: key, count: 0, examples: new Map() };
      g.count += 1;
      const e = (r.customerIntent || "").trim();
      if (e) g.examples.set(e, (g.examples.get(e) || 0) + 1);
      map.set(key, g);
    });
    const max = Math.max(1, ...[...map.values()].map((g) => g.count));
    return [...map.values()]
      .map((g) => ({ key: g.key, label: g.label, count: g.count, style: `width:${(g.count / max) * 100}%`, example: [...g.examples.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || "" }))
      .sort((a, b) => b.count - a.count);
  }
  get visibleIntents() { return this.showAllIntents ? this.intentGroups : this.intentGroups.slice(0, 5); }
  get canToggleIntents() { return this.intentGroups.length > 5; }
  get intentsToggleLabel() { return this.showAllIntents ? "Show fewer" : `Show all ${this.intentGroups.length} intents`; }
  toggleIntents() { this.showAllIntents = !this.showAllIntents; }

  // Conversation analysis: the 5 most recently analyzed conversations, with Show all.
  get sortedRows() { return [...this.rows].sort((a, b) => String(b.analyzedAt || "").localeCompare(String(a.analyzedAt || ""))); }
  get visibleRows() { return this.showAllRows ? this.sortedRows : this.sortedRows.slice(0, 5); }
  get visibleRowCount() { return this.visibleRows.length; }
  get totalRowCount() { return this.rows.length; }
  get canToggleRows() { return this.rows.length > 5; }
  get rowsToggleLabel() { return this.showAllRows ? "Show fewer" : `Show all ${this.rows.length}`; }
  toggleRows() { this.showAllRows = !this.showAllRows; }

  // Bot failure reasons: only real failures, identical reasons clubbed with a count.
  get failureGroups() {
    const map = new Map();
    this.rows.forEach((r) => {
      const reason = (r.botFailureReason || "").trim();
      if (!reason) return;
      const g = map.get(reason) || { key: reason, reason, count: 0, example: (r.customerIntent || "").trim() };
      g.count += 1;
      map.set(reason, g);
    });
    return [...map.values()].sort((a, b) => b.count - a.count);
  }
  get hasFailures() { return this.failureGroups.length > 0; }
  get visibleFailures() { return this.showAllFailures ? this.failureGroups : this.failureGroups.slice(0, 5); }
  get canToggleFailures() { return this.failureGroups.length > 5; }
  get failuresToggleLabel() { return this.showAllFailures ? "Show fewer" : `Show all ${this.failureGroups.length} reasons`; }
  toggleFailures() { this.showAllFailures = !this.showAllFailures; }
  handleFilter(event) { this.filters = { ...this.filters, [event.target.name]: event.detail?.value ?? event.target.value }; }
  async handleRefresh() { await refreshApex(this.wiredResult); }
  async handleDetail(event) { const id=event.currentTarget.dataset.id; try { this.selectedDetail=await getConversationDetail({ conversationRecordId:id }); this.detailError=undefined; this.showDetail=true; } catch(e) { this.detailError=e; } }
  closeDetail() { this.showDetail=false; }
  openRecord() { if(this.selectedDetail?.conversationRecordId) this[NavigationMixin.Navigate]({ type:"standard__recordPage", attributes:{ recordId:this.selectedDetail.conversationRecordId, objectApiName:"Chat_Conversation__c", actionName:"view" } }); }
}