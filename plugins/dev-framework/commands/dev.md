---
description: "[v4.0.0 tombstone] Renamed to /dev-framework:implement. See also /dev-framework:spike for multi-ticket research. Removed in v4.1.0."
---

# `/dev` has been renamed (v4.0.0)

Inform the user, without invoking any skill:

> The `/dev` command has been renamed as of dev-framework v4.0.0.
>
> - For **single-ticket implementation** (what `/dev` used to do), use `/dev-framework:implement` or the optional user-level shortcut `/implement`.
> - For **multi-ticket research and decomposition** (new in v4.0.0), use `/dev-framework:spike` or `/spike`.
>
> See `plugins/dev-framework/README.md` and `docs/specs/2026-04-21-spike-implement-split.md` for the workflow split rationale.

Do not invoke any skill. Do not take any other action. Return after informing the user.
