# Documentation Standards

Documentation is a first-class artifact. Every decision is documented. Every pattern is explained.

## Directory Structure

Documentation lives in `docs/` adjacent to but separate from source code:

```
project-root/
├── docs/
│   ├── adr/                    # Architecture Decision Records
│   │   ├── ADR-001-project-setup.md
│   │   ├── ADR-002-auth-approach.md
│   │   └── ...
│   ├── specs/                  # Feature specifications
│   └── test-plans/             # Test plan documents
├── src/                        # Source code
└── tests/                      # Test code
```

## Documentation Types

### Architecture Decision Records (ADRs)

Capture every architectural or design decision. Use the ADR template from `${CLAUDE_PLUGIN_ROOT}/skills/dev/references/templates/ADR_TEMPLATE.md`.

**When to write an ADR:**
- Choosing a technology or library
- Deciding on an architectural pattern
- Making a design trade-off
- Deviating from an established pattern

**ADR lifecycle:** Proposed → Accepted → Superseded (see DECISION_MAKING.md)

### Feature Specifications

Document what each feature does, why it exists, and how it works. Use the template from `${CLAUDE_PLUGIN_ROOT}/skills/dev/references/templates/FEATURE_SPEC_TEMPLATE.md`.

**When to write a spec:**
- Before implementing any new feature (Phase 1-3 of the cycle)
- When significantly modifying existing behavior

### Test Plans

Document the testing strategy for each feature. Use the template from `${CLAUDE_PLUGIN_ROOT}/skills/dev/references/templates/TEST_PLAN_TEMPLATE.md`.

**When to write a test plan:**
- During Phase 4 of the development cycle
- Include: test types, coverage targets, traceability matrix

## Documentation Maintenance

Documentation is updated as part of the development cycle (Phase 7), not as an afterthought.

### When to update:
- After any implementation that deviates from the original design
- When actual test coverage numbers are known
- When new patterns or conventions emerge

### What not to do in Phase 7:
- Do not introduce new features
- Do not refactor code
- Do not change behavior
- If a gap is found, log it as a follow-up task

## Writing Quality

- Be concise — say what needs to be said, nothing more
- Use concrete examples over abstract explanations
- Keep documentation close to the code it describes
- If a document is longer than 200 lines, consider splitting it
