package de.nexus.sdv.data_api_sampler;

import java.time.Instant;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The issuer is learned from Keycloak rather than configured, because it differs
 * between remote and local PKI. These cover the cases that change made possible:
 * Keycloak not up yet, and a learned issuer that is asked for once.
 */
class DiscoveredIssuerValidatorTest {

    private static final String LOCAL = "https://34.158.153.37:8443/realms/sdv-telemetry";
    private static final String REMOTE = "https://keycloak-ui.example.test/realms/sdv-telemetry";

    private static Jwt tokenFrom(final String issuer) {
        return Jwt.withTokenValue("irrelevant")
                .header("alg", "RS256")
                .claim("iss", issuer)
                .issuedAt(Instant.now())
                .expiresAt(Instant.now().plusSeconds(3600))
                .build();
    }

    @Test
    void aTokenFromTheAnnouncedIssuerPasses_oneFromElsewhereDoesNot() {
        final DiscoveredIssuerValidator validator = new DiscoveredIssuerValidator(() -> LOCAL);
        assertThat(validator.validate(tokenFrom(LOCAL)).hasErrors()).isFalse();
        assertThat(validator.validate(tokenFrom(REMOTE)).hasErrors()).isTrue();
    }

    @Test
    void keycloakNotUpYet_thatTokenIsRefused_theNextOneSucceeds() {
        final AtomicBoolean up = new AtomicBoolean(false);
        final DiscoveredIssuerValidator validator = new DiscoveredIssuerValidator(() -> {
            if (!up.get()) {
                throw new IllegalStateException("connection refused");
            }
            return REMOTE;
        });

        assertThat(validator.validate(tokenFrom(REMOTE)).hasErrors()).isTrue();
        up.set(true);
        assertThat(validator.validate(tokenFrom(REMOTE)).hasErrors()).isFalse();
    }

    @Test
    void aLearnedIssuerIsAskedForOnce() {
        final AtomicInteger asked = new AtomicInteger();
        final DiscoveredIssuerValidator validator = new DiscoveredIssuerValidator(() -> {
            asked.incrementAndGet();
            return REMOTE;
        });
        for (int i = 0; i < 5; i++) {
            assertThat(validator.validate(tokenFrom(REMOTE)).hasErrors()).isFalse();
        }
        assertThat(asked.get()).isEqualTo(1);
    }
}
