package com.example.springsample.discover;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import org.jspecify.annotations.Nullable;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/**
 * Embeds text with {@link EmbeddingModel#BGE} served by an OpenAI-compatible embeddings server (vLLM in the sample)
 * inside the cluster, through {@code POST /v1/embeddings}. The server is not exposed outside the cluster and takes no
 * credentials. The request names {@link EmbeddingProperties#bgeModel()}, which must equal the served model name.
 */
@Component
class BgeEmbeddingClient {

	/** Inputs per request, so one call never sends an unbounded batch. */
	static final int MAX_BATCH = 32;

	private final EmbeddingProperties properties;

	private final RestClient rest;

	BgeEmbeddingClient(EmbeddingProperties properties, RestClient.Builder builder) {
		this.properties = properties;
		this.rest = builder.clone().baseUrl(properties.bgeUrl()).build();
	}

	boolean isEnabled() {
		return properties.configured(EmbeddingModel.BGE);
	}

	float[] embed(String text) {
		return embedAll(List.of(text)).getFirst();
	}

	/** Vectors in the order of {@code texts}, requested in batches of {@link #MAX_BATCH}. */
	List<float[]> embedAll(List<String> texts) {
		if (!isEnabled()) {
			throw new EmbeddingUnavailableException("Embedding endpoint is not configured (EMBEDDINGS_BGE_URL)", null);
		}
		List<float[]> vectors = new ArrayList<>(texts.size());
		for (int start = 0; start < texts.size(); start += MAX_BATCH) {
			vectors.addAll(embedBatch(texts.subList(start, Math.min(start + MAX_BATCH, texts.size()))));
		}
		return vectors;
	}

	private List<float[]> embedBatch(List<String> texts) {
		EmbeddingResponse response;
		try {
			response = rest.post()
				.uri("/v1/embeddings")
				.contentType(MediaType.APPLICATION_JSON)
				.body(Map.of("input", texts, "model", properties.bgeModel()))
				.retrieve()
				.body(EmbeddingResponse.class);
		}
		catch (RestClientException ex) {
			throw new EmbeddingUnavailableException("BGE embedding call failed", ex);
		}
		if (response == null || response.data() == null || response.data().size() != texts.size()) {
			throw new EmbeddingUnavailableException("BGE embedding server returned "
					+ ((response == null || response.data() == null) ? 0 : response.data().size()) + " embeddings for "
					+ texts.size() + " inputs", null);
		}
		if (!indexesCoverInputs(response.data(), texts.size())) {
			throw new EmbeddingUnavailableException("BGE embedding server returned indexes "
					+ response.data().stream().map(item -> (item != null) ? item.index() : null).toList() + " for " + texts.size()
					+ " inputs", null);
		}
		return response.data()
			.stream()
			.sorted(Comparator.comparingInt(EmbeddingResponse.Item::index))
			.map(item -> toArray(item.embedding()))
			.toList();
	}

	/** Whether the indexes are exactly 0..size-1, each once, so sorting by index restores the input order. */
	private static boolean indexesCoverInputs(List<EmbeddingResponse.Item> items, int size) {
		boolean[] seen = new boolean[size];
		for (EmbeddingResponse.Item item : items) {
			Integer index = (item != null) ? item.index() : null;
			if (index == null || index < 0 || index >= size || seen[index]) {
				return false;
			}
			seen[index] = true;
		}
		return true;
	}

	private static float[] toArray(List<Float> values) {
		if (values == null || values.isEmpty()) {
			throw new EmbeddingUnavailableException("Empty embedding in the BGE embedding response", null);
		}
		float[] vector = new float[values.size()];
		for (int i = 0; i < vector.length; i++) {
			vector[i] = values.get(i);
		}
		return vector;
	}

	@JsonIgnoreProperties(ignoreUnknown = true)
	record EmbeddingResponse(List<Item> data) {

		@JsonIgnoreProperties(ignoreUnknown = true)
		record Item(@Nullable Integer index, List<Float> embedding) {
		}

	}

}
