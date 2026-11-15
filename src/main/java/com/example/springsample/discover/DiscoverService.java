package com.example.springsample.discover;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Predicate;
import java.util.function.Supplier;

import com.example.springsample.movie.MovieService;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tags;
import io.micrometer.core.instrument.Timer;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Service;

/**
 * Semantic search (query embedded in the app with an {@link EmbeddingModel}, pgvector cosine distance in HorizonDB)
 * and graph exploration (Apache AGE).
 * Each call is timed as {@code movielog.discover.*} with an {@code outcome} tag, and embedding, search and similar
 * calls also with a {@code model} tag, so the AKS Application Insights agent exports it to customMetrics next to the
 * other movielog meters.
 */
@Service
public class DiscoverService {

	private static final Logger logger = LoggerFactory.getLogger(DiscoverService.class);

	public static final int MAX_RESULTS = 30;

	public static final int MAX_QUERY_LENGTH = 200;

	private static final int GRAPH_CO_CREDITS = 60;

	private static final int GRAPH_PERSON_MOVIES = 30;

	private static final String GRAPH_POSTER_SIZE = "w92";

	private final EmbeddingModels embeddings;

	private final VectorSearchRepository vectors;

	private final MovieGraphRepository graph;

	private final MeterRegistry registry;

	private final DiscoverRateLimiter rateLimiter;

	private final Counter rejected;

	private final QueryCorrector corrector;

	private final MovieService movies;

	private final Counter corrected;

	public DiscoverService(EmbeddingModels embeddings, VectorSearchRepository vectors, MovieGraphRepository graph,
			MeterRegistry registry, DiscoverRateLimiter rateLimiter, QueryCorrector corrector, MovieService movies) {
		this.embeddings = embeddings;
		this.vectors = vectors;
		this.graph = graph;
		this.registry = registry;
		this.rateLimiter = rateLimiter;
		this.rejected = Counter.builder("movielog.discover.rejected")
			.description("Semantic searches refused by the rate cap before calling the embedding model")
			.register(registry);
		this.corrector = corrector;
		this.movies = movies;
		this.corrected = Counter.builder("movielog.discover.corrected")
			.description("Semantic searches whose misspelled name or title was corrected before embedding")
			.register(registry);
	}

	/** The model used when a request names none. */
	public EmbeddingModel defaultModel() {
		return embeddings.defaultModel();
	}

	/** Models with an endpoint, which a request may name. */
	public List<EmbeddingModel> configuredModels() {
		return embeddings.configured();
	}

	/**
	 * The model named by a request parameter, or the default model when it is blank.
	 * @throws UnknownEmbeddingModelException when the name is unknown or the model is not configured
	 */
	public EmbeddingModel resolveModel(@Nullable String requested) {
		return embeddings.resolve(requested);
	}

	/**
	 * @param client address of the caller (after forwarded headers), used for the per-client rate cap
	 */
	public List<MovieHit> search(String query, int limit, String client) {
		return search(query, limit, client, defaultModel());
	}

	public List<MovieHit> search(String query, int limit, String client, EmbeddingModel model) {
		return searchWithCorrection(query, limit, client, model).hits();
	}

	public DiscoverSearch searchWithCorrection(String query, int limit, String client) {
		return searchWithCorrection(query, limit, client, defaultModel());
	}

	/**
	 * Like {@link #search}, and reports a corrected person name or title. The corrected query is embedded and
	 * matched by keywords; the web page shows which words were replaced.
	 */
	public DiscoverSearch searchWithCorrection(String query, int limit, String client, EmbeddingModel model) {
		if (!rateLimiter.tryAcquire(client)) {
			rejected.increment();
			throw new DiscoverRateLimitedException("Too many semantic searches; try again in a minute");
		}
		String typed = truncate(query.strip(), MAX_QUERY_LENGTH);
		QueryCorrection correction = corrector.correct(typed).orElse(null);
		if (correction != null) {
			corrected.increment();
		}
		String input = (correction == null) ? typed : correction.query();
		float[] embedding = timed("movielog.discover.embedding", "query", model,
				() -> embeddings.embed(model, input), v -> false);
		List<MovieHit> hits = timed("movielog.discover.search", "vector", model,
				() -> vectors.search(model, embedding, input, Math.clamp(limit, 1, MAX_RESULTS)), List::isEmpty);
		return new DiscoverSearch(hits, correction, model);
	}

	/** Search results, the model that embedded the query and, when the query was corrected, the replaced words. */
	public record DiscoverSearch(List<MovieHit> hits, @Nullable QueryCorrection correction, EmbeddingModel model) {
	}

	public List<MovieHit> similar(long tmdbId, int limit) {
		return similar(tmdbId, limit, defaultModel());
	}

	/** Neighbors by the stored document vectors of {@code model}; no embedding call. */
	public List<MovieHit> similar(long tmdbId, int limit, EmbeddingModel model) {
		return timed("movielog.discover.similar", "vector", model,
				() -> vectors.similar(model, tmdbId, Math.clamp(limit, 1, MAX_RESULTS)), List::isEmpty);
	}

	/** The catalog's attributed summary of the movie, or null when there is none or the catalog cannot be read. */
	public @Nullable CatalogOverview catalogOverview(long tmdbId) {
		try {
			return vectors.catalogOverview(tmdbId);
		}
		catch (DataAccessException ex) {
			logger.warn("catalog overview lookup failed: {}", ex.getMostSpecificCause().getMessage());
			return null;
		}
	}

	public GraphView movieGraph(long tmdbId) {
		return withPosters(timed("movielog.discover.graph", "movie",
				() -> graph.neighborhood(tmdbId, GRAPH_CO_CREDITS), view -> view.nodes().isEmpty()));
	}

	public GraphView graphAmong(List<Long> tmdbIds) {
		List<Long> ids = tmdbIds.stream().distinct().limit(MAX_RESULTS).toList();
		return withPosters(timed("movielog.discover.graph", "results", () -> graph.among(ids),
				view -> view.nodes().isEmpty()));
	}

	/** A person and their movies in the graph, for expanding a Person node. */
	public GraphView personGraph(String qid) {
		return withPosters(timed("movielog.discover.graph", "person", () -> graph.person(qid, GRAPH_PERSON_MOVIES),
				view -> view.nodes().isEmpty()));
	}

	/** Posters are a nicety: a failed lookup leaves the colored placeholder nodes. */
	private GraphView withPosters(GraphView view) {
		List<Long> ids = view.nodes().stream().map(GraphView.Node::tmdbId).filter(Objects::nonNull).distinct().toList();
		try {
			Map<Long, String> urls = new HashMap<>();
			vectors.posterPaths(ids).forEach((id, path) -> {
				String url = movies.posterUrl(path, GRAPH_POSTER_SIZE);
				if (url != null) {
					urls.put(id, url);
				}
			});
			return view.withPosters(urls);
		}
		catch (DataAccessException ex) {
			logger.warn("graph poster lookup failed: {}", ex.getMostSpecificCause().getMessage());
			return view;
		}
	}

	/** Cuts at a code point boundary so a surrogate pair is never split. */
	static String truncate(String text, int maxCodePoints) {
		if (text.codePointCount(0, text.length()) <= maxCodePoints) {
			return text;
		}
		return text.substring(0, text.offsetByCodePoints(0, maxCodePoints));
	}

	private <T> T timed(String name, String kind, Supplier<T> call, Predicate<T> empty) {
		return timed(name, Tags.of("kind", kind), kind, call, empty);
	}

	private <T> T timed(String name, String kind, EmbeddingModel model, Supplier<T> call, Predicate<T> empty) {
		return timed(name, Tags.of("kind", kind, "model", model.id()), kind + ", " + model.id(), call, empty);
	}

	private <T> T timed(String name, Tags tags, String detail, Supplier<T> call, Predicate<T> empty) {
		Timer.Sample sample = Timer.start(registry);
		String outcome = "error";
		try {
			T result = call.get();
			outcome = empty.test(result) ? "empty" : "found";
			return result;
		}
		catch (DataAccessException ex) {
			logger.warn("{} ({}) failed: {}", name, detail, ex.getMostSpecificCause().getMessage());
			throw new DiscoverUnavailableException("Catalog search is not available", ex);
		}
		catch (EmbeddingUnavailableException ex) {
			logger.warn("{} ({}) failed: {}", name, detail, ex.getMessage());
			throw new DiscoverUnavailableException("Query embedding is not available", ex);
		}
		finally {
			sample.stop(registry.timer(name, tags.and("outcome", outcome)));
		}
	}

}
