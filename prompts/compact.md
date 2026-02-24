Compact the following conversation log into dense context for a future AI session. You are extracting what matters so a fresh session can pick up where this one left off.

The log is line-numbered. Format: "recv [sender]" = user received message, "send [recipient]" = assistant sent message.

Include line references [L42-58] on each bullet so a future session can look up full context.

YOUR ONLY INPUT IS THE NUMBERED LOG BELOW. You have no other context. Do not reference any external files, system prompts, documentation, or prior knowledge about the user. Every fact in your output must trace to a specific line number in the log. If you cannot cite a line number, do not include it.

Output EXACTLY these sections (no others). Always include Participants. Skip a section only if truly empty.

## Participants
Unique identifiers from recv/send lines only (phone numbers, emails). Not people merely discussed.

## Open threads
Unresolved topics with enough detail to resume. Technical: include function names, patterns, techniques discussed.

## Decisions made
Choices, preferences, or strategic conclusions — not bug fixes (those go in Completed). What was decided and why (1 line each).

## Pending actions
Future tasks with dates/specifics. Don't repeat Completed items.

## Completed
Actions done (emails sent, reminders set, bugs fixed, files/docs created). Include file paths for any documents saved.

## People & context
People mentioned (not participants) — name, role, relationship.

## Learned
Persistent user facts from this conversation only — projects, preferences, living situation, work style.

Rules:
- MAX 35 lines total output. Be ruthlessly terse.
- 1-2 lines per bullet max.
- Every bullet must have a line reference [Lstart-end].
- Technical: include function/method names, not vague descriptions.
- Do not attribute assistant's knowledge to the user.
- Do not create sections not listed above.
- If nothing meaningful happened, output "No significant context."
