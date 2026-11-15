package com.example.springsample.discover;

import java.util.List;

import com.example.springsample.movie.MovieService;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.jspecify.annotations.Nullable;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;

@Controller
@RequiredArgsConstructor
class DiscoverWebController {

	private static final int PAGE_RESULTS = 12;

	private final DiscoverService discoverService;

	private final MovieService movieService;

	/**
	 * An unknown or unconfigured {@code model} falls back to the default model with a notice. When both models are
	 * configured, the page links to the same query with the other model.
	 */
	@GetMapping("/discover")
	String search(@RequestParam(required = false) @Nullable String q,
			@RequestParam(name = "model", required = false) @Nullable String requestedModel, Model model,
			HttpServletRequest request) {
		String query = (q == null) ? "" : q.strip();
		model.addAttribute("q", query);
		EmbeddingModel embeddingModel;
		try {
			embeddingModel = discoverService.resolveModel(requestedModel);
			if (StringUtils.hasText(requestedModel)) {
				model.addAttribute("requestedModel", embeddingModel.id());
			}
		}
		catch (UnknownEmbeddingModelException ex) {
			embeddingModel = discoverService.defaultModel();
			model.addAttribute("modelNotice", true);
		}
		model.addAttribute("searchModelLabel", embeddingModel.label());
		EmbeddingModel current = embeddingModel;
		List<EmbeddingModel> configured = discoverService.configuredModels();
		if (configured.contains(current)) {
			configured.stream().filter(other -> other != current).findFirst().ifPresent(other -> {
				model.addAttribute("otherModel", other.id());
				model.addAttribute("otherModelLabel", other.label());
			});
		}
		if (StringUtils.hasText(query)) {
			try {
				DiscoverService.DiscoverSearch search = discoverService.searchWithCorrection(query, PAGE_RESULTS,
						request.getRemoteAddr(), embeddingModel);
				List<MovieHit> hits = search.hits();
				model.addAttribute("hits", hits);
				model.addAttribute("correction", search.correction());
				model.addAttribute("hitIds", hits.stream().map(hit -> String.valueOf(hit.tmdbId())).toList());
			}
			catch (DiscoverUnavailableException ex) {
				model.addAttribute("searchFailed", true);
			}
			catch (DiscoverRateLimitedException ex) {
				model.addAttribute("searchLimited", true);
			}
		}
		return "discover/search";
	}

	@GetMapping("/graph/movies/{tmdbId}")
	String graph(@PathVariable long tmdbId, Model model) {
		model.addAttribute("movie", movieService.getMovie(tmdbId));
		return "discover/graph";
	}

}
