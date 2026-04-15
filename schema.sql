-- =============================================================================
-- LLM Wiki + PostgreSQL Schema
-- A structured backbone for AI-maintained knowledge bases
--
-- This schema replaces the file-based wiki/ directory from Karpathy's LLM Wiki
-- with a PostgreSQL database that stores both content (markdown) and structure
-- (relationships, metadata, traceability).
--
-- Author: romaricvivien65
-- License: MIT
-- Status: Theoretical — not yet tested in production
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. WIKIS — Multi-wiki support
-- One wiki per department, client, or project
-- -----------------------------------------------------------------------------

CREATE TABLE wikis (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL UNIQUE,
    description TEXT,
    schema_version INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE wikis IS 'Each wiki is an independent knowledge base. Supports multi-tenant setups.';

-- -----------------------------------------------------------------------------
-- 2. PAGES — The core of the wiki
-- Replaces: wiki/concepts/*.md, wiki/entities/*.md, wiki/sources/*.md, etc.
-- The content column stores full markdown — the same content that would live
-- in a .md file, now queryable and indexable.
-- -----------------------------------------------------------------------------

CREATE TABLE pages (
    id SERIAL PRIMARY KEY,
    wiki_id INTEGER NOT NULL REFERENCES wikis(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL,
    type VARCHAR(50) NOT NULL CHECK (type IN (
        'concept',          -- Abstract ideas, methodologies, frameworks
        'entity',           -- People, organizations, places, products
        'source-summary',   -- Summary of an ingested source document
        'comparison',       -- Side-by-side analysis of two or more pages
        'overview',         -- High-level synthesis (like overview.md)
        'custom'            -- Client-specific page types
    )),
    content TEXT NOT NULL,                          -- Full markdown content
    confidence VARCHAR(20) DEFAULT 'medium' CHECK (confidence IN ('high', 'medium', 'low')),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(wiki_id, slug)
);

CREATE INDEX idx_pages_wiki_type ON pages(wiki_id, type);
CREATE INDEX idx_pages_updated ON pages(wiki_id, updated_at);

COMMENT ON TABLE pages IS 'Every wiki page. Content is markdown stored in TEXT column. Replaces individual .md files.';
COMMENT ON COLUMN pages.slug IS 'URL-friendly identifier. Matches what would have been the filename (e.g., aminata-sy).';
COMMENT ON COLUMN pages.confidence IS 'How confident is the LLM in this page accuracy? Set during ingestion, reviewed during lint.';

-- -----------------------------------------------------------------------------
-- 3. RELATIONS — The knowledge graph
-- Replaces: [[wikilinks]] in markdown files
-- Typed, directional relationships between pages.
-- This is what makes navigation and lint scale beyond 200 pages.
-- -----------------------------------------------------------------------------

CREATE TABLE relations (
    id SERIAL PRIMARY KEY,
    wiki_id INTEGER NOT NULL REFERENCES wikis(id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    target_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    relation_type VARCHAR(100) NOT NULL,
    confidence VARCHAR(20) DEFAULT 'medium' CHECK (confidence IN ('high', 'medium', 'low')),
    created_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(source_id, target_id, relation_type)
);

CREATE INDEX idx_relations_source ON relations(source_id);
CREATE INDEX idx_relations_target ON relations(target_id);
CREATE INDEX idx_relations_wiki ON relations(wiki_id);
CREATE INDEX idx_relations_type ON relations(relation_type);

COMMENT ON TABLE relations IS 'Typed, directional links between pages. The knowledge graph.';
COMMENT ON COLUMN relations.relation_type IS 'E.g.: works_for, partner_of, contradicts, supersedes, depends_on, mentioned_in, related_to, part_of, located_in';

-- -----------------------------------------------------------------------------
-- 4. SOURCES — Document traceability
-- Replaces: wiki/sources/*.md (partially — the detailed summary is in pages)
-- Tracks which original documents were ingested and when.
-- -----------------------------------------------------------------------------

CREATE TABLE sources (
    id SERIAL PRIMARY KEY,
    wiki_id INTEGER NOT NULL REFERENCES wikis(id) ON DELETE CASCADE,
    original_name VARCHAR(500) NOT NULL,
    raw_path VARCHAR(500),                         -- Path in raw/ directory
    file_type VARCHAR(50),                         -- 'pdf', 'docx', 'md', 'scan'
    ingested_at TIMESTAMP DEFAULT NOW(),
    summary TEXT                                   -- Short summary of the source
);

CREATE INDEX idx_sources_wiki ON sources(wiki_id);

COMMENT ON TABLE sources IS 'Every source document that was ingested. Immutable record for traceability.';

-- -----------------------------------------------------------------------------
-- 5. PAGE_SOURCES — Which pages came from which sources
-- Many-to-many: one source can create multiple pages, one page can cite
-- multiple sources.
-- -----------------------------------------------------------------------------

CREATE TABLE page_sources (
    page_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    PRIMARY KEY (page_id, source_id)
);

COMMENT ON TABLE page_sources IS 'Links pages to their source documents. Answers: where did this information come from?';

-- -----------------------------------------------------------------------------
-- 6. LOG — Operation history
-- Replaces: wiki/log.md
-- Append-only record of every operation performed on the wiki.
-- -----------------------------------------------------------------------------

CREATE TABLE log (
    id SERIAL PRIMARY KEY,
    wiki_id INTEGER NOT NULL REFERENCES wikis(id) ON DELETE CASCADE,
    operation VARCHAR(50) NOT NULL CHECK (operation IN (
        'ingest',     -- New source document processed
        'query',      -- Complex question answered by Claude
        'lint',       -- Health check performed
        'update',     -- Manual page update
        'delete',     -- Page removed
        'archive'     -- Monthly log archive
    )),
    details TEXT,
    pages_affected INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_log_wiki_date ON log(wiki_id, created_at DESC);
CREATE INDEX idx_log_operation ON log(operation);

COMMENT ON TABLE log IS 'Chronological record of all wiki operations. Replaces log.md.';

-- =============================================================================
-- FULL-TEXT SEARCH
-- PostgreSQL built-in search engine. No external tools needed.
-- Weighted: title matches rank higher than content matches.
-- =============================================================================

ALTER TABLE pages ADD COLUMN search_vector tsvector;
CREATE INDEX idx_pages_search ON pages USING gin(search_vector);

-- Auto-update search vector on insert or update
CREATE OR REPLACE FUNCTION update_search_vector() RETURNS trigger AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.content, '')), 'B');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pages_search_update
    BEFORE INSERT OR UPDATE ON pages
    FOR EACH ROW EXECUTE FUNCTION update_search_vector();

COMMENT ON COLUMN pages.search_vector IS 'Auto-maintained full-text search index. Title weighted higher than content.';

-- =============================================================================
-- AUTO-UPDATE TIMESTAMPS
-- =============================================================================

CREATE OR REPLACE FUNCTION update_timestamp() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pages_timestamp
    BEFORE UPDATE ON pages
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

CREATE TRIGGER wikis_timestamp
    BEFORE UPDATE ON wikis
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- =============================================================================
-- USEFUL VIEWS
-- Pre-built queries for common operations
-- =============================================================================

-- Replaces index.md: full catalog of all pages
CREATE VIEW wiki_index AS
SELECT
    p.wiki_id,
    w.name as wiki_name,
    p.id,
    p.title,
    p.slug,
    p.type,
    p.confidence,
    p.created_at,
    p.updated_at,
    (SELECT COUNT(*) FROM relations r WHERE r.source_id = p.id) as outgoing_links,
    (SELECT COUNT(*) FROM relations r WHERE r.target_id = p.id) as incoming_links,
    (SELECT COUNT(*) FROM page_sources ps WHERE ps.page_id = p.id) as source_count
FROM pages p
JOIN wikis w ON w.id = p.wiki_id
ORDER BY p.wiki_id, p.type, p.title;

COMMENT ON VIEW wiki_index IS 'Replaces index.md. Full catalog of all pages with link and source counts.';

-- Orphan pages: no incoming links (potential lint issue)
CREATE VIEW orphan_pages AS
SELECT p.wiki_id, p.id, p.title, p.type, p.updated_at
FROM pages p
LEFT JOIN relations r ON r.target_id = p.id
WHERE r.id IS NULL
ORDER BY p.wiki_id, p.updated_at;

COMMENT ON VIEW orphan_pages IS 'Pages with no incoming links. Lint should review these.';

-- Stale pages: not updated in over 6 months
CREATE VIEW stale_pages AS
SELECT wiki_id, id, title, type, updated_at,
       NOW() - updated_at as age
FROM pages
WHERE updated_at < NOW() - INTERVAL '6 months'
ORDER BY updated_at;

COMMENT ON VIEW stale_pages IS 'Pages not updated in 6+ months. May contain outdated information.';

-- Unsourced pages: no source traceability
CREATE VIEW unsourced_pages AS
SELECT p.wiki_id, p.id, p.title, p.type
FROM pages p
LEFT JOIN page_sources ps ON ps.page_id = p.id
WHERE ps.source_id IS NULL
  AND p.type NOT IN ('comparison', 'overview')
ORDER BY p.wiki_id, p.title;

COMMENT ON VIEW unsourced_pages IS 'Pages with no linked source documents. Traceability gap.';

-- Relationship summary: types and counts
CREATE VIEW relation_summary AS
SELECT wiki_id, relation_type, COUNT(*) as count
FROM relations
GROUP BY wiki_id, relation_type
ORDER BY wiki_id, count DESC;

COMMENT ON VIEW relation_summary IS 'Overview of relationship types in each wiki.';

-- =============================================================================
-- SAMPLE DATA
-- Uncomment to test the schema with example data
-- =============================================================================

/*
-- Create a wiki
INSERT INTO wikis (name, slug, description)
VALUES ('Company Knowledge Base', 'company-kb', 'Institutional memory for the organization');

-- Create some pages
INSERT INTO pages (wiki_id, title, slug, type, content, confidence) VALUES
(1, 'Aminata Sy', 'aminata-sy', 'entity',
'# Aminata Sy

Chief Financial Officer since January 2025.

## Background
Previously served as Finance Director at BAD.

## Key Decisions
- Led Q3 2025 budget restructuring
- Initiated partnership with African Development Bank

## Sources
- Annual Report 2025, Section 1
', 'high'),

(1, 'Cash Flow Management', 'cash-flow-management', 'concept',
'# Cash Flow Management

The company''s approach to cash flow management shifted significantly in 2025
following the appointment of the new CFO.

## Current Strategy
Focus on quarterly forecasting with monthly variance analysis.

## Historical Context
Prior to 2025, cash flow was managed on an annual basis.
', 'medium'),

(1, 'Annual Report 2025', 'annual-report-2025', 'source-summary',
'# Annual Report 2025

## Key Highlights
- Revenue: 2.3B FCFA (+12% YoY)
- New CFO appointed: Aminata Sy
- Senegal project discontinued
- New partnership with African Development Bank

## Document Details
- Pages: 80
- Ingested: 2026-04-15
- Confidence: High (primary source)
', 'high');

-- Create relationships
INSERT INTO relations (wiki_id, source_id, target_id, relation_type) VALUES
(1, 1, 2, 'related_to'),         -- Aminata Sy → Cash Flow Management
(1, 1, 3, 'mentioned_in'),       -- Aminata Sy → Annual Report 2025
(1, 2, 3, 'mentioned_in');       -- Cash Flow Management → Annual Report 2025

-- Record the source
INSERT INTO sources (wiki_id, original_name, raw_path, file_type, summary) VALUES
(1, 'Annual Report 2025', 'raw/annual-report-2025/', 'pdf',
 'Company annual report covering financial results, personnel changes, and 2026 outlook.');

-- Link pages to source
INSERT INTO page_sources (page_id, source_id) VALUES (1, 1), (2, 1), (3, 1);

-- Log the operation
INSERT INTO log (wiki_id, operation, details, pages_affected) VALUES
(1, 'ingest', 'Annual Report 2025 — 3 pages created, 0 updated', 3);
*/

-- =============================================================================
-- FUTURE: pgvector for semantic search
-- Uncomment when ready to add vector embeddings
-- =============================================================================

/*
CREATE EXTENSION vector;
ALTER TABLE pages ADD COLUMN embedding vector(1536);
CREATE INDEX idx_pages_embedding ON pages USING ivfflat (embedding vector_cosine_ops);

-- Semantic search query
-- SELECT title, content
-- FROM pages
-- WHERE wiki_id = 1
-- ORDER BY embedding <=> $query_embedding
-- LIMIT 10;
*/
