package com.example.springsample.discover;

import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.not;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.List;

import com.example.springsample.IntegrationTest;
import org.junit.jupiter.api.Test;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

class DiscoverModelWebTests extends IntegrationTest {

	private static final MovieHit DUNE = new MovieHit(438631, "듄", "Dune", 2021, List.of("SF"), "줄거리", null, 0.61);

	@MockitoBean
	private DiscoverService discoverService;

	private void searchReturnsDune(EmbeddingModel model) {
		given(discoverService.searchWithCorrection(eq("dune"), anyInt(), anyString(), eq(model)))
			.willReturn(new DiscoverService.DiscoverSearch(List.of(DUNE), null, model));
	}

	@Test
	void namesTheModelAndLinksToTheSameQueryWithTheOtherModel() throws Exception {
		given(discoverService.resolveModel(null)).willReturn(EmbeddingModel.BGE);
		given(discoverService.configuredModels()).willReturn(List.of(EmbeddingModel.OPENAI, EmbeddingModel.BGE));
		searchReturnsDune(EmbeddingModel.BGE);

		mockMvc.perform(get("/discover").param("q", "dune"))
			.andExpect(status().isOk())
			.andExpect(content().string(containsString("임베딩 모델: <span>BGE-M3 한국어 (dragonkue/BGE-m3-ko)</span>")))
			.andExpect(content().string(containsString("href=\"/discover?q=dune&amp;model=openai\"")))
			.andExpect(content().string(containsString("Azure OpenAI text-embedding-3-large(으)로 다시 검색")))
			.andExpect(content().string(not(containsString("name=\"model\""))));
	}

	@Test
	void keepsAnExplicitModelForTheNextQuery() throws Exception {
		given(discoverService.resolveModel("openai")).willReturn(EmbeddingModel.OPENAI);
		given(discoverService.configuredModels()).willReturn(List.of(EmbeddingModel.OPENAI, EmbeddingModel.BGE));
		searchReturnsDune(EmbeddingModel.OPENAI);

		mockMvc.perform(get("/discover").param("q", "dune").param("model", "openai"))
			.andExpect(status().isOk())
			.andExpect(content().string(containsString("<input type=\"hidden\" name=\"model\" value=\"openai\">")))
			.andExpect(content().string(containsString("href=\"/discover?q=dune&amp;model=bge\"")));
	}

	@Test
	void unknownModelFallsBackToTheDefaultWithANoticeAndNoOtherModelLink() throws Exception {
		given(discoverService.resolveModel("<script>")).willThrow(new UnknownEmbeddingModelException(List.of()));
		given(discoverService.defaultModel()).willReturn(EmbeddingModel.BGE);
		given(discoverService.configuredModels()).willReturn(List.of(EmbeddingModel.BGE));
		searchReturnsDune(EmbeddingModel.BGE);

		mockMvc.perform(get("/discover").param("q", "dune").param("model", "<script>"))
			.andExpect(status().isOk())
			.andExpect(content().string(containsString("요청한 임베딩 모델을 사용할 수 없어 기본 모델")))
			.andExpect(content().string(containsString("듄")))
			.andExpect(content().string(not(containsString("다시 검색"))))
			.andExpect(content().string(not(containsString("<script>"))));
	}

}
