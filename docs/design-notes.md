# 설계 메모

[README](../README.md)를 보충하는 문서입니다. 파일마다 맡은 역할과 구현하면서 내린 결정을 정리했습니다.

## 파일별 역할

| 경로 | 용도 |
|---|---|
| `src/`, `build.gradle.kts`, `settings.gradle.kts`, `gradlew` | 애플리케이션(Gradle Kotlin DSL) |
| `Dockerfile`, `agent-init/Dockerfile` | 앱 이미지와 Application Insights Java agent 3.7.10 init image |
| `.github/workflows/ci.yml` | PR·main: 테스트와 이미지 빌드 확인(push 없음) |
| `.github/workflows/release.yml` | `vX.Y.Z` 태그: 테스트 → `ghcr.io/hellices/sample-movielog-horizondb` push → build provenance |
| `k8s/10-instrumentation.yaml` | AKS autoinstrumentation의 Application Insights 연결 |
| `k8s/21-agent-3.7.10.patch.yaml` | 관리형 agent 주입을 3.7.10 init image로 바꾸는 patch |
| `k8s/30-loadgen.yaml` | `loadgen/loadgen.py`를 실행하는 부하 Deployment |
| `data/build_catalog.py` | Wikidata(감독·배우·장르·TMDB id)와 Wikipedia 요약으로 영화 약 480편의 `catalog.json`·`catalog.sql`을 만듭니다. 표준 라이브러리만 씁니다. |
| `data/enrich_tmdb.py` | `catalog.json`의 TMDB id로 TMDB 상세 API를 호출해 비어 있는 포스터·상영 시간·IMDb id만 채우는 `tmdb.sql`을 만듭니다. Wikipedia 제목과 요약은 바꾸지 않습니다. |
| `data/embed_catalog.py` | `catalog.movie_docs.doc`을 Azure OpenAI `text-embedding-3-large`(1,536차원)로 임베딩해 저장합니다. Azure CLI의 Entra token을 씁니다. |
| `db/00-database.sql` | `movielog` DB와 앱 role을 만듭니다. |
| `db/10-schema.sql` | `vector`, `pg_diskann`, `age` 확장과 `catalog` schema를 만듭니다. |
| `db/20-vector-index.sql` | `embedding`에 DiskANN 코사인 index를 만듭니다. |
| `db/30-graph.sql` | 관계형 카탈로그에서 AGE 그래프 `movie_graph`를 처음 만듭니다. 영화마다 임베딩 최근접 3편을 `SIMILAR_TO`로 잇습니다. 이후 변경은 `40-graph-sync.sql`이 반영합니다. |
| `db/40-graph-sync.sql` | 그래프 변경 queue(`catalog.graph_queue`)와 관계형 테이블 trigger, 바뀐 영화만 그래프에 반영하고 `SIMILAR_TO`를 맞추는 `catalog.process_graph_queue`, 관계형과 그래프의 차이를 queue에 넣는 `catalog.enqueue_graph_drift`(둘 다 SECURITY DEFINER)와 앱의 `INSERT` 권한입니다. `30-graph.sql` 다음에 한 번 실행합니다. |
| `src/main/java/.../discover/` | 의미 검색(모델 목록 `EmbeddingModel`·`EmbeddingModels`, Azure OpenAI `EmbeddingClient`, vLLM 등 OpenAI 호환 서버용 `BgeEmbeddingClient`, 벡터·키워드 순위를 RRF로 합치는 `VectorSearchRepository`), 인물·제목 철자 교정(`QueryCorrector`), 카탈로그 밖 영화 색인(`CatalogIndexer`, `TmdbCreditsClient`), 그래프 조회(`MovieGraphRepository`), `movielog.discover.*` Timer를 기록하는 `DiscoverService`, 웹·API controller입니다. |
| `src/main/resources/templates/discover/`, `static/js/graph.js` | `/discover` 의미 검색 화면과 `/graph/movies/{tmdbId}` 그래프 화면입니다. Cytoscape.js와 fCoSE 레이아웃으로 그리며, 영화 노드는 TMDB 포스터로 표시하고, 범례 칩으로 관계 종류를 거르고, 누른 노드의 정보 패널에서 인물의 다른 작품을 펼칩니다. 키보드·스크린 리더용 관계 텍스트 목록과 영화 링크를 함께 렌더링합니다. |
| `azure.yaml` | azd 프로젝트입니다. service 없이 hook 네 개(`preprovision`, `postprovision`, `postdeploy`, `predown`)로 배포합니다. |
| `infra/main.bicep`, `infra/resources.bicep` | HorizonDB를 뺀 Azure 리소스와 역할 할당입니다. hook이 쓰는 이름과 endpoint를 output으로 넘깁니다. |
| `hooks/` | HorizonDB 생성, DB 준비, Key Vault, Entra ID 앱, Kubernetes 배포, 카탈로그 적재, HTTPS, 정리를 다시 실행해도 같은 결과가 되게 수행합니다. |
| `k8s/40-embeddings-vllm.yaml` | GPU spot 노드에서 vLLM으로 `dragonkue/BGE-m3-ko`를 서빙하는 Deployment와 클러스터 내부 Service입니다. |
| `k8s/00-namespace.yaml` | namespace와 workload identity ServiceAccount입니다. |
| `k8s/20-movielog.yaml` | HorizonDB 연결(secret)과 Azure OpenAI endpoint를 받는 앱 Deployment입니다. |
| `k8s/24-keyvault-secrets.yaml` | Secrets Store CSI driver가 Key Vault의 TMDB·OMDb 키와 Entra ID client secret을 앱 workload identity로 읽어 `movielog-keyvault` secret으로 동기화하는 SecretProviderClass입니다. |
| `src/main/java/.../member/`, `config/SecurityConfig.java`, `templates/auth/login.html`, `application-entra.properties` | 아이디·비밀번호 로그인 옆에 Microsoft Entra ID(OpenID Connect) 로그인을 더하고, 첫 로그인 때 `tid`·`oid`로 회원을 만듭니다. `entra` profile에서만 켜집니다. |
| `k8s/26-agfc.yaml` | Application Gateway for Containers(AKS add-on)로 앱을 커스텀 도메인 HTTPS로 공개하는 ApplicationLoadBalancer, HTTP·HTTPS listener Gateway, 앱 HTTPRoute, HTTP→HTTPS redirect HTTPRoute와 session affinity·health check policy입니다. |
| `k8s/27-tls.yaml` | cert-manager가 Let's Encrypt에서 HTTP-01 challenge로 인증서를 받아 `movielog-tls` secret에 넣는 ClusterIssuer와 Certificate입니다. |
| `loadgen/loadgen.py` | 가입·조회·리뷰와 의미 검색·그래프 조회를 반복하는 합성 사용자입니다. 작성한 합성 리뷰는 조회한 뒤 항상 삭제해 리뷰 목록에 쌓이지 않습니다. Deployment는 `k8s/30-loadgen.yaml`입니다. |
| `grafana/movielog-horizondb-dashboard.json` | discover Timer, HorizonDB·Azure OpenAI dependency, discover 요청을 보는 dashboard입니다. resource ID 변수는 비어 있습니다. |

## 설계 결정

- **Microsoft Entra ID 로그인은 기존 회원 구조에 붙입니다.** `entra` profile이 single-tenant 앱
  등록을 OpenID Connect client로 등록하면 로그인 화면에 Entra ID 버튼이 생깁니다. 첫 로그인 때 ID token의
  변하지 않는 `tid`·`oid`로 `members.external_id`(`entra:<tid>:<oid>`)를 만들고, 아이디는
  `preferred_username` 앞부분과 hash로 `<이름>-<6자리>` 형태를 씁니다. 회원가입 아이디는 `-`를 쓸 수 없어
  둘이 겹치지 않습니다. 닉네임은 `name` claim에서 가져오며 이후 이름이 바뀌어도 회원은 그대로입니다.
  principal이 `UserDetails`이기도 해서 리뷰·댓글 코드는 두 로그인 방식을 구분하지 않습니다. 필요한 claim이
  ID token에 있으므로 Microsoft Graph user info는 호출하지 않으며, 로그아웃은 앱 session만 끝냅니다.
- **앱 비밀값은 Key Vault에서 받습니다.** TMDB·OMDb 키와 Entra ID client secret은 Key Vault에 두고,
  AKS Secrets Store CSI driver가 앱과 같은 workload identity로 읽어 환경 변수로 넘깁니다. 실습 구독에서는
  Azure Policy(`modify`)가 Key Vault의 공용 네트워크 접근을 끄므로, AKS VNet에 private endpoint와
  `privatelink.vaultcore.azure.net` private DNS zone을 둡니다. 운영자는 Key Vault data plane 대신 ARM
  `Microsoft.KeyVault/vaults/secrets`로 값을 넣습니다.

- **AKS 배포는 모든 화면에 로그인을 요구합니다.** 기본 MovieLog 앱은 목록·상세를 익명으로 읽게
  열어 두지만, 이 예제의 `aks` profile은 `app.security.require-login=true`로 로그인·회원가입·정적
  파일·health를 뺀 모든 화면과 API를 막습니다. 로그인하지 않으면 화면은 `/login`으로 redirect되고 API는
  401을 받습니다. 기본값은 `false`라 로컬과 기본 앱 테스트는 그대로입니다.
- **의미 검색에 요청률 한도를 둡니다.** 회원 가입이 열려 있어 누구나 계정을 만들어 `/discover`와
  `/api/discover/search`로 Azure OpenAI를 호출할 수 있으므로, 앱이 Azure OpenAI를 부르기 전에 Pod마다 클라이언트 주소당 분당
  30건(`DISCOVER_RATE_LIMIT_PER_CLIENT`)과 전체 분당 300건(`DISCOVER_RATE_LIMIT_TOTAL`)으로
  제한합니다. 넘으면 API는 429, 화면은 안내 문구를 돌려줍니다. 클라이언트 주소는 AGFC가 넘기는
  `x-forwarded-for`에서 Tomcat이 얻습니다. 카운터는 분마다 비우고 한 분에 주소 1만 개까지만
  추적해 그 이상 새 주소는 다음 분까지 거부합니다. 한도는 Pod 메모리에 있어 replica 수만큼 늘어나며,
  Azure OpenAI deployment의 용량(실습은 GlobalStandard 150K TPM)이 마지막 상한입니다.

- **질의 임베딩은 앱에서 합니다.** HorizonDB `azure_ai` 2.5.6은 `azure_ai.set_setting`을
  막고 `model_registry`에 등록한 alias로 모델을 호출합니다. 실습에서 확인한 제약은
  다음과 같습니다.
  - 관리자가 쓰는 alias 기반 `model_registry.model_add`는 PUBLIC에 열려 있고 BYOM으로
    등록합니다. UUID와 `registry_type`을 받는 `model_add_with_registry_type` 등 UUID
    overload는 EXECUTE가 `azuresu`에만 있어 관리자도 `permission denied`를 받습니다.
    이 함수들은 AI Model Management가 `default-embedding` 같은 managed model을 등록하는
    서비스 경로입니다.
  - BYOM에 `managed-identity`를 지정하면 "managed identity authentication is not
    supported for bring-your-own (BYOM) models"로 거부됩니다. Learn 문서의 등록 예는
    `managed-identity`를 허용한다고 적고 있어 동작과 다릅니다.
  - AI Model Management는 limited preview라 참여 신청 승인이 필요합니다. 승인 전에는
    cluster `aiModelManagement`를 `Enabled`로 바꿀 수 없습니다(`AiModelManagementAfecNotRegistered`).
  - `azure_openai.create_embeddings()`·`ai.embed()`는 `{endpoint}/openai/deployments/{deployment}/embeddings`
    형식으로 호출하며, Learn이 밝힌 임베딩 지원 모델은 `text-embedding-3-small`, `text-embedding-3-large`,
    `text-embedding-ada-002`입니다. `*.inference.ml.azure.com/score` 같은 Azure ML endpoint는 "Endpoint is not valid"로
    거부됐습니다. BYOM의 API Management endpoint 등록 경로에 OpenAI 형식으로 응답하는 mock을 두고 모델 이름을
    `bge-m3-ko`로 등록하면 `ai.embed()`가 응답을 받아들였지만, BGE-M3는 지원 모델 목록 밖이므로 이 예제는 DB 안
    임베딩 대신 앱에서 임베딩합니다.

  key 인증을 끈 Azure OpenAI에서는 앱이 workload identity로 embedding을 받아 벡터를 SQL
  parameter로 넘깁니다. 같은 이유로 앱 쪽 client만 바꾸면 다른 embedding 모델도 쓸 수 있습니다.
- **Azure OpenAI 모델은 `text-embedding-3-large`를 1,536차원으로 줄여 씁니다.** 소규모 한국어 질의 점검을 보고
  골랐으며, 정답 집합으로 `text-embedding-3-small`과 품질을 평가한 결과는 아닙니다. 앱과
  `embed_catalog.py`는 같은 deployment와 차원을 써야 합니다.
- **임베딩 문서에는 한국어 요약과 영어 요약을 함께 넣습니다.** 한국어 Wikipedia
  도입부는 제작 정보 위주라 줄거리 질의와 잘 맞지 않았습니다. 화면에는 한국어
  요약만 보입니다.
- **카탈로그 밖의 영화는 앱이 색인합니다.** 회원이 TMDB 검색으로 처음 연 영화는
  `public.movies`에만 저장되므로, `aks` profile의 `CatalogIndexer`가 30초마다 문서가 없는
  영화를 찾아 TMDB credits를 더한 문서를 임베딩해 `catalog.movie_docs`에 넣고, 인물(TMDB가 아는
  Wikidata id로 카탈로그 인물과 연결)·출연·장르를 `catalog.*`에 넣습니다. `db/10-schema.sql`과
  `db/40-graph-sync.sql`의 권한이 필요합니다.
- **그래프는 변경분만 반영합니다.** 관계형 테이블의 trigger가 바뀐 영화를 `catalog.graph_queue`에 넣고,
  `aks` profile의 `MovieGraphSync`가 30초마다 `catalog.process_graph_queue`로 그 영화만 다시 만들고
  `SIMILAR_TO`를 맞춥니다. 1시간마다 관계형과 그래프의 차이도 점검합니다. 카탈로그를 다시 적재해도
  `30-graph.sql`을 다시 실행할 필요가 없습니다.
- **틀린 철자는 인물·제목 사전으로 고칩니다.** 어떤 영화 문서에도 없는 단어가 든 구간을 한글 자모
  편집 거리로 `catalog.people` 이름과 영화 제목에 맞춰 보고, 유사도 0.75 이상이며 2위보다 0.1 이상
  높을 때만 바꿉니다(「드늬 뷜베브」 → 「드니 빌뇌브」).
- **의미 검색은 벡터 순위와 키워드 순위를 합칩니다.** 「듄」, 「드니 빌뇌브」 같은 짧은 제목·이름
  질의는 문서 전체 임베딩만으로는 순위가 낮아, 질의 단어의 절반 이상이 문서 머리(제목·장르·감독·
  출연)에 있는 영화의 순위를 Reciprocal Rank Fusion으로 더합니다. 서술형 질의 결과는 그대로입니다.
- **AGE 다중 시작점 조회는 `UNWIND`로 씁니다.** `MATCH (a:Movie)-[r]-(b) WHERE
  a.tmdb_id IN [...]`는 모든 edge를 훑어 영화 8편에 약 27초가 걸렸고,
  `UNWIND [...] AS t MATCH (a:Movie {tmdb_id: t})-[r]-(b)`는 같은 결과를 약 0.1초에
  돌려줬습니다. 그래프 생성 스크립트는 label table에 GIN index를 만듭니다.
- **Cypher 문자열에는 숫자 id만 넣습니다.** Cypher에는 JDBC parameter를 쓸 수 없고,
  `(a:Movie)`를 Spring의 named parameter로 오인하지 않도록 `JdbcTemplate`을 씁니다.
- 영화 약 480편 규모에서는 planner가 DiskANN 대신 seq scan을 고릅니다.
  `SET enable_seqscan = off`로 index 경로를 확인할 수 있습니다.
- **임베딩 모델을 둘 둔 이유** — 한국어로 미세 조정한 BGE-M3(1,024차원)와 Azure OpenAI `text-embedding-3-large`
  (1,536차원)를 요청마다 `model=bge|openai`로 고를 수 있게 두었습니다. 앱 기본값은 BGE-M3이지만 품질 평가에 따른
  선택이 아니라 예제 구성입니다. 모델마다 열(`embedding_bge`, `embedding`)과
  DiskANN index가 따로 있고, SQL의 열 이름과 `vector(n)` 차원은 요청 값이 아니라 `EmbeddingModel` enum에서만 옵니다.
  `SIMILAR_TO` 그래프 관계는 기본 모델인 bge 임베딩으로 만듭니다.
