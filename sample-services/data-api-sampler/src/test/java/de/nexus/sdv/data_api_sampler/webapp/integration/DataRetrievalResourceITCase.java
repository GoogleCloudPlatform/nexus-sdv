package de.nexus.sdv.data_api_sampler.webapp.integration;

import com.google.protobuf.ByteString;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.resttestclient.autoconfigure.AutoConfigureRestTestClient;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
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
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/*
 * DataRetrievalResourceTest.java
 *
 * Created on 13.01.26
 *
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureRestTestClient
@ExtendWith(MockitoExtension.class)
@TestPropertySource(locations = "classpath:application-test.properties")
class DataRetrievalResourceITCase {

    @LocalServerPort
    private int port;

    @MockitoBean
    private TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryDataApiBlockingV2Stub;

    private static String BASE_URL = "http://localhost:%d/";

    @Autowired
    private RestTestClient restTestClient;

    @BeforeEach
    void setUp() throws StatusException, InterruptedException {
        final BlockingClientCall clientCall = mock(BlockingClientCall.class);
        when(telemetryDataApiBlockingV2Stub.getTelemetryData(any())).thenReturn(clientCall);
        when(clientCall.hasNext()).thenReturn(true, true, false);
        final DataApi.TelemetryPoint telemetryPoint1 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data")).build();
        final DataApi.TelemetryPoint telemetryPoint2 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data2")).build();
        when(clientCall.read()).thenReturn(telemetryPoint1, telemetryPoint2);
    }

    @Test
    void retrieveDataForVin() {
        final EntityExchangeResult<String> stringEntityExchangeResult = restTestClient.get().uri(
                        BASE_URL.formatted(port) + "/data/VEHICLE001/datatypes/dynamic:battery.temp")
                .exchange().expectStatus().isOk()
                .expectBody(String.class)
                .returnResult();

        assertThat(stringEntityExchangeResult.getResponseBody()).isNotBlank();
    }

    @Test
    void retrieveDataForVin_withLookBack() {
        final EntityExchangeResult<String> stringEntityExchangeResult = restTestClient.get().uri(
                        BASE_URL.formatted(port) + "/data/VEHICLE001/datatypes/dynamic:battery.temp?lookback=5d")
                .exchange().expectStatus().isOk()
                .expectBody(String.class)
                .returnResult();

        assertThat(stringEntityExchangeResult.getResponseBody()).isNotBlank();
    }
}