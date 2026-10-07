package de.nexus.sdv.data_api_sampler.client.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.oauth2.client.OAuth2AuthorizeRequest;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;

import dataapi.v1.TelemetryDataAPIGrpc;
import io.grpc.CallOptions;
import io.grpc.Channel;
import io.grpc.ClientCall;
import io.grpc.ClientInterceptor;
import io.grpc.ForwardingClientCall;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
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

    /** The Spring Security client registration used to mint the access token. */
    private static final String REGISTRATION_ID = "data-api";

    private static final Metadata.Key<String> AUTHORIZATION =
            Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER);

    private String dataApiUrl;
    private String dataApiUsername;
    private String dataApiPassword;

    /**
     * The Data API requires a Keycloak token since #558, so every call carries
     * one. The channel itself is plaintext: the Data API is cluster-internal,
     * like the platform's other internal services.
     */
    @Bean
    TelemetryDataAPIGrpc.TelemetryDataAPIBlockingV2Stub telemetryDataApiBlockingV2Stub(
            final OAuth2AuthorizedClientManager authorizedClientManager) {

        log.info("Calling the Data API at [{}]", dataApiUrl);

        final ManagedChannel channel = ManagedChannelBuilder
                .forTarget(dataApiUrl)
                .usePlaintext()
                .intercept(bearerTokenInterceptor(authorizedClientManager))
                .build();

        return TelemetryDataAPIGrpc.newBlockingV2Stub(channel);
    }

    /**
     * Puts the service's own access token on every outgoing call.
     *
     * <p>The manager caches the token and fetches a new one when it expires, so
     * this is one Keycloak round trip per token lifetime, not per request.
     */
    static ClientInterceptor bearerTokenInterceptor(final OAuth2AuthorizedClientManager manager) {
        return new ClientInterceptor() {
            @Override
            public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
                    final MethodDescriptor<ReqT, RespT> method,
                    final CallOptions callOptions,
                    final Channel next) {

                return new ForwardingClientCall.SimpleForwardingClientCall<>(
                        next.newCall(method, callOptions)) {
                    @Override
                    public void start(final Listener<RespT> responseListener, final Metadata headers) {
                        headers.put(AUTHORIZATION, "Bearer " + accessToken(manager));
                        super.start(responseListener, headers);
                    }
                };
            }
        };
    }

    private static String accessToken(final OAuth2AuthorizedClientManager manager) {
        final var request = OAuth2AuthorizeRequest.withClientRegistrationId(REGISTRATION_ID)
                .principal(REGISTRATION_ID)
                .build();
        final var client = manager.authorize(request);
        if (client == null || client.getAccessToken() == null) {
            throw new IllegalStateException(
                    "no access token for client registration '" + REGISTRATION_ID
                            + "' — check the Keycloak client secret");
        }
        return client.getAccessToken().getTokenValue();
    }
}
