package de.nexus.sdv.data_api_sampler.webapp;

import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import de.nexus.sdv.data_api_sampler.client.DataApiClient;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

/*
 * DataRetrievalResourceTest.java
 *
 * Created on 14.01.26
 *
 */
@ExtendWith(MockitoExtension.class)
class DataRetrievalResourceTest {

    @Mock
    private DataApiClient client;

    @InjectMocks
    private DataRetrievalResource resource;

    @Test
    void retrieveDataForVin() {
        final Map<String, List<String>> retrievedData = new HashMap<>();
        final String vin = "vin";
        final String datatype = "datatype";

        retrievedData.put("dataType", Arrays.asList("data1", "data2"));
        when(client.retrieveData(eq(vin), eq(datatype), anyLong())).thenReturn(retrievedData);

        final Map<String, List<String>> result = resource.retrieveDataForVin(vin, datatype, null);

        assertThat(result).isNotEmpty();

    }
}