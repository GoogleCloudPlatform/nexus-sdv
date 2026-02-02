package de.nexus.sdv.data_api_sampler;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.annotation.web.configurers.HeadersConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Configuration
@EnableWebSecurity
@Slf4j
@RequiredArgsConstructor
public class CustomHttpSecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(final HttpSecurity httpSecurity) throws Exception {

        httpSecurity.csrf(AbstractHttpConfigurer::disable)
                .authorizeHttpRequests(
                        authz -> authz
                                // (Actuator) Health
                                .requestMatchers(HttpMethod.GET, "/health").permitAll()
                                .requestMatchers(HttpMethod.GET, "/data/**").permitAll()
                                .anyRequest().denyAll()

                )
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .headers(
                        headersConfigurer ->
                                headersConfigurer
                                        .frameOptions(HeadersConfigurer.FrameOptionsConfig::disable)
                                        .cacheControl(HeadersConfigurer.CacheControlConfig::disable)
                );

        return httpSecurity.build();
    }

}
