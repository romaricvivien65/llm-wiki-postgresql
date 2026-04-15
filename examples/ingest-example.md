# Ingest Example: Annual Report 2025

This example shows the complete flow when Claude Code ingests a new document into the PostgreSQL-backed wiki.

## Starting Point

A PDF has been uploaded to `inbox/` and processed by [Distill](https://github.com/romaricvivien65/distill-skill):

```
raw/annual-report-2025/
├── 00_index.md
├── 01_executive_summary.md
├── 02_financial_results.md
├── 03_ongoing_projects.md
├── 04_outlook_2026.md
└── _sources.md
```

## What Claude Does

### 1. Read the distilled source files

Claude reads the markdown files in `raw/annual-report-2025/` using its standard Read tool.

### 2. Check what already exists in the wiki

```sql
-- What pages already exist in this wiki?
SELECT id, title, slug, type, updated_at
FROM pages
WHERE wiki_id = 1
ORDER BY type, title;
```

This replaces reading `index.md`. Claude now knows every existing page without parsing a long text file.

### 3. Check for related entities

```sql
-- Do we already have pages for entities mentioned in the report?
SELECT id, title FROM pages
WHERE wiki_id = 1
  AND type = 'entity'
  AND (title ILIKE '%aminata%' OR title ILIKE '%senegal%' OR title ILIKE '%bad%');
```

### 4. Create new pages

```sql
-- New entity: Aminata Sy (not found in existing pages)
INSERT INTO pages (wiki_id, title, slug, type, content, confidence)
VALUES (1, 'Aminata Sy', 'aminata-sy', 'entity',
'# Aminata Sy

Chief Financial Officer since January 2025. Appointed following the departure of Jean-Marc Dubois.

## Background
- Previously Finance Director at the African Development Bank (BAD)
- 15 years of experience in development finance

## Key Decisions at the Company
- Led Q3 2025 budget restructuring
- Initiated strategic partnership with BAD
- Introduced quarterly cash flow forecasting (replacing annual model)

## Sources
- Annual Report 2025, Executive Summary (Section 1.2)
- Annual Report 2025, Financial Results (Section 2.1)
', 'high')
RETURNING id;
-- Returns: id = 42
```

### 5. Update existing pages

```sql
-- Senegal page already exists (id = 7) — update it
UPDATE pages
SET content = content || '

## 2025 Update
The Senegal regional project was **discontinued** in Q2 2025 due to funding reallocation.
This decision was part of the broader portfolio review led by the new CFO.

*Source: Annual Report 2025, Section 3.4*
',
    updated_at = NOW()
WHERE id = 7 AND wiki_id = 1;
```

### 6. Create relationships

```sql
INSERT INTO relations (wiki_id, source_id, target_id, relation_type) VALUES
  (1, 42, 15, 'works_for'),       -- Aminata Sy → The Company
  (1, 42, 23, 'previously_at'),   -- Aminata Sy → BAD
  (1, 42, 8,  'related_to'),      -- Aminata Sy → Cash Flow Management
  (1, 42, 7,  'related_to'),      -- Aminata Sy → Senegal
  (1, 7,  42, 'related_to'),      -- Senegal → Aminata Sy (reverse link)
  (1, 42, 31, 'mentioned_in');    -- Aminata Sy → Annual Report 2025 (source-summary)
```

### 7. Record the source

```sql
INSERT INTO sources (wiki_id, original_name, raw_path, file_type, summary)
VALUES (1, 'Annual Report 2025', 'raw/annual-report-2025/', 'pdf',
        'Annual report covering FY2025 financial results, leadership changes, project portfolio review, and 2026 strategic outlook.')
RETURNING id;
-- Returns: id = 12

-- Link all affected pages to this source
INSERT INTO page_sources (page_id, source_id) VALUES
  (42, 12),   -- Aminata Sy
  (7, 12),    -- Senegal (updated)
  (8, 12),    -- Cash Flow Management (updated)
  (31, 12);   -- Annual Report 2025 (source-summary page)
```

### 8. Log the operation

```sql
INSERT INTO log (wiki_id, operation, details, pages_affected)
VALUES (1, 'ingest',
        'Annual Report 2025 — Created: Aminata Sy (entity), Annual Report 2025 (source-summary), CA 2024 vs 2025 (comparison). Updated: Senegal, Cash Flow Management, BAD. 6 relationships created.',
        6);
```

## Result

One PDF → 3 pages created, 3 pages updated, 6 relationships established, full source traceability.

The wiki just got richer. And PostgreSQL knows exactly what changed and why.
