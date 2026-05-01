# Stash Tag API Documentation

## Tag Type Schema

```graphql
type Tag {
  id: ID!
  name: String!
  sort_name: String          # overrides name for sorting
  description: String
  aliases: [String!]!
  ignore_auto_tag: Boolean!
  favorite: Boolean!

  # Hierarchy (DAG - multiple parents/children allowed, no cycles)
  parents: [Tag!]!
  children: [Tag!]!
  parent_count: Int!
  child_count: Int!

  # Counts with optional depth for hierarchy traversal
  scene_count(depth: Int): Int!
  scene_marker_count(depth: Int): Int!
  image_count(depth: Int): Int!
  gallery_count(depth: Int): Int!
  performer_count(depth: Int): Int!
  studio_count(depth: Int): Int!
  group_count(depth: Int): Int!
}
```

## Hierarchy Structure

- **Parents/Children**: Directed acyclic graph (DAG) - tags can have multiple parents and multiple children
- **Depth parameter**: `depth: Int` on count fields includes descendant counts
- **Categories**: Tags organized via parent/child relationships (no separate `category` field in main API, used by stash-box integration)

## Aliases

- **Uniqueness**: Must be unique across all tags (case-insensitive)
- **Matching**: Used during auto-tag, scraping, and filename parsing
- **Validation**: Duplicates and aliases equal to name are ignored on create; return error on update

## Query Operations

| Query | Description |
|-------|-------------|
| `findTag(id: ID!)` | Single tag by ID |
| `findTags(tag_filter, filter, ids)` | Paginated list with filtering |

### Find Tags with Hierarchy

```bash
curl -s -X POST http://localhost:9999/graphql \
  -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findTags(filter: { q: \"Japanese\" }, tag_filter: {}) { tags { id name parents { id name } children { id name } } } }"}'
```

### Filter by Hierarchy

```graphql
findTags(tag_filter: {
  children: { value: ["parent_id"], modifier: INCLUDES, depth: 2 }
}) { tags { id name } }
```

## TagFilterType - Key Filters

| Filter | Type |
|--------|------|
| `name`, `aliases`, `description` | `StringCriterionInput` |
| `favorite`, `ignore_auto_tag` | `Boolean` |
| `parent_count`, `child_count` | `IntCriterionInput` |
| `parents`, `children` | `HierarchicalMultiCriterionInput` (value, modifier, depth, excludes) |
| `scene_count`, etc. | `IntCriterionInput` |

## Mutations

| Mutation | Input | Description |
|----------|-------|-------------|
| `tagCreate` | `TagCreateInput!` | Create tag |
| `tagUpdate` | `TagUpdateInput!` | Update tag |
| `tagDestroy` | `TagDestroyInput!` | Delete tag |
| `tagsDestroy` | `ids: [ID!]!` | Delete multiple |
| `tagsMerge` | `source: [ID!]!, destination: ID!` | Merge into destination |
| `bulkTagUpdate` | `BulkTagUpdateInput!` | Bulk operations |

### Create Tag with Aliases and Parent

```bash
curl -s -X POST http://localhost:9999/graphql \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { tagCreate(input: {name: \"Japanese\", aliases: [\"Japanese Actress\"], parent_ids: [\"parent_id\"]}) { id name aliases } }"}'
```

## Sort Options

`created_at`, `galleries_count`, `id`, `images_count`, `name`, `performers_count`, `random`, `scene_markers_count`, `scenes_count`, `updated_at`
