package com.example.springsample.discover;

import java.util.Locale;
import java.util.Optional;

import org.jspecify.annotations.Nullable;

/**
 * The embedding models whose vectors {@code catalog.movie_docs} stores, each in its own column. SQL takes the
 * column name and size only from here, never from request input.
 */
public enum EmbeddingModel {

	OPENAI("openai", "embedding", 1536, "text-embedding-3-large", "Azure OpenAI text-embedding-3-large"),

	BGE("bge", "embedding_bge", 1024, "dragonkue/BGE-m3-ko", "BGE-M3 한국어 (dragonkue/BGE-m3-ko)");

	private final String id;

	private final String column;

	private final int dimensions;

	private final String modelName;

	private final String label;

	EmbeddingModel(String id, String column, int dimensions, String modelName, String label) {
		this.id = id;
		this.column = column;
		this.dimensions = dimensions;
		this.modelName = modelName;
		this.label = label;
	}

	/** Value of the {@code model} request parameter and of the {@code model} metric tag. */
	public String id() {
		return id;
	}

	/** Column of {@code catalog.movie_docs} holding this model's document vectors. */
	public String column() {
		return column;
	}

	/** Size of the {@code vector(n)} column. */
	public int dimensions() {
		return dimensions;
	}

	/** Upstream model name; for {@link #BGE} the default of {@code app.discover.embedding.bge-model}. */
	public String modelName() {
		return modelName;
	}

	public String label() {
		return label;
	}

	/** {@code CAST(:param AS vector(n))} for a parameter holding this model's vector literal. */
	String castParameter(String parameter) {
		return "CAST(:" + parameter + " AS vector(" + dimensions + "))";
	}

	public static Optional<EmbeddingModel> fromId(@Nullable String id) {
		if (id == null) {
			return Optional.empty();
		}
		String key = id.strip().toLowerCase(Locale.ROOT);
		for (EmbeddingModel model : values()) {
			if (model.id.equals(key)) {
				return Optional.of(model);
			}
		}
		return Optional.empty();
	}

}
