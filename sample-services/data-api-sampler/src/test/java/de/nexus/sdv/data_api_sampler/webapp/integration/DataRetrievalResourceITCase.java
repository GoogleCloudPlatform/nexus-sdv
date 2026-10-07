package de.nexus.sdv.data_api_sampler.webapp.integration;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import com.google.protobuf.ByteString;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.resttestclient.autoconfigure.AutoConfigureRestTestClient;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpHeaders;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.client.EntityExchangeResult;
import org.springframework.test.web.servlet.client.RestTestClient;

import dataapi.v1.DataApi;
import dataapi.v1.TelemetryDataAPIGrpc;
import io.grpc.StatusException;
import io.grpc.stub.BlockingClientCall;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/*
 * DataRetrievalResourceITCase.java
 *
 * Created on 13.01.26
 *
 * Until #558 these tests asked for telemetry with no credentials at all and
 * asserted 200. That was an accurate description of the service: the data
 * endpoint was permitAll while the service was a LoadBalancer, so anyone who
 * knew a VIN could read that vehicle's history over the internet. The tests now
 * describe what the service does instead of what it did.
 *
 * The JwtDecoder is mocked rather than reaching a Keycloak, so the real filter
 * chain, the realm-role converter and the authorization rule are all exercised.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureRestTestClient
@ExtendWith(MockitoExtension.class)
@TestPropertySource(locations = "classpath:application-test.properties")
class DataRetrievalResourceITCase {

    private static final String REQUIRED_ROLE = "factory-operator";
    private static final String WITH_ROLE = "token-with-the-role";
    private static final String WITHOUT_ROLE = "token-without-the-role";

    @LocalServerPort
    private int port;

    @MockitoBean
    private TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryDataApiBlockingV2Stub;

    @MockitoBean
    private JwtDecoder jwtDecoder;

    private static String BASE_URL = "http://localhost:%d/";

    private static final String PATH = "/data/VEHICLE001/datatypes/dynamic:battery.temp";

    @Autowired
    private RestTestClient restTestClient;

    /**
     * Only the calls that reach the handler need these stubs. A request refused
     * by the filter chain never touches the Data API client or the decoder, and
     * Mockito's strict stubbing says so.
     */
    private void stubAnAuthorisedCall() throws StatusException, InterruptedException {
        final BlockingClientCall clientCall = mock(BlockingClientCall.class);
        when(telemetryDataApiBlockingV2Stub.getTelemetryData(any())).thenReturn(clientCall);
        when(clientCall.hasNext()).thenReturn(true, true, false);
        final DataApi.TelemetryPoint telemetryPoint1 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data")).build();
        final DataApi.TelemetryPoint telemetryPoint2 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data2")).build();
        when(clientCall.read()).thenReturn(telemetryPoint1, telemetryPoint2);

        when(jwtDecoder.decode(eq(WITH_ROLE))).thenReturn(tokenWithRoles(List.of("other", REQUIRED_ROLE)));
    }

    private static Jwt tokenWithRoles(final List<String> roles) {
        return Jwt.withTokenValue("irrelevant")
                .header("alg", "RS256")
                .claim("realm_access", Map.of("roles", roles))
                .issuedAt(Instant.now())
                .expiresAt(Instant.now().plusSeconds(3600))
                .build();
    }

    @Test
    void retrieveDataForVin_withoutAToken_isRefused() {
        restTestClient.get().uri(BASE_URL.formatted(port) + PATH)
                .exchange().expectStatus().isUnauthorized();
    }

    @Test
    void retrieveDataForVin_withoutTheRealmRole_isRefused() {
        when(jwtDecoder.decode(eq(WITHOUT_ROLE))).thenReturn(tokenWithRoles(List.of("other")));
        restTestClient.get().uri(BASE_URL.formatted(port) + PATH)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + WITHOUT_ROLE)
                .exchange().expectStatus().isForbidden();
    }

    @Test
    void retrieveDataForVin() throws StatusException, InterruptedException {
        stubAnAuthorisedCall();
        final EntityExchangeResult<String> stringEntityExchangeResult = restTestClient.get().uri(
                        BASE_URL.formatted(port) + PATH)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + WITH_ROLE)
                .exchange().expectStatus().isOk()
                .expectBody(String.class)
                .returnResult();

        assertThat(stringEntityExchangeResult.getResponseBody()).isNotBlank();
    }

    @Test
    void retrieveDataForVin_withLookBack() throws StatusException, InterruptedException {
        stubAnAuthorisedCall();
        final EntityExchangeResult<String> stringEntityExchangeResult = restTestClient.get().uri(
                        BASE_URL.formatted(port) + PATH + "?lookback=5d")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + WITH_ROLE)
                .exchange().expectStatus().isOk()
                .expectBody(String.class)
                .returnResult();

        assertThat(stringEntityExchangeResult.getResponseBody()).isNotBlank();
    }

    @Test
    void health_staysOpen() {
        restTestClient.get().uri(BASE_URL.formatted(port) + "/health")
                .exchange().expectStatus().isOk();
    }
}
