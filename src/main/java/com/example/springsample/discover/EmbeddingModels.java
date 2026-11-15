package com.example.springsample.discover;

import java.util.List;

import org.jspecify.annotations.Nullable;
import org.springframework.stereotype.Component;

/** Routes embedding calls to the client of each {@link EmbeddingModel} and resolves the model of a request. */
@Component
class EmbeddingModels {

	private final EmbeddingProperties properties;

	private final EmbeddingClient openai;

	private final BgeEmbeddingClient bge;

	EmbeddingModels(EmbeddingProperties properties, EmbeddingClient openai, BgeEmbeddingClient bge) {
		this.properties = properties;
		this.openai = openai;
		this.bge = bge;
	}

	boolean isConfigured(EmbeddingModel model) {
		return properties.configured(model);
	}

	/** Models with an endpoint, in declaration order. */
	List<EmbeddingModel> configured() {
		return properties.configuredModels();
	}

	EmbeddingModel defaultModel() {
		return properties.defaultEmbeddingModel();
	}

	/**
	 * The default model when {@code requested} is blank, otherwise the named model if it is configured.
	 * @throws UnknownEmbeddingModelException for any other value
	 */
	EmbeddingModel resolve(@Nullable String requested) {
		if (requested == null || requested.isBlank()) {
			return defaultModel();
		}
		return EmbeddingModel.fromId(requested)
			.filter(this::isConfigured)
			.orElseThrow(() -> new UnknownEmbeddingModelException(configured()));
	}

	/** A vector of exactly {@link EmbeddingModel#dimensions()} values, so it fits the model's column. */
	float[] embed(EmbeddingModel model, String text) {
		float[] vector = switch (model) {
			case OPENAI -> openai.embed(text);
			case BGE -> bge.embed(text);
		};
		if (vector.length != model.dimensions()) {
			throw new EmbeddingUnavailableException("%s returned %d dimensions instead of %d".formatted(model.id(),
					vector.length, model.dimensions()), null);
		}
		return vector;
	}

}
