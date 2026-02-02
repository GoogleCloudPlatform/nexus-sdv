package de.nexus.sdv.data_api_sampler.client.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import dataapi.v1.TelemetryDataAPIGrpc;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import lombok.Getter;
import lombok.Setter;
import lombok.ToString;
import lombok.extern.slf4j.Slf4j;

/*
 * DataApiClientConfiguration.java
 *
 * Created on 13.01.26
 *
 */
@Configuration
@Getter
@Setter
@ConfigurationProperties(prefix = "data-api.client")
@ToString
@Slf4j
public class DataApiClientConfiguration {

    private String dataApiUrl;
    private String dataApiUsername;
    private String dataApiPassword;

    @Bean
    TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryDataApiBlockingV2Stub() {
        log.info("Retrieving data with configuration: dataApiUrl[{}], dataApiUsername[{}]", dataApiUrl,
                dataApiUsername);
        final ManagedChannel channel = ManagedChannelBuilder
                .forTarget(dataApiUrl)
                .usePlaintext()
                .build();
        return TelemetryDataAPIGrpc.newBlockingV2Stub(channel);
    }
}
