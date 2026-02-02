package de.nexus.sdv.data_api_sampler.client;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.google.protobuf.ByteString;
import com.google.protobuf.Timestamp;

import de.nexus.sdv.data_api_sampler.client.config.DataApiClientConfiguration;

import org.springframework.context.annotation.Bean;
import org.springframework.stereotype.Component;

import dataapi.v1.DataApi;
import dataapi.v1.TelemetryDataAPIGrpc;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.StatusException;
import io.grpc.stub.BlockingClientCall;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/*
 * DataApiClient.java
 *
 * Created on 13.01.26
 *
 */
@Component
@Slf4j
@RequiredArgsConstructor
public class DataApiClient {

    private final DataApiClientConfiguration config;
    private final TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryDataAPIBlockingV2Stub;

    public Map<String, List<String>> retrieveData(final String vin, final String dataType, final long recentInMillis) {
        log.info("Retrieving data for VIN: {} and dataType: {} for for the last Millis: {}", vin, dataType,
                recentInMillis);

        final List<String> telemetryData =
                getTelemetryDataFromDataApi(vin, dataType, recentInMillis);

        final Map<String, List<String>> result = new HashMap<>();
        result.put(dataType, telemetryData);
        return result;
    }

    List<String> getTelemetryDataFromDataApi(
            final String vin, final String dataType, final long recentInMillis) {
        final DataApi.GetTelemetryDataRequest.Builder builder = DataApi.GetTelemetryDataRequest.newBuilder()
                .setVehicleId(vin)
                .addDataTypes(dataType);

        if (recentInMillis == 0L) {
            builder.setLatest(true);
        } else {
            builder.setTimeRange(DataApi.TimeRange.newBuilder()
                    .setStart(Timestamp.newBuilder()
                            .setSeconds(convertMillisToSeconds(System.currentTimeMillis() - recentInMillis)).build())
                    .setEnd(Timestamp.newBuilder().setSeconds(convertMillisToSeconds(System.currentTimeMillis()))
                            .build())
                    .build());
        }

        final DataApi.GetTelemetryDataRequest request = builder.build();
        final BlockingClientCall<?, DataApi.TelemetryPoint> telemetryData =
                telemetryDataAPIBlockingV2Stub.getTelemetryData(request);

        final List<String> result = new ArrayList<>();
        try {
            while (telemetryData.hasNext()) {
                final DataApi.TelemetryPoint telemetryPoint = telemetryData.read();
                if (telemetryPoint != null) {
                    for (final Map.Entry<String, ByteString> entry : telemetryPoint.getValuesMap().entrySet()) {
                        final String telemetryPointValue = entry.getValue().toStringUtf8();
                        log.info("DataEntry - Key: {}, Value: {}", entry.getKey(), telemetryPointValue);
                        result.add(telemetryPointValue);
                    }
                }
            }

        } catch (StatusException | InterruptedException e) {
            log.error("Error during Data api call: ", e);
        }

        return result;
    }

    private static long convertMillisToSeconds(final long millis) {
        return millis / 1000;
    }

}
