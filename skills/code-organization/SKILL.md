---
name: code-organization
description: Review a codebase, feature, API, or branch for consistent naming of concepts and whether files and folders should be renamed, split, merged, or moved. Use whenever the user asks about naming, structure, layout, or organization of code, mentions inconsistent or confusing names, or wants a cleanup pass that is about structure rather than logic.
---

Review structure and naming only — not logic, bugs, or style. Read the relevant scope
(feature, API, branch diff, or whole codebase) broadly before judging anything; organization
problems are only visible across files.

Look for:

- **One concept, one name.** The same idea should carry the same word everywhere — variables,
  functions, types, endpoints, files, folders. Flag synonyms (`user`/`account`/`member`) and
  homonyms (one word meaning two things).
- **Names match contents.** A file, function, or folder should be named after what is actually
  in it, and contain only what its name promises.
- **Right-sized units.** Files or folders doing several unrelated jobs want splitting; scattered
  fragments of one job want merging.
- **Coherent layout.** Related things live together; the folder tree should mirror the domain,
  and depth should earn itself.

Report findings ordered by how much confusion they cause, each with the concrete move
(rename X → Y, split A into B/C, move D under E) and the reason in one line. Propose only;
apply changes when the user asks.
