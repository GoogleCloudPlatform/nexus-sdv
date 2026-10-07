package de.nexus.sdv.data_api_sampler;

import java.util.Map;
import java.util.function.Supplier;

import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.client.RestClient;

import lombok.extern.slf4j.Slf4j;

/**
 * Checks a token's issuer against the issuer Keycloak itself announces.
 *
 * <p>The issuer differs by installation — {@code keycloak-ui.<domain>} on remote
 * PKI, the load balancer address on local PKI — so it is learned from Keycloak's
 * OpenID discovery document rather than configured. Building it from the base
 * domain matched only the remote case and rejected every token on a local
 * platform.
 *
 * <p>The issuer is asked for on the first validation, not at start-up, so the
 * sampler does not depend on Keycloak being up when it starts. A failed lookup
 * rejects that one token and is retried on the next; a successful one is kept.
 */
@Slf4j
public class DiscoveredIssuerValidator implements OAuth2TokenValidator<Jwt> {

    private final Supplier<String> issuerSource;
    private volatile String issuer;

    public DiscoveredIssuerValidator(final Supplier<String> issuerSource) {
        this.issuerSource = issuerSource;
    }

    /** The issuer field of an OpenID discovery document. */
    @SuppressWarnings("unchecked")
    public static Supplier<String> fromDiscovery(final String discoveryUri) {
        final RestClient http = RestClient.create();
        return () -> {
            final Map<String, Object> doc = http.get().uri(discoveryUri).retrieve().body(Map.class);
            final Object issuer = doc == null ? null : doc.get("issuer");
            if (!(issuer instanceof String value) || value.isBlank()) {
                throw new IllegalStateException("discovery document at " + discoveryUri + " has no issuer");
            }
            return value;
        };
    }

    @Override
    public OAuth2TokenValidatorResult validate(final Jwt jwt) {
        final String expected;
        try {
            expected = currentIssuer();
        } catch (RuntimeException e) {
            log.warn("Cannot establish the token issuer from Keycloak: {}", e.getMessage());
            return OAuth2TokenValidatorResult.failure(
                    new OAuth2Error("invalid_token", "the token issuer cannot be established", null));
        }
        final String actual = jwt.getClaimAsString("iss");
        if (expected.equals(actual)) {
            return OAuth2TokenValidatorResult.success();
        }
        return OAuth2TokenValidatorResult.failure(
                new OAuth2Error("invalid_token", "the token was issued by another issuer", null));
    }

    private String currentIssuer() {
        String known = issuer;
        if (known == null) {
            synchronized (this) {
                known = issuer;
                if (known == null) {
                    known = issuerSource.get();
                    issuer = known;
                    log.info("Tokens are checked against issuer [{}]", known);
                }
            }
        }
        return known;
    }
}
