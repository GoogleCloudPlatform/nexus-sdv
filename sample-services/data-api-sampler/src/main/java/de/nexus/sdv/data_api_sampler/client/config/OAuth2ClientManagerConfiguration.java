package de.nexus.sdv.data_api_sampler.client.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.oauth2.client.AuthorizedClientServiceOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientProviderBuilder;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientService;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;

/**
 * The token source for this service's own calls to the Data API (#558).
 *
 * <p>Spring Boot auto-configures the registration repository and the authorized
 * client service from the properties, but not a manager: the servlet default is
 * built around a logged-in user, and this service calls the Data API as itself.
 * {@link AuthorizedClientServiceOAuth2AuthorizedClientManager} is the
 * service-to-service variant, and it caches the token until it expires.
 */
@Configuration
public class OAuth2ClientManagerConfiguration {

    @Bean
    OAuth2AuthorizedClientManager authorizedClientManager(
            final ClientRegistrationRepository registrations,
            final OAuth2AuthorizedClientService authorizedClients) {

        final var manager = new AuthorizedClientServiceOAuth2AuthorizedClientManager(
                registrations, authorizedClients);
        manager.setAuthorizedClientProvider(
                OAuth2AuthorizedClientProviderBuilder.builder().clientCredentials().build());
        return manager;
    }
}
