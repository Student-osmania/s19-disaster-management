package com.s19.analytics;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

import java.util.List;

/** `mvn test`: runs the pipeline on a local Flink MiniCluster (see PipelineScenario). */
class SituationPipelineTest {
    @Test
    void windowsUniqueReportersAndSurgeState() throws Exception {
        List<String> failures = PipelineScenario.verify(PipelineScenario.run());
        assertEquals(List.of(), failures);
    }
}
