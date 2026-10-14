# Tool reference

TekesComputerUse exposes twelve MCP tools. Read-only classification describes
whether a tool changes another application; it does not remove the need for
macOS permission where noted.

| Tool | Purpose | macOS permission | Changes target app |
| --- | --- | --- | --- |
| `list_apps` | List regular running applications. | None | No |
| `permission_status` | Read Accessibility and Screen Recording status. | None | No |
| `request_permissions` | Ask macOS to show the requested consent UI. | User decision required | No |
| `get_app_state` | Read an app's accessibility tree; include a front-window image when available. | Accessibility; Screen Recording for image | No |
| `click` | Press an accessibility element or screen coordinate. | Accessibility | Yes |
| `drag` | Drag between screen coordinates. | Accessibility | Yes |
| `press_key` | Send a keyboard action to an application. | Accessibility | Yes |
| `scroll` | Scroll an application window. | Accessibility | Yes |
| `set_value` | Set the value of an accessibility element. | Accessibility | Yes |
| `select_text` | Select matching text in a supported accessibility element. | Accessibility | Yes |
| `type_text` | Insert text into an application. | Accessibility | Yes |
| `perform_secondary_action` | Invoke a non-primary accessibility action. | Accessibility | Yes |

`get_app_state` is Accessibility-first. A missing Screen Recording grant or an
unavailable on-screen window produces a screenshot diagnostic while preserving
the available accessibility result. A missing Accessibility grant blocks the
state/interaction operation rather than falling back to unapproved screen
automation.

Input and selection tools require the host to obtain its own explicit approval
before invocation. The MCP capability metadata tells the host which tools are
read-only; it does not grant macOS permission or waive the host's approval
policy.
