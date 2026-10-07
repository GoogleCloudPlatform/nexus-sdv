package de.nexus.sdv.data_api_sampler;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.annotation.web.configurers.HeadersConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.security.web.SecurityFilterChain;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * Who may read telemetry through this service.
 *
 * <p>Until #558 the data endpoint was {@code permitAll} while the service was a
 * LoadBalancer, so anyone who knew a VIN could read that vehicle's history over
 * the internet. It now requires a Keycloak access token carrying the realm role
 * the factory-helper already requires.
 *
 * <p>The realm's signing keys are fetched from Keycloak inside the cluster over
 * plain HTTP. That is deliberate: Keycloak's TLS certificate comes from the
 * platform's own CA, and fetching the key set over HTTPS would mean shipping
 * that CA into the JVM truststore for no gain on a path that never leaves the
 * cluster. The issuer is still validated — against the issuer Keycloak itself
 * announces, see {@link DiscoveredIssuerValidator}.
 */
@Configuration
@EnableWebSecurity
@Slf4j
@RequiredArgsConstructor
public class CustomHttpSecurityConfig {

    @Value("${nexus.auth.jwk-set-uri}")
    private String jwkSetUri;

    @Value("${nexus.auth.discovery-uri}")
    private String discoveryUri;

    @Value("${nexus.auth.required-realm-role}")
    private String requiredRealmRole;

    @Bean
    public SecurityFilterChain securityFilterChain(final HttpSecurity httpSecurity) throws Exception {

        final String authority = "ROLE_" + requiredRealmRole;
        log.info("Telemetry reads require realm role [{}]; issuer from [{}]", requiredRealmRole, discoveryUri);

        httpSecurity.csrf(AbstractHttpConfigurer::disable)
                .authorizeHttpRequests(
                        authz -> authz
                                // (Actuator) Health — the kubelet has no token.
                                .requestMatchers(HttpMethod.GET, "/health").permitAll()
                                .requestMatchers(HttpMethod.GET, "/data/**").hasAuthority(authority)
                                .anyRequest().denyAll()

                )
                .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt -> jwt
                        .decoder(jwtDecoder())
                        .jwtAuthenticationConverter(realmRoleConverter())))
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .headers(
                        headersConfigurer ->
                                headersConfigurer
                                        .frameOptions(HeadersConfigurer.FrameOptionsConfig::disable)
                                        .cacheControl(HeadersConfigurer.CacheControlConfig::disable)
                );

        return httpSecurity.build();
    }

    /**
     * Validates signature, expiry and issuer. The audience is deliberately not
     * checked: Keycloak's client_credentials tokens carry an {@code aud} that
     * depends on the mapper configuration, which is the same reason
     * factory-helper's auth.rs sets {@code validate_aud} to false.
     */
    @Bean
    public JwtDecoder jwtDecoder() {
        final NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build();
        final OAuth2TokenValidator<Jwt> validator = new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefault(),
                new DiscoveredIssuerValidator(DiscoveredIssuerValidator.fromDiscovery(discoveryUri)));
        decoder.setJwtValidator(validator);
        return decoder;
    }

    /**
     * Keycloak puts realm roles under {@code realm_access.roles}; Spring expects
     * authorities. Without this converter every token would authenticate and
     * none would authorise.
     */
    static Converter<Jwt, AbstractAuthenticationToken> realmRoleConverter() {
        final JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(CustomHttpSecurityConfig::realmRoles);
        return jwt -> new JwtAuthenticationToken(jwt, realmRoles(jwt));
    }

    @SuppressWarnings("unchecked")
    static Collection<GrantedAuthority> realmRoles(final Jwt jwt) {
        final Object realmAccess = jwt.getClaims().get("realm_access");
        if (!(realmAccess instanceof Map<?, ?> claim)) {
            return List.of();
        }
        final Object roles = claim.get("roles");
        if (!(roles instanceof Collection<?> list)) {
            return List.of();
        }
        return ((Collection<String>) list).stream()
                .map(role -> (GrantedAuthority) new SimpleGrantedAuthority("ROLE_" + role))
                .toList();
    }
}
