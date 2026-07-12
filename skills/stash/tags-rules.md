# Stash Tag Rules

## Naming Conventions

### Case
- Use **lowercase** for single-word tags: `anal`, `fetish`, `bondage`
- Use **Title Case** only for multi-word category labels and group notation: `Double Blowjob (2 Mouths)`, `Foursome (Lesbian)`

### Word Count
- Keep tag names to **1-4 words maximum**
- Prefer **2-word combinations** for specificity: `anal fisting` not `analfisting`

### Parenthetical Notation
- Use parentheses **only** for group size notation with composition codes
- Format: `{type} ({composition})` where `b`=male, `g`=female, `t`=trans
- Examples: `threesome (bbg)`, `foursome (bbgg)`, `Twosome (Lesbian)`

### Prefixes
- Use `double`, `triple` for count-based variations
- Use `first` for initial/completion actions: `first insertion`, `first suck`

## Alias Rules

### Required Alias Types
Every tag should have aliases covering:

1. **Synonyms** - common alternative names
   - `bdsm` → `domination`, `submission`, `submissive`

2. **Shorthand** - common abbreviations
   - `ass to mouth` → `a2m`, `atm`
   - `double anal penetration` → `dap`

3. **Spelling variations** - misspellings and alternate spellings
   - `deepthroat` / `deep throat` / `deep throating`

4. **Phrase expansion** - when single word is ambiguous
   - `anal` → `anal masturbation`, `anal sex`

5. **Reverse forms** - bidirectional naming
   - `ass to mouth` → `mouth to ass` (as alias)

### Alias Constraints
- Aliases must be **case-insensitive unique** across all tags
- Do **not** create aliases identical to the tag name
- Duplicate aliases are ignored silently on create; error on update

### Alias Count Guidelines
- Minimum: 1-2 aliases per tag
- Maximum reasonable: 8-10 for core categories (`bdsm`, `blowjob`)
- Prefer quality over quantity

## Hierarchy Rules (DAG)

### Structure
- Tags form a **Directed Acyclic Graph** — children can have multiple parents
- **Never create circular relationships** (A→B→C→A)

### Parent Assignment
- Use parent relationships for **categorical inheritance**
- Hub tags should parent related subcategories:
  - `anal` → `anal fingering`, `anal fisting`, `anal gape`, etc.
  - `pussy` → `pussy creampie`, `pussy fisting`, etc.

### Multi-Parent Tags
For cross-category composition, combine parents from different semantic areas:

```
anal fisting       = anal insertion + fisting
dirty anal         = anal + scat
double penetration  = anal insertion + pussy + pussy insertion
ass to mouth       = anal + blowjob
```

Formula: `{body_part_tag} + {action_tag}` or `{category1} + {category2}`

## Tag Family Patterns

### Group by Prefix
Tags sharing a prefix belong to same family:
- `anal *` - all anal activities
- `pussy *` - all vaginal activities
- `dirty *` - scatological variations

### Common Suffixes
Use these suffixes for consistency:
- `* insertion` - acts of inserting
- `* pushing` - forced insertion acts
- `* play` - general activity categories
- `* enema` - fluid-based activities
- `* fisting` - extreme activity variants
- `* creampie` - completion-state variants

### Hub Tags (Category Roots)
These tags should have multiple children as category parents:
- `anal` (→ 21 children)
- `pussy` (→ 12 children)
- `enema` (→ 10 children)
- `pee` (→ 10 children)
- `blowjob` (→ 6 children, depth 5)
- `cum` (→ multiple subcategories)

## Alias Semantic Mapping

When creating aliases, use these patterns:

| Alias Starts With | Maps To Category |
|------------------|------------------|
| `ass`, `anal` | Body part variants |
| `piss`, `pee` | Urination/watersports |
| `cum` | Ejaculation |
| `shitty`, `dirty` | Scatological |
| `spit`, `drool` | Spit play |
| ` gag`, `throat` | Deep throat/blowjob |

## Orphan Management

### Identifying Orphans
Root tags with **no children** and **no parent count > 0** may be orphans.

### Cleanup Action
- Review orphan tags periodically
- Merge duplicates into canonical tag
- Delete truly unused tags

## Tag Creation Checklist

When creating a new tag, ensure:
- [ ] Name follows case conventions (lowercase or Title Case)
- [ ] 1-4 words maximum
- [ ] At least 2-3 aliases covering synonyms, shorthand, variations
- [ ] Parent assigned if tag belongs to category
- [ ] No circular hierarchy relationships
- [ ] Aliases unique case-insensitively
- [ ] No aliases identical to tag name