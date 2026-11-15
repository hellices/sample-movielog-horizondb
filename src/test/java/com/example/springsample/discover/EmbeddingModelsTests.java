package com.example.springsample.discover;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

import org.junit.jupiter.api.Test;

class EmbeddingModelsTests {

	private static final String AOAI = "https://aoai.test";

	private static final String BGE = "http://embeddings.test";

	private final EmbeddingClient openai = mock();

	private final BgeEmbeddingClient bge = mock();

	private static EmbeddingProperties properties(String endpoint, String bgeUrl, String defaultModel) {
		return new EmbeddingProperties(endpoint, null, 0, null, bgeUrl, null, defaultModel);
	}

	private EmbeddingModels models(String endpoint, String bgeUrl, String defaultModel) {
		return new EmbeddingModels(properties(endpoint, bgeUrl, defaultModel), openai, bge);
	}

	@Test
	void eachModelHasAFixedColumnAndVectorSize() {
		assertThat(EmbeddingModel.OPENAI.column()).isEqualTo("embedding");
		assertThat(EmbeddingModel.OPENAI.dimensions()).isEqualTo(1536);
		assertThat(EmbeddingModel.OPENAI.castParameter("v")).isEqualTo("CAST(:v AS vector(1536))");
		assertThat(EmbeddingModel.BGE.column()).isEqualTo("embedding_bge");
		assertThat(EmbeddingModel.BGE.dimensions()).isEqualTo(1024);
		assertThat(EmbeddingModel.BGE.castParameter("v")).isEqualTo("CAST(:v AS vector(1024))");
	}

	@Test
	void modelIdsAreMatchedOnlyAgainstTheWhitelist() {
		assertThat(EmbeddingModel.fromId(" BGE ")).contains(EmbeddingModel.BGE);
		assertThat(EmbeddingModel.fromId("openai")).contains(EmbeddingModel.OPENAI);
		assertThat(EmbeddingModel.fromId("embedding_bge")).isEmpty();
		assertThat(EmbeddingModel.fromId("bge; DROP TABLE catalog.movie_docs")).isEmpty();
		assertThat(EmbeddingModel.fromId(null)).isEmpty();
	}

	@Test
	void defaultModelIsBgeWhenTheBgeUrlIsSetAndOpenAiOtherwise() {
		assertThat(properties(AOAI, BGE, null).defaultEmbeddingModel()).isEqualTo(EmbeddingModel.BGE);
		assertThat(properties("", BGE, "").defaultEmbeddingModel()).isEqualTo(EmbeddingModel.BGE);
		assertThat(properties(AOAI, "", null).defaultEmbeddingModel()).isEqualTo(EmbeddingModel.OPENAI);
		assertThat(properties("", "", null).defaultEmbeddingModel()).isEqualTo(EmbeddingModel.OPENAI);
	}

	@Test
	void configuredDefaultModelWinsOnlyWhenThatModelIsConfigured() {
		assertThat(properties(AOAI, BGE, "openai").defaultEmbeddingModel()).isEqualTo(EmbeddingModel.OPENAI);
		assertThat(properties(AOAI, "", "bge").defaultEmbeddingModel()).isEqualTo(EmbeddingModel.OPENAI);
		assertThat(properties("", BGE, "openai").defaultEmbeddingModel()).isEqualTo(EmbeddingModel.BGE);
	}

	@Test
	void unknownDefaultModelFailsAtStartup() {
		assertThatThrownBy(() -> properties(AOAI, BGE, "gpt")).isInstanceOf(IllegalArgumentException.class)
			.hasMessageContaining("default-model");
	}

	@Test
	void configuredModelsFollowTheirEndpoints() {
		assertThat(properties(AOAI, BGE, null).configuredModels()).containsExactly(EmbeddingModel.OPENAI,
				EmbeddingModel.BGE);
		assertThat(properties("", BGE, null).configuredModels()).containsExactly(EmbeddingModel.BGE);
		assertThat(properties(" ", " ", null).configuredModels()).isEmpty();
	}

	@Test
	void resolvesBlankToTheDefaultAndRejectsUnknownOrUnconfiguredModels() {
		EmbeddingModels models = models(AOAI, "", null);

		assertThat(models.resolve(null)).isEqualTo(EmbeddingModel.OPENAI);
		assertThat(models.resolve(" ")).isEqualTo(EmbeddingModel.OPENAI);
		assertThat(models.resolve("OpenAI")).isEqualTo(EmbeddingModel.OPENAI);
		assertThatThrownBy(() -> models.resolve("bge")).isInstanceOf(UnknownEmbeddingModelException.class)
			.satisfies(ex -> assertThat(((UnknownEmbeddingModelException) ex).getAvailable()).containsExactly("openai"));
		assertThatThrownBy(() -> models.resolve("embedding")).isInstanceOf(UnknownEmbeddingModelException.class);
	}

	@Test
	void routesBgeOnlyToTheBgeClient() {
		EmbeddingModels models = models(AOAI, BGE, null);
		given(bge.embed("질문")).willReturn(new float[1024]);

		assertThat(models.embed(EmbeddingModel.BGE, "질문")).hasSize(1024);
		verify(bge, times(1)).embed("질문");
		verifyNoInteractions(openai);
	}

	@Test
	void routesOpenAiOnlyToTheOpenAiClient() {
		EmbeddingModels models = models(AOAI, BGE, null);
		given(openai.embed("질문")).willReturn(new float[1536]);

		assertThat(models.embed(EmbeddingModel.OPENAI, "질문")).hasSize(1536);
		verify(openai, times(1)).embed("질문");
		verifyNoInteractions(bge);
	}

	@Test
	void rejectsVectorsOfTheWrongSize() {
		EmbeddingModels models = models(AOAI, BGE, null);
		given(openai.embed("질문")).willReturn(new float[3]);

		assertThatThrownBy(() -> models.embed(EmbeddingModel.OPENAI, "질문"))
			.isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("3 dimensions instead of 1536");
		verify(openai, times(1)).embed("질문");
		verifyNoInteractions(bge);
	}

}
