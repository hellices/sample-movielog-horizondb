package com.example.springsample.discover;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.mock;

import java.util.List;
import java.util.Optional;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

class DiscoverServiceModelTests {

	private final EmbeddingModels embeddings = mock();

	private final VectorSearchRepository vectors = mock();

	private final DiscoverRateLimiter rateLimiter = mock();

	private final QueryCorrector corrector = mock();

	private final SimpleMeterRegistry registry = new SimpleMeterRegistry();

	private final DiscoverService service = new DiscoverService(embeddings, vectors, mock(), registry, rateLimiter,
			corrector, mock());

	@Test
	void searchesTheChosenModelsColumnAndTagsTheTimersWithTheModel() {
		MovieHit dune = new MovieHit(438631, "듄", "Dune", 2021, List.of("SF"), null, null, 0.6);
		float[] vector = new float[1024];
		given(rateLimiter.tryAcquire("10.0.0.1")).willReturn(true);
		given(corrector.correct("듄")).willReturn(Optional.empty());
		given(embeddings.embed(EmbeddingModel.BGE, "듄")).willReturn(vector);
		given(vectors.search(EmbeddingModel.BGE, vector, "듄", 12)).willReturn(List.of(dune));

		DiscoverService.DiscoverSearch search = service.searchWithCorrection("듄", 12, "10.0.0.1", EmbeddingModel.BGE);

		assertThat(search.hits()).containsExactly(dune);
		assertThat(search.model()).isEqualTo(EmbeddingModel.BGE);
		assertThat(registry.get("movielog.discover.embedding")
			.tags("kind", "query", "model", "bge", "outcome", "found")
			.timer()
			.count()).isEqualTo(1);
		assertThat(registry.get("movielog.discover.search")
			.tags("kind", "vector", "model", "bge", "outcome", "found")
			.timer()
			.count()).isEqualTo(1);
	}

	@Test
	void similarWithoutAModelUsesTheDefaultModel() {
		given(embeddings.defaultModel()).willReturn(EmbeddingModel.BGE);
		given(vectors.similar(EmbeddingModel.BGE, 438631, 6)).willReturn(List.of());

		assertThat(service.similar(438631, 6)).isEmpty();
		assertThat(registry.get("movielog.discover.similar")
			.tags("kind", "vector", "model", "bge", "outcome", "empty")
			.timer()
			.count()).isEqualTo(1);
	}

}
