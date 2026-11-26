"""Shortens the descriptions the model reads for each Python tool (same meaning, fewer words).
Run after build_agent.py --no-zip, then zip the folder (see build.sh)."""
import glob, json, os, sys
PKG = sys.argv[1]
SHORT = {
 "get_order_status": "Gets an order's status, dates and total. Call after verification, with the order number.\n\nArgs:\n  order_number: As the caller said it, for example \"102\".\n\nReturns:\n  dict: ok, order_status, order_date, end_date, total_amount. not_found: nothing matched. system_error true: apologize and escalate.",
 "get_shipping_address": "Gets an order's current shipping address to read out before a change. Call after verification, with the order number.\n\nArgs:\n  order_number: As the caller said it, for example \"102\".\n\nReturns:\n  dict: ok, street, city, state, postal_code, country. not_found: nothing matched. system_error true: apologize and escalate.",
 "identify_caller": "Runs automatically at call start to recognise the caller by phone. Do not call it.\n\nArgs:\n  include_details: Internal. Leave empty.\n\nReturns:\n  dict: ok, caller_status (known or unknown), first_name. system_error true: caller is treated as unknown.",
 "save_transcript": "Runs automatically at call end. Do not call it.\n\nArgs:\n  outcome: Filled in by the end-of-call hook. Leave empty.\n\nReturns:\n  dict: ok, message. system_error true: not saved.",
 "update_shipping_address": "Changes an order's shipping address. Send only the parts the caller gave. Call after verification, with the order number and the new address.\n\nArgs:\n  order_number: As the caller said it, for example \"102\".\n  street: New street and number, as said.\n  city: Only if given.\n  state: Only if given.\n  postal_code: Only if given.\n  country: Only if given.\n\nReturns:\n  dict: ok, updated_fields. not_found, not_confirmed, invalid_input: fix and retry. system_error true: apologize and escalate.",
 "verify_caller_email": "Checks the email the caller says against the email on their Salesforce contact. Call once they have said it. Share nothing about orders unless verified is true.\n\nArgs:\n  email: Exactly as said, including spoken \"at\" and \"dot\".\n\nReturns:\n  dict: verified (true or false), message. not_verified: say it could not be verified and ask for another (see attempts_remaining). locked_out: end the call politely. invalid_input: ask them to say it again.",
}
before = after = 0
for f in sorted(glob.glob(os.path.join(PKG, "tools", "*", "*.json"))):
    d = json.load(open(f))
    name = d["pythonFunction"]["name"]
    if name in SHORT:
        before += len(d["pythonFunction"]["description"])
        d["pythonFunction"]["description"] = SHORT[name]
        after += len(SHORT[name])
        json.dump(d, open(f, "w"), indent=2)
# The console reads the tool description from the docstring in the Python code, not from the JSON field,
# so the same short text must also go into python_code.py.
import re
for name, text in SHORT.items():
    path = os.path.join(PKG, "tools", name, "python_function", "python_code.py")
    code = open(path).read()
    start = code.index('  """')
    end = code.index('"""', start + 5) + 3
    doc = '  """' + text.replace('"""', "\'\'\'").replace("\n", "\n  ") + '\n  """'
    code = code[:start] + doc + code[end:]
    compile(code, path, "exec")   # must still be valid Python
    open(path, "w").write(code)
print("tool descriptions: %d -> %d letters (JSON and Python docstring)" % (before, after))
