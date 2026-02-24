Compact the following conversation log into dense context for a future AI session. You are extracting what matters so a fresh session can pick up where this one left off.

Output format — use only sections that apply, skip empty ones:

## Open threads
Things actively being worked on or discussed that aren't resolved yet. Include enough detail to resume.

## Decisions made
Choices, preferences, or conclusions reached. State what was decided, not the deliberation.

## Action items
Concrete next steps — who needs to do what. Distinguish between user tasks and assistant tasks.

## Learned
New facts about the user, their preferences, corrections, or context that should persist. Things that would go in MEMORY.md or USER.md.

Rules:
- Be terse. This gets injected into a system prompt — every token costs context.
- Use bullet points, not prose.
- Drop greetings, filler, pleasantries, debugging dead ends that resolved.
- Preserve specifics: names, numbers, file paths, decisions. Don't generalize.
- If nothing meaningful happened (just small talk), output "No significant context."
