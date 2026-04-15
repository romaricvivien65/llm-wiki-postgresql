# Query Example: "What are our active partnerships in West Africa?"

This example shows how a question is answered using the PostgreSQL-backed wiki.

## Two Types of Queries

### Type 1: Simple Search (Web Server Only — No Claude Needed)

The client types "partnerships" in the search bar. The web server handles this directly:

```sql
-- Full-text search (PostgreSQL built-in)
SELECT title, type, LEFT(content, 200) as preview,
       ts_rank(search_vector, query) as relevance
FROM pages,
     to_tsquery('english', 'partnership & active') query
WHERE wiki_id = 1
  AND search_vector @@ query
ORDER BY relevance DESC
LIMIT 10;
```

Result displayed in the browser — a list of matching pages with previews. Claude is not involved. **Zero cost.**

### Type 2: Complex Question (Claude Required)

The client asks: *"What are the implications of the Q3 restructuring on our West Africa partnerships?"*

This requires reasoning across multiple pages. The web server passes the question to Claude.

## How Claude Answers (Step by Step)

### Step 1: Find relevant pages via SQL

```sql
-- Find pages related to partnerships
SELECT p.id, p.title, p.type
FROM pages p
JOIN relations r ON (r.source_id = p.id OR r.target_id = p.id)
WHERE p.wiki_id = 1
  AND (r.relation_type = 'partner_of'
       OR p.content ILIKE '%partnership%'
       OR p.content ILIKE '%west africa%')
GROUP BY p.id, p.title, p.type;
```

Result: 5 pages identified (BAD, Senegal, USAID, Cash Flow Management, Q3 Budget Review).

### Step 2: Get the relationships between them

```sql
-- How are these pages connected?
SELECT
    p1.title as from_page,
    r.relation_type,
    p2.title as to_page
FROM relations r
JOIN pages p1 ON p1.id = r.source_id
JOIN pages p2 ON p2.id = r.target_id
WHERE r.wiki_id = 1
  AND (r.source_id IN (23, 7, 44, 8, 51)
       OR r.target_id IN (23, 7, 44, 8, 51));
```

Result: Claude sees the full relationship map between these 5 pages.

### Step 3: Read only the relevant pages

```sql
-- Read the full content of the 5 relevant pages
SELECT title, content FROM pages
WHERE id IN (23, 7, 44, 8, 51);
```

Claude reads 5 pages instead of 300. Focused, efficient.

### Step 4: Synthesize and answer

Claude combines the information from the 5 pages, follows the relationships, and writes a structured answer:

> The Q3 restructuring led by Aminata Sy reallocated funding from the discontinued Senegal project to the BAD partnership, strengthening our West Africa presence through a different channel. The USAID partnership remains unaffected as it operates on a separate funding track. Key implication: our West Africa strategy has shifted from direct project execution (Senegal) to institutional partnerships (BAD), which carries lower operational risk but longer implementation timelines.

### Step 5: Optionally save the answer as a new page

If the answer is valuable, Claude can save it back into the wiki:

```sql
INSERT INTO pages (wiki_id, title, slug, type, content, confidence)
VALUES (1,
        'West Africa Partnership Strategy Post-Q3',
        'west-africa-partnership-strategy-post-q3',
        'comparison',
        '# West Africa Partnership Strategy Post-Q3 Restructuring

... (the full answer as markdown) ...

## Sources
- BAD partnership page
- Senegal project page
- Q3 Budget Review
- Cash Flow Management
', 'medium');
```

This is what Karpathy calls "good answers filed back into the wiki as new pages" — the wiki gets smarter with each question asked.

## Comparison

| Aspect | Without PostgreSQL | With PostgreSQL |
|--------|-------------------|-----------------|
| Find relevant pages | Read index.md (300 lines) | SQL query (instant) |
| See connections | Parse wikilinks in text | Query relations table |
| Read content | Open 5 separate .md files | One SELECT returning 5 rows |
| Pages Claude reads | Possibly 15-20 (guessing) | Exactly 5 (targeted) |
| Simple search | Requires Claude | Web server handles it (free) |
