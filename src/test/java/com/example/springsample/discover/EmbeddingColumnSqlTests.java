package com.example.springsample.discover;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import java.util.EnumMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.core.simple.JdbcClient.MappedQuerySpec;
import org.springframework.jdbc.core.simple.JdbcClient.StatementSpec;

/** The SQL compares and writes only the columns of the chosen models, cast to their vector sizes. */
class EmbeddingColumnSqlTests {

	private final JdbcClient jdbc = mock();

	private final StatementSpec statement = mock(StatementSpec.class, RETURNS_SELF);

	private final ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);

	@BeforeEach
	@SuppressWarnings({ "unchecked", "rawtypes" })
	void stubJdbc() {
		given(jdbc.sql(sql.capture())).willReturn(statement);
		MappedQuerySpec mapped = mock();
		given(statement.query(any(RowMapper.class))).willReturn(mapped);
		given(mapped.list()).willReturn(List.of());
	}

	@Test
	void searchUsesTheBgeColumnAndCastsTheQueryToItsSize() {
		new VectorSearchRepository(jdbc).search(EmbeddingModel.BGE, new float[] { 0.5f, 0.25f }, "듄", 12);

		assertThat(sql.getValue()).contains("CAST(:v AS vector(1024))", "d.embedding_bge <=> q.v",
				"d.embedding_bge IS NOT NULL")
			.doesNotContainPattern("embedding(?!_bge)");
		verify(statement).param("v", "[0.5,0.25]");
	}

	@Test
	void searchUsesTheOpenAiColumnForOpenAi() {
		new VectorSearchRepository(jdbc).search(EmbeddingModel.OPENAI, new float[] { 1f }, "듄", 12);

		assertThat(sql.getValue()).contains("CAST(:v AS vector(1536))", "d.embedding <=> q.v")
			.doesNotContain("embedding_bge");
	}

	@Test
	void similarComparesOnlyTheChosenColumn() {
		new VectorSearchRepository(jdbc).similar(EmbeddingModel.BGE, 693134, 6);

		assertThat(sql.getValue()).contains("d.embedding_bge <=> (SELECT embedding_bge FROM catalog.movie_docs")
			.doesNotContainPattern("embedding(?!_bge)");
	}

	@Test
	void insertWritesOneColumnPerEmbeddedModel() {
		Map<EmbeddingModel, float[]> vectors = new EnumMap<>(EmbeddingModel.class);
		vectors.put(EmbeddingModel.OPENAI, new float[] { 1f });
		vectors.put(EmbeddingModel.BGE, new float[] { 2f });

		new CatalogIndexRepository(jdbc).insert(693134, "제목: 듄: 파트 2", vectors);

		assertThat(sql.getValue()).contains("(tmdb_id, doc, embedding, embedding_bge, embedded_at)",
				"(:tmdbId, :doc, CAST(:openai AS vector(1536)), CAST(:bge AS vector(1024)), now())");
		verify(statement).param("openai", "[1.0]");
		verify(statement).param("bge", "[2.0]");
		verify(statement).update();
	}

	@Test
	void insertWithOnlyBgeLeavesTheOpenAiColumnNull() {
		new CatalogIndexRepository(jdbc).insert(693134, "제목: 듄: 파트 2", Map.of(EmbeddingModel.BGE, new float[] { 2f }));

		assertThat(sql.getValue()).contains("(tmdb_id, doc, embedding_bge, embedded_at)")
			.doesNotContainPattern("embedding(?!_bge)");
	}

}
