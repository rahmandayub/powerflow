# Evidence Rule

Two labels. Nothing else.

- **FACT**: directly verifiable from one source. Must carry a citation: `file:line` or `log:timestamp`. Example: `UserController.php:42 calls UserService.create()`.
- **ASSUMPTION**: believed but not verified. Must be explicitly marked `ASSUMPTION`. Never presented as fact.

## Rules

1. Every claim in `brief.md` carries one label. Bare claims are rewritten.
2. Never present an ASSUMPTION as a FACT.
3. If two facts contradict: record both in the brief's Facts section; downstream phases pick one and say why. One sentence — no separate conflict protocol.
4. Verification happens downstream: assumptions are confirmed with citations as the plan is drafted and executed, or they are dropped.
