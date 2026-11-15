package com.example.springsample.discover;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.springsample.IntegrationTest;
import org.junit.jupiter.api.Test;

/** The test profile configures no embedding endpoint, so no model can be named. */
class DiscoverModelApiTests extends IntegrationTest {

	@Test
	void searchRejectsUnknownAndUnconfiguredModels() throws Exception {
		for (String model : new String[] { "bge", "openai", "embedding_bge", "gpt" }) {
			mockMvc.perform(get("/api/discover/search").param("q", "듄").param("model", model).with(user("alice")))
				.andExpect(status().isBadRequest())
				.andExpect(jsonPath("$.code").value("UNKNOWN_EMBEDDING_MODEL"))
				.andExpect(jsonPath("$.available").isEmpty());
		}
	}

	@Test
	void similarRejectsUnknownModels() throws Exception {
		mockMvc.perform(get("/api/discover/movies/438631/similar").param("model", "gpt").with(user("alice")))
			.andExpect(status().isBadRequest())
			.andExpect(jsonPath("$.code").value("UNKNOWN_EMBEDDING_MODEL"));
	}

	@Test
	void searchWithoutAModelUsesTheDefaultAndReportsItUnavailable() throws Exception {
		mockMvc.perform(get("/api/discover/search").param("q", "듄").with(user("alice")))
			.andExpect(status().isServiceUnavailable());
	}

}
