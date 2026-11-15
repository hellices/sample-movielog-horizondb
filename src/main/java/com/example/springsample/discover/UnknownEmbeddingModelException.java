package com.example.springsample.discover;

import java.util.List;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ResponseStatus;

/** A search named an embedding model that does not exist or has no endpoint configured. */
@ResponseStatus(HttpStatus.BAD_REQUEST)
public class UnknownEmbeddingModelException extends RuntimeException {

	private final List<String> available;

	UnknownEmbeddingModelException(List<EmbeddingModel> available) {
		super("Unknown or unconfigured embedding model");
		this.available = available.stream().map(EmbeddingModel::id).toList();
	}

	/** Ids of the configured models. */
	public List<String> getAvailable() {
		return available;
	}

}
