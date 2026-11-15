package com.example.springsample.discover;

import java.util.Arrays;
import java.util.List;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Embedding models used for query text. The catalog documents are embedded with the same models and dimensions by
 * {@code data/embed_catalog.py}; anything else makes the distances meaningless.
 *
 * @param endpoint Azure OpenAI endpoint, for example https://my-openai.openai.azure.com/ (blank disables
 * {@link EmbeddingModel#OPENAI})
 * @param deployment deployment name of text-embedding-3-large
 * @param dimensions output size, equal to the {@code vector(n)} column of {@code catalog.movie_docs}
 * @param apiVersion Azure OpenAI data-plane API version
 * @param bgeUrl base URL of the OpenAI-compatible embeddings server (vLLM in the sample) for
 * {@link EmbeddingModel#BGE}, for example http://embeddings.movielog.svc.cluster.local (blank disables it)
 * @param bgeModel served model name sent as {@code model}; vLLM rejects any other name
 * @param defaultModel model used when a search names none, {@code openai} or {@code bge}; see
 * {@link #defaultEmbeddingModel()}
 */
@ConfigurationProperties("app.discover.embedding")
public record EmbeddingProperties(String endpoint, String deployment, int dimensions, String apiVersion,
		String bgeUrl, String bgeModel, String defaultModel) {

	public EmbeddingProperties {
		endpoint = (endpoint == null) ? "" : endpoint.strip();
		deployment = (deployment == null || deployment.isBlank()) ? "text-embedding-3-large" : deployment;
		dimensions = (dimensions <= 0) ? EmbeddingModel.OPENAI.dimensions() : dimensions;
		apiVersion = (apiVersion == null || apiVersion.isBlank()) ? "2024-10-21" : apiVersion;
		bgeUrl = (bgeUrl == null) ? "" : bgeUrl.strip();
		bgeModel = (bgeModel == null || bgeModel.isBlank()) ? EmbeddingModel.BGE.modelName() : bgeModel.strip();
		defaultModel = (defaultModel == null) ? "" : defaultModel.strip();
		if (!defaultModel.isEmpty() && EmbeddingModel.fromId(defaultModel).isEmpty()) {
			throw new IllegalArgumentException("app.discover.embedding.default-model must be one of "
					+ Arrays.stream(EmbeddingModel.values()).map(EmbeddingModel::id).toList() + ": " + defaultModel);
		}
	}

	/** Azure OpenAI is configured. */
	public boolean enabled() {
		return !endpoint.isEmpty();
	}

	public boolean configured(EmbeddingModel model) {
		return switch (model) {
			case OPENAI -> enabled();
			case BGE -> !bgeUrl.isEmpty();
		};
	}

	public List<EmbeddingModel> configuredModels() {
		return Arrays.stream(EmbeddingModel.values()).filter(this::configured).toList();
	}

	/**
	 * The {@code default-model} when that model is configured; otherwise {@code bge} when the BGE URL is set and
	 * {@code openai} when it is not.
	 */
	public EmbeddingModel defaultEmbeddingModel() {
		return EmbeddingModel.fromId(defaultModel)
			.filter(this::configured)
			.orElse(configured(EmbeddingModel.BGE) ? EmbeddingModel.BGE : EmbeddingModel.OPENAI);
	}

}
