-- Run as the HorizonDB administrator against the "movielog" database after data/embed_catalog.py.
-- DiskANN approximate nearest-neighbor indexes for cosine distance (<=>) on the 1,536-dimension Azure OpenAI and the
-- 1,024-dimension BGE-M3 embeddings.
\set ON_ERROR_STOP on

CREATE INDEX IF NOT EXISTS movie_docs_embedding_diskann
	ON catalog.movie_docs USING diskann (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS movie_docs_embedding_bge_diskann
	ON catalog.movie_docs USING diskann (embedding_bge vector_cosine_ops);

ANALYZE catalog.movie_docs;

SELECT count(*) AS documents, count(embedding) AS embedded, count(embedding_bge) AS embedded_bge
FROM catalog.movie_docs;
