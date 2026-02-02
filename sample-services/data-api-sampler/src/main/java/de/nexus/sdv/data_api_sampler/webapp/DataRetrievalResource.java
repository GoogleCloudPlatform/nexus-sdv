package de.nexus.sdv.data_api_sampler.webapp;

import java.util.List;
import java.util.Map;
import java.util.Objects;

import de.nexus.sdv.data_api_sampler.client.DataApiClient;

import org.springframework.util.ObjectUtils;
import org.springframework.util.StringUtils;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import lombok.RequiredArgsConstructor;

@RestController
@RequiredArgsConstructor
public class DataRetrievalResource {

    private final DataApiClient dataApiClient;

    @GetMapping("/data/{vin}/datatypes/{datatype}")
    public Map<String, List<String>> retrieveDataForVin(
            @PathVariable final String vin,
            @PathVariable final String datatype,
            @RequestParam(required = false) final String lookback) {

        final long since = extractLookbackDuration(lookback);

        return dataApiClient.retrieveData(vin, datatype, since);
    }

    private long extractLookbackDuration(final String lookback) {
        long since = 0L;
        if (lookback != null && !lookback.isEmpty()) {
            final String unit = lookback.substring(lookback.length() - 1).toLowerCase();
            final long value = Long.parseLong(lookback.substring(0, lookback.length() - 1));

            since = switch (unit) {
                case "s" -> value * 1000;
                case "m" -> value * 1000 * 60;
                case "h" -> value * 1000 * 60 * 60;
                case "d" -> value * 1000 * 60 * 60 * 24;
                default -> 0L;
            };
        }
        return since;
    }

}
