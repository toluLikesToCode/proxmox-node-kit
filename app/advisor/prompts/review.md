---
command: review
name: Review
---
Review this compose file, script or config. Do not rewrite it all.

{{content}}

Answer in this order:
1. Verdict: one sentence.
2. Problems: most serious first. For each, the line, why it matters and the fix.
3. Safety: secrets in the file, exposed ports, missing backups, destructive commands.
4. Undo: how to roll back the fixes you suggest.
