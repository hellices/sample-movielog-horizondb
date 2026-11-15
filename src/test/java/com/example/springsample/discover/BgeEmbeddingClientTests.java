package com.example.springsample.discover;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withBadRequest;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import java.util.List;
import java.util.stream.IntStream;

import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.test.json.JsonCompareMode;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

class BgeEmbeddingClientTests {

	private static final String URL = "http://embeddings.test/v1/embeddings";

	private MockRestServiceServer server;

	private BgeEmbeddingClient client(String bgeUrl) {
		return client(bgeUrl, null);
	}

	private BgeEmbeddingClient client(String bgeUrl, String bgeModel) {
		RestClient.Builder builder = RestClient.builder();
		server = MockRestServiceServer.bindTo(builder).build();
		return new BgeEmbeddingClient(new EmbeddingProperties("", null, 0, null, bgeUrl, bgeModel, null), builder);
	}

	@Test
	void postsTheInputsWithTheServedModelNameAndNoCredentialsAndOrdersVectorsByIndex() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		server.expect(requestTo(URL))
			.andExpect(method(HttpMethod.POST))
			.andExpect(request -> assertThat(request.getHeaders().containsHeader(HttpHeaders.AUTHORIZATION)).isFalse())
			.andExpect(header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE))
			.andExpect(content().json("""
					{"input":["우주 가족","사막 행성"],"model":"dragonkue/BGE-m3-ko"}""", JsonCompareMode.STRICT))
			.andRespond(withSuccess("""
					{"object":"list","model":"dragonkue/BGE-m3-ko",
					 "data":[{"object":"embedding","embedding":[0.5,0.25],"index":1},
					         {"object":"embedding","embedding":[1.0,-1.0],"index":0}],
					 "usage":{"prompt_tokens":8,"total_tokens":8}}""", MediaType.APPLICATION_JSON));

		List<float[]> vectors = client.embedAll(List.of("우주 가족", "사막 행성"));

		assertThat(vectors).hasSize(2);
		assertThat(vectors.get(0)).containsExactly(1.0f, -1.0f);
		assertThat(vectors.get(1)).containsExactly(0.5f, 0.25f);
		server.verify();
	}

	@Test
	void sendsTheConfiguredServedModelName() {
		BgeEmbeddingClient client = client("http://embeddings.test", "bge-m3-ko");
		server.expect(requestTo(URL))
			.andExpect(content().json("""
					{"input":["듄"],"model":"bge-m3-ko"}""", JsonCompareMode.STRICT))
			.andRespond(withSuccess("""
					{"data":[{"embedding":[0.5],"index":0}]}""", MediaType.APPLICATION_JSON));

		assertThat(client.embed("듄")).containsExactly(0.5f);
		server.verify();
	}

	@Test
	void splitsInputsIntoBatchesOfThirtyTwo() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		List<String> texts = IntStream.range(0, 33).mapToObj(i -> "doc " + i).toList();
		String full = IntStream.range(0, 32)
			.mapToObj(i -> "{\"embedding\":[" + i + "],\"index\":" + i + "}")
			.reduce((a, b) -> a + "," + b)
			.orElseThrow();
		String firstInputs = IntStream.range(0, 32)
			.mapToObj(i -> "\"doc " + i + "\"")
			.reduce((a, b) -> a + "," + b)
			.orElseThrow();
		server.expect(times(1), requestTo(URL))
			.andExpect(content().json("{\"input\":[" + firstInputs + "],\"model\":\"dragonkue/BGE-m3-ko\"}",
					JsonCompareMode.STRICT))
			.andRespond(withSuccess("{\"data\":[" + full + "]}", MediaType.APPLICATION_JSON));
		server.expect(times(1), requestTo(URL))
			.andExpect(content().json("""
					{"input":["doc 32"],"model":"dragonkue/BGE-m3-ko"}""", JsonCompareMode.STRICT))
			.andRespond(withSuccess("""
					{"data":[{"embedding":[32],"index":0}]}""", MediaType.APPLICATION_JSON));

		List<float[]> vectors = client.embedAll(texts);

		assertThat(vectors).hasSize(33);
		assertThat(vectors.get(31)).containsExactly(31f);
		assertThat(vectors.get(32)).containsExactly(32f);
		server.verify();
	}

	@Test
	void httpErrorsAndIncompleteResponsesAreEmbeddingErrors() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		server.expect(requestTo(URL)).andRespond(withBadRequest().contentType(MediaType.APPLICATION_JSON).body("""
				{"object":"error","message":"The model `other` does not exist.","type":"BadRequestError","code":400}"""));
		server.expect(requestTo(URL)).andRespond(withServerError().contentType(MediaType.APPLICATION_JSON).body("""
				{"object":"error","message":"engine dead","type":"InternalServerError","code":500}"""));
		server.expect(requestTo(URL)).andRespond(withSuccess("""
				{"data":[]}""", MediaType.APPLICATION_JSON));
		server.expect(requestTo(URL)).andRespond(withSuccess("""
				{"data":[{"embedding":[],"index":0}]}""", MediaType.APPLICATION_JSON));

		assertThatThrownBy(() -> client.embed("a")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("BGE embedding call failed");
		assertThatThrownBy(() -> client.embed("a")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("BGE embedding call failed");
		assertThatThrownBy(() -> client.embed("b")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("0 embeddings for 1 inputs");
		assertThatThrownBy(() -> client.embed("c")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("Empty");
		server.verify();
	}

	@Test
	void duplicateIndexesAreEmbeddingErrors() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		server.expect(requestTo(URL)).andRespond(withSuccess("""
				{"data":[{"embedding":[1.0],"index":0},{"embedding":[2.0],"index":0}]}""", MediaType.APPLICATION_JSON));

		assertThatThrownBy(() -> client.embedAll(List.of("a", "b"))).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("indexes [0, 0] for 2 inputs");
		server.verify();
	}

	@Test
	void missingIndexIsAnEmbeddingErrorRatherThanIndexZero() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		server.expect(requestTo(URL)).andRespond(withSuccess("""
				{"data":[{"embedding":[1.0]},{"embedding":[2.0],"index":1}]}""", MediaType.APPLICATION_JSON));

		assertThatThrownBy(() -> client.embedAll(List.of("a", "b"))).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("indexes [null, 1] for 2 inputs");
		server.verify();
	}

	@Test
	void nullValueInAnEmbeddingIsAnEmbeddingError() {
		BgeEmbeddingClient client = client("http://embeddings.test");
		server.expect(requestTo(URL)).andRespond(withSuccess("""
				{"data":[{"embedding":[0.5,null],"index":0}]}""", MediaType.APPLICATION_JSON));

		assertThatThrownBy(() -> client.embed("a")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("Null value at position 1");
		server.verify();
	}

	@Test
	void blankUrlDisablesTheModelWithoutRequests() {
		BgeEmbeddingClient client = client(" ");

		assertThat(client.isEnabled()).isFalse();
		assertThatThrownBy(() -> client.embed("a")).isInstanceOf(EmbeddingUnavailableException.class)
			.hasMessageContaining("EMBEDDINGS_BGE_URL");
		server.verify();
	}

}
