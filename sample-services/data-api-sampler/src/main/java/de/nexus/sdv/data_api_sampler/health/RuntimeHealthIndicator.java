package de.nexus.sdv.data_api_sampler.health;

import java.text.DecimalFormat;

import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.stereotype.Component;

@Component
public class RuntimeHealthIndicator implements HealthIndicator {

    private static final DecimalFormat myFormatter = new DecimalFormat("###");
    private static final int MB = 1024 * 1024;

    @Override
    public Health health() {
        return Health.up()
                .withDetail("totalMemory", myFormatter.format(Runtime.getRuntime().totalMemory() / MB))
                .withDetail("maxMemory", myFormatter.format(Runtime.getRuntime().maxMemory() / MB))
                .withDetail("freeMemory", myFormatter.format(Runtime.getRuntime().freeMemory() / MB))
                .withDetail("availableProcessors", Runtime.getRuntime().availableProcessors())
                .build();
    }
}
