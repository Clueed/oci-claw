# Stash Tags

## How Tags Work

### Tag Structure
- **Canonical name**: The primary tag name
- **Aliases**: Alternative names that resolve to this tag (used during auto-tagging, scraping, filename parsing)
- **Hierarchy**: Tags form a DAG (directed acyclic graph) — a tag can have multiple parents and multiple children, but no cycles

### Alias Resolution
When you search for a tag, stash automatically matches against:
1. The canonical name
2. All aliases

So searching `"lesbian girls"` will find the tag `"lesbian"` if `"lesbian girls"` is an alias. This is handled server-side via `findTags(filter: { q: "..." })`.

### Hierarchy
- **Parents**: Tags that are more general (e.g., `"Japanese"` might have parent `"Asian"`)
- **Children**: Tags that are more specific (e.g., `"Japanese Actress"` might be a child of `"Japanese"`)
- **Depth**: Count fields like `scene_count(depth: Int)` include descendant counts when depth is specified

Tags without any scenes, markers, images, galleries, performers, or studios are **orphan tags** — candidates for cleanup.

## Tag Operations

### Find Tags
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTags(filter: { q: \"NAME\" }) { tags { id name } } }"}'
```

### Find Tags with Aliases
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTags(filter: { q: \"QUERY\" }, tag_filter: {}) { tags { id name aliases } } }"}'
```

### Get Tag Hierarchy (parents + children)
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTag(id: \"TAG_ID\") { id name parents { id name } children { id name child_count parent_count } } }"}'
```

### Find Tags by Parent (hierarchy traversal)
```bash
# Find all children of a tag up to depth N
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTags(tag_filter: { children: { value: [\"PARENT_ID\"], modifier: INCLUDES, depth: 2 } }) { tags { id name parent_count child_count } } }"}'
```

### Find Orphan Tags (no scenes, images, etc.)
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTags(filter: {}, tag_filter: { scene_count: { value: 0, modifier: EQUALS }, image_count: { value: 0, modifier: EQUALS }, gallery_count: { value: 0, modifier: EQUALS }, performer_count: { value: 0, modifier: EQUALS }, studio_count: { value: 0, modifier: EQUALS } }) { tags { id name scene_count image_count gallery_count performer_count studio_count } } }"}'
```

### Bulk Resolve Aliases to Canonical Tags
```bash
# Resolve multiple search terms to their canonical tag names
for term in "lesbian girls" "Japanese actress" "bbw"; do
  curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
    -H "ApiKey: $STASH_API_KEY" \
    -d "{\"query\":\"{ findTags(filter: { q: \\\"$term\\\" }, tag_filter: {}) { tags { name aliases } } }\"}" \
    | jq -r '.data.findTags.tags[0] // empty | "\($term) → \(.name) (aliases: \(.aliases | join(", ")))"'
done
```

### Merge Tags (move all associations to destination)
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { tagsMerge(source: [\"SOURCE_ID_1\", \"SOURCE_ID_2\"], destination: \"DEST_ID\") { id } }"}'
```

## Detailed Reference

For full GraphQL schema details (filter types, mutation inputs, sort options), see [tags-details.md](./tags-details.md).
