# Spike: can a callback call a tool at the start of a call?

Ten minutes in the console. It answers the one question the greeting by name depends on, before you paste anything into the real agent.
Do it in a **new, empty test app**, not in the Pharma agent.

## Steps
1. Create a new voice app, for example "Spike".
2. Variables (type Text): `spike_var`, `spike_cb_var`, and `telephony-caller-id` (exactly this name) with the default value `+14155550101` (John's demo number).
3. Python tool: create `spike_echo` and paste [spike_echo.py](spike_echo.py).
4. Root agent: add the tool `spike_echo`. Instruction: `Say hello.`
5. Callbacks: add a **Before model** callback and paste [spike_callback.py](spike_callback.py).
6. Open Preview and start a session. The agent speaks a short report instead of a greeting. Send me that text (it also appears in the trace).
7. Say "hello", open the trace, and look for `state_update` entries for `spike_var` and `spike_cb_var`.

## How to read the result
| The report says | Meaning | What to do |
|---|---|---|
| `tools works, result type dict` | A callback can run a Python tool | Keep `mode: direct` (the default) |
| `tools FAILED with NameError` (or another error) | A callback cannot call tools | Set `mode: tool_call` on the greeting callback (edit the line `MODE = 'direct'` to `MODE = 'tool_call'`) |
| `variable written by the tool reads as set-by-tool` | Variables the tool writes are visible to the callback | Good |
| `variable written by the tool reads as None` | The callback does not see them straight away | No problem: the real callback copies the values from the tool's result itself |
| `variable set by the callback reads as set-by-callback` | A callback can set variables | Needed for the stored name and email |
| `caller id present True, last four digits 0101` | The test number reaches the callback | Good. On a real phone call the platform fills this variable |
| `caller id present False` | The variable is not filled in Preview | Check the name has hyphens exactly: `telephony-caller-id` |
| `state_update` entries in the trace | Variable changes are shown to the AI | Confirms that the stored email can be seen by the AI |

Delete the test app afterwards. Nothing in it touches Salesforce.
