"""Guardrail resources. Shapes follow the REST reference (Guardrail) and the real console export.

Types: default_safety, default_prompt_security, llm_policy, blocklist, sensitive_words, supervisor, code_callback.
Action: {"respond": "text"} | {"generative": "optional prompt"} | {"transfer": "agent display name"}
Placement: "scope": "app" (default, applies to every agent) or "agent" with "agents": [display names].
llm_policy uses "policy_scope": USER_QUERY | AGENT_RESPONSE | USER_QUERY_AND_AGENT_RESPONSE.
"""
from .common import SpecError, need

LEVELS = {"strict": "BLOCK_LOW_AND_ABOVE", "balanced": "BLOCK_MEDIUM_AND_ABOVE", "relaxed": "BLOCK_ONLY_HIGH"}
CATEGORIES = ["HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_DANGEROUS_CONTENT", "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_HARASSMENT"]
DEFAULT_RESPONSE = "I'm sorry, I can't help with that. Let me connect you with a team member."


def _action(spec, default_text=None):
    a = spec.get("action")
    if a is None:
        if default_text:
            return {"respondImmediately": {"responses": [{"text": default_text}]}}
        return {"generativeAnswer": {}}
    if "respond" in a:
        return {"respondImmediately": {"responses": [{"text": a["respond"]}]}}
    if "generative" in a:
        return {"generativeAnswer": ({"prompt": a["generative"]} if a["generative"] else {})}
    if "transfer" in a:
        return {"transferAgent": {"agent": a["transfer"]}}
    raise SpecError("guardrail '%s': action must be respond, generative or transfer" % spec.get("displayName"))


def build_guardrail(spec):
    """Returns (displayName, json_dict, extra_files) where extra_files is {relative_path_in_guardrail_dir: text}."""
    t = need(spec, "type", "guardrail")
    name = spec.get("displayName")
    if t == "default_safety":
        level = spec.get("level", "strict")
        if level not in LEVELS:
            raise SpecError("guardrail default_safety: level must be strict, balanced or relaxed")
        d = {"displayName": name or "Default Safety Guardrail", "enabled": True, "action": _action(spec),
             "modelSafety": {"safetySettings": [{"category": c, "threshold": LEVELS[level]} for c in CATEGORIES]}}
        return d["displayName"], d, {}
    if t == "default_prompt_security":
        d = {"displayName": name or "Default Prompt Guardrail", "enabled": True, "action": _action(spec),
             "llmPromptSecurity": {"defaultSettings": {}}}
        if spec.get("fail_open") is not None:
            d["llmPromptSecurity"]["failOpen"] = bool(spec["fail_open"])
        return d["displayName"], d, {}
    name = need(spec, "displayName", "guardrail")
    d = {"displayName": name, "description": spec.get("description", ""), "enabled": spec.get("enabled", True)}
    if t == "llm_policy":
        scope = spec.get("policy_scope", "USER_QUERY")
        d["llmPolicy"] = {"prompt": need(spec, "prompt", "guardrail " + name), "policyScope": scope,
                          "failOpen": bool(spec.get("fail_open", False)), "maxConversationMessages": int(spec.get("max_messages", 10))}
        d["action"] = _action(spec, DEFAULT_RESPONSE)
    elif t == "blocklist":
        words_in = spec.get("user_input") or []
        words_out = spec.get("agent_response") or []
        both = spec.get("both") or []
        if not (words_in or words_out or both):
            raise SpecError("guardrail %s: blocklist needs user_input, agent_response or both phrases" % name)
        cf = {"matchType": spec.get("match", "WORD_BOUNDARY_STRING_MATCH")}
        if both:
            cf["bannedContents"] = both
        if words_in:
            cf["bannedContentsInUserInput"] = words_in
        if words_out:
            cf["bannedContentsInAgentResponse"] = words_out
        d["contentFilter"] = cf
        d["action"] = _action(spec, DEFAULT_RESPONSE)
    elif t == "sensitive_words":
        d["contentFilter"] = {"matchType": "SENSITIVE_WORDS"}
        d["action"] = _action(spec, DEFAULT_RESPONSE)
    elif t == "supervisor":
        d["supervisor"] = {"type": need(spec, "supervisor_type", "guardrail " + name), "detectionMode": spec.get("detection", "NON_BLOCKING")}
        d["action"] = _action(spec)
    elif t == "code_callback":
        phase = spec.get("phase", "afterModelCallback")
        if phase not in ("beforeAgentCallback", "afterAgentCallback", "beforeModelCallback", "afterModelCallback"):
            raise SpecError("guardrail %s: bad phase %s" % (name, phase))
        code = need(spec, "code", "guardrail " + name)
        rel = "guardrail_callback/python_code.py"
        d["codeCallback"] = {phase: {"pythonCode": "guardrails/%s/%s" % ("__DIR__", rel), "description": spec.get("description", "")}}
        d["action"] = _action(spec, DEFAULT_RESPONSE)
        return name, d, {rel: code}
    else:
        raise SpecError("guardrail '%s': unknown type '%s'" % (name, t))
    return name, d, {}
