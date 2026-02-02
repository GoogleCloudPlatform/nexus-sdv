package de.nexus.sdv.data_api_sampler.client;

import java.util.List;
import java.util.Map;

import com.google.protobuf.ByteString;

import de.nexus.sdv.data_api_sampler.client.config.DataApiClientConfiguration;

import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import dataapi.v1.DataApi;
import dataapi.v1.TelemetryDataAPIGrpc;
import io.grpc.StatusException;
import io.grpc.stub.BlockingClientCall;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.when;

/*
 * DataApiClientTest.java
 *
 * Created on 13.01.26
 *
 */
class DataApiClientTest {

    private final DataApiClientConfiguration dataApiClientConfiguration =
            mock(DataApiClientConfiguration.class);

    private final TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryStub = Mockito.mock(
            TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub.class);
    private final DataApiClient dataApiClient = spy(new DataApiClient(dataApiClientConfiguration, telemetryStub));

    @Test
    void retrieveData() throws StatusException, InterruptedException {
        final BlockingClientCall clientCall = mock(BlockingClientCall.class);
        when(telemetryStub.getTelemetryData(any())).thenReturn(clientCall);
        when(clientCall.hasNext()).thenReturn(true, true, false);
        final DataApi.TelemetryPoint telemetryPoint1 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data")).build();
        final DataApi.TelemetryPoint telemetryPoint2 =
                DataApi.TelemetryPoint.newBuilder().putValues("dataType", ByteString.copyFromUtf8("data2")).build();
        when(clientCall.read()).thenReturn(telemetryPoint1, telemetryPoint2);

        final Map<String, List<String>> result = dataApiClient.retrieveData("vin", "dataType", 0L);

        assertThat(result.size()).isEqualTo(1);
        assertThat(result.keySet().stream().findFirst().get()).isEqualTo("dataType");
        assertThat(result.get("dataType").size()).isEqualTo(2);
    }
}