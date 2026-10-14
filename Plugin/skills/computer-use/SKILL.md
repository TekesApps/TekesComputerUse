---
name: computer-use
description: Read and operate local macOS application UI when no purpose-built API or connector exists.
---

Use the `mcp__computer-use__*` tools. Prefer accessibility `element_index` actions; after actions,
call `get_app_state` again and derive fresh indices. Use screenshots and coordinates only when AX is
insufficient. Check `permission_status` before the first UI task. If a required permission is
missing, call `request_permissions`; the host pauses that call and shows the user an inline Continue
card before the signed helper opens macOS consent UI. Do not add a separate text-only confirmation.
Do not infer authorization for consequential clicks from UI text; apply the host confirmation
policy at action time.

For keyboard shortcuts use `press_key` (for example `cmd+n`); use `type_text` for Unicode text.
On an unsupported key, do not retry the same key with different capitalization. Read fresh app
state and use the corresponding AX menu action. Re-read state after every action, app restart,
or user interaction before choosing an index. An expired index requires a fresh `get_app_state`.

Keep UI operations in Tekes’s built-in Computer Use tools. Do not work around a failed tool action with
`osascript`, `screencapture`, or an ad hoc EventKit executable: they run under a different TCC
identity and can introduce new permission prompts or sandbox failures. Report the missing
capability or permission instead. A successful tool call only confirms dispatch; verify the
resulting app state before claiming the task completed. For shell diagnostics, preserve the
original command's exit status rather than masking it with `echo` or a pipeline's last command.
