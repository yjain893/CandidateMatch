# Tool descriptions (the console reads them from the docstring at the top of each tool file, so pasting the tool file is enough)

## get_order_status
```
Gets an order's status, dates and total. Call after verification, with the order number.

Args:
  order_number: As the caller said it, for example "102".

Returns:
  dict: ok, order_status, order_date, end_date, total_amount. not_found: nothing matched. system_error true: apologize and escalate.
```

## get_shipping_address
```
Gets an order's current shipping address to read out before a change. Call after verification, with the order number.

Args:
  order_number: As the caller said it, for example "102".

Returns:
  dict: ok, street, city, state, postal_code, country. not_found: nothing matched. system_error true: apologize and escalate.
```

## identify_caller
```
Runs automatically at call start to recognise the caller by phone. Do not call it.

Args:
  include_details: Internal. Leave empty.

Returns:
  dict: ok, caller_status (known or unknown), first_name. system_error true: caller is treated as unknown.
```

## save_transcript
```
Runs automatically at call end. Do not call it.

Args:
  outcome: Filled in by the end-of-call hook. Leave empty.

Returns:
  dict: ok, message. system_error true: not saved.
```

## update_shipping_address
```
Changes an order's shipping address. Send only the parts the caller gave. Call after verification, with the order number and the new address.

Args:
  order_number: As the caller said it, for example "102".
  street: New street and number, as said.
  city: Only if given.
  state: Only if given.
  postal_code: Only if given.
  country: Only if given.

Returns:
  dict: ok, updated_fields. not_found, not_confirmed, invalid_input: fix and retry. system_error true: apologize and escalate.
```

## verify_caller_email
```
Checks the email the caller says against the email on their Salesforce contact. Call once they have said it. Share nothing about orders unless verified is true.

Args:
  email: Exactly as said, including spoken "at" and "dot".

Returns:
  dict: verified (true or false), message. not_verified: say it could not be verified and ask for another (see attempts_remaining). locked_out: end the call politely. invalid_input: ask them to say it again.
```
