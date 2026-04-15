# Lint Example: Weekly Health Check

This example shows how the Lint operation works with the PostgreSQL-backed wiki. Most checks are pure SQL — Claude only needs to read pages flagged as problematic.

## The Lint Process

### Check 1: Orphan Pages (No Incoming Links)

Pages that nothing points to. They exist but are disconnected from the knowledge graph.

```sql
SELECT p.id, p.title, p.type, p.created_at
FROM pages p
LEFT JOIN relations r ON r.target_id = p.id
WHERE p.wiki_id = 1
  AND r.id IS NULL
ORDER BY p.created_at;
```

**Without PostgreSQL**: Claude would need to read every page, parse every `[[wikilink]]`, build a link map in memory, and find pages with zero incoming links. At 300 pages, this is error-prone.

**With PostgreSQL**: One query, instant result. Claude then reads only the orphan pages to decide: create links, merge into another page, or flag for review.

### Check 2: Stale Pages (Not Updated Recently)

Pages that haven't been touched in months may contain outdated information.

```sql
SELECT id, title, type, updated_at,
       EXTRACT(DAY FROM NOW() - updated_at) as days_since_update
FROM pages
WHERE wiki_id = 1
  AND updated_at < NOW() - INTERVAL '3 months'
ORDER BY updated_at;
```

### Check 3: Low Confidence Pages

Pages where Claude was uncertain during ingestion. These need human review or additional sources.

```sql
SELECT id, title, type, created_at
FROM pages
WHERE wiki_id = 1
  AND confidence = 'low'
ORDER BY created_at;
```

### Check 4: Unsourced Pages

Pages with no link to a source document. Where did this information come from?

```sql
SELECT p.id, p.title, p.type
FROM pages p
LEFT JOIN page_sources ps ON ps.page_id = p.id
WHERE ps.source_id IS NULL
  AND p.wiki_id = 1
  AND p.type NOT IN ('comparison', 'overview')
ORDER BY p.title;
```

### Check 5: Potential Contradictions

Pages linked by a "contradicts" relationship that haven't been resolved.

```sql
SELECT
    p1.title as page_a,
    p2.title as page_b,
    r.created_at as flagged_on
FROM relations r
JOIN pages p1 ON p1.id = r.source_id
JOIN pages p2 ON p2.id = r.target_id
WHERE r.relation_type = 'contradicts'
  AND r.wiki_id = 1
ORDER BY r.created_at;
```

### Check 6: Heavily Connected Pages (Hubs)

Pages with many connections might need splitting into sub-topics.

```sql
SELECT p.title,
       COUNT(DISTINCT CASE WHEN r.source_id = p.id THEN r.id END) as outgoing,
       COUNT(DISTINCT CASE WHEN r.target_id = p.id THEN r.id END) as incoming,
       COUNT(DISTINCT r.id) as total_links
FROM pages p
LEFT JOIN relations r ON (r.source_id = p.id OR r.target_id = p.id)
WHERE p.wiki_id = 1
GROUP BY p.id, p.title
HAVING COUNT(DISTINCT r.id) > 15
ORDER BY total_links DESC;
```

### Check 7: Wiki Statistics (Overall Health)

```sql
SELECT
    w.name,
    COUNT(DISTINCT p.id) as total_pages,
    COUNT(DISTINCT CASE WHEN p.type = 'concept' THEN p.id END) as concepts,
    COUNT(DISTINCT CASE WHEN p.type = 'entity' THEN p.id END) as entities,
    COUNT(DISTINCT CASE WHEN p.type = 'source-summary' THEN p.id END) as sources,
    COUNT(DISTINCT r.id) as total_relations,
    COUNT(DISTINCT CASE WHEN p.confidence = 'low' THEN p.id END) as low_confidence
FROM wikis w
LEFT JOIN pages p ON p.wiki_id = w.id
LEFT JOIN relations r ON r.wiki_id = w.id
WHERE w.id = 1
GROUP BY w.name;
```

## Lint Report

After running all checks, Claude generates a report:

```
## Lint Report — 2026-04-15

Wiki: Company Knowledge Base
Total pages: 287 | Relations: 1,432

### Issues Found
- 🔴 3 orphan pages (no incoming links)
- 🟡 12 stale pages (not updated in 3+ months)
- 🟡 5 low confidence pages
- 🔴 2 unresolved contradictions
- 🟡 1 unsourced page

### Recommendations
1. Review orphans: "Budget Q1 Draft", "Old Meeting Notes", "Temp Analysis"
2. Contradictions: "Revenue 2024" vs "Q4 Correction" — need reconciliation
3. Hub page "The Company" has 23 links — consider splitting by topic

### Action Taken
- Archived 2 orphan pages (confirmed obsolete)
- Updated confidence on 3 pages after source verification
- Created missing link: Cash Flow → Budget Q1

Next lint: 2026-04-22
```

```sql
-- Log the lint operation
INSERT INTO log (wiki_id, operation, details, pages_affected)
VALUES (1, 'lint',
        'Weekly lint: 3 orphans (2 archived), 2 contradictions (1 resolved), 12 stale pages flagged',
        5);
```

## Cost Comparison

| Lint Step | Without PostgreSQL | With PostgreSQL |
|-----------|-------------------|-----------------|
| Find orphans | Read all 287 pages | 1 SQL query |
| Find stale pages | Check file dates of 287 files | 1 SQL query |
| Find contradictions | Read all pages, compare claims | 1 SQL query on relations |
| Find unsourced pages | Read frontmatter of 287 pages | 1 SQL query |
| Generate statistics | Read everything | 1 SQL query |
| **Total Claude reads** | **~287 pages** | **~8 flagged pages** |
| **Time** | Minutes | Seconds |
