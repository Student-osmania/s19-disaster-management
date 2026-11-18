package com.s19.analytics;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.util.CloseableIterator;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Runs SituationPipeline on a real local Flink MiniCluster with a bounded input and checks the window
 * results. Plain Java (no JUnit) so it can also be run with java directly; SituationPipelineTest wraps it
 * for `mvn test`.
 */
public final class PipelineScenario {

    static final long T0 = 1_700_000_040_000L;          // aligned to a minute boundary

    private PipelineScenario() {}

    static String ev(String type, String region, long ts, String extra) {
        return "{\"eventType\":\"" + type + "\",\"region\":\"" + region + "\",\"ts\":" + ts
                + (extra.isEmpty() ? "" : "," + extra) + "}";
    }

    static List<String> input() {
        List<String> in = new ArrayList<>();
        // ---- window A [T0, T0+60s)
        in.add(ev("INCIDENT_REPORTED", "north", T0 + 1_000, "\"severity\":\"CRITICAL\",\"reporterId\":\"r1\""));
        in.add(ev("INCIDENT_REPORTED", "north", T0 + 2_000, "\"severity\":\"HIGH\",\"reporterId\":\"r1\""));
        in.add(ev("DISPATCH_CREATED", "north", T0 + 3_000, "\"resourceCount\":3,\"volunteerCount\":5"));
        in.add(ev("CONFLICT_DETECTED", "north", T0 + 4_000, ""));
        in.add(ev("READ_REPAIR", "north", T0 + 5_000, ""));
        in.add(ev("INCIDENT_REPORTED", "south", T0 + 6_000, "\"severity\":\"LOW\",\"reporterId\":\"s1\""));
        in.add("this is not json");                                    // counted as parse error, skipped
        // ---- window B [T0+60s, T0+120s)
        for (int i = 1; i <= 6; i++) {
            in.add(ev("INCIDENT_REPORTED", "north", T0 + 60_000 + i * 1_000,
                    "\"severity\":\"MEDIUM\",\"reporterId\":\"n" + i + "\""));
            if (i == 1) {
                // out-of-order event of window A, 7 s behind the max timestamp: within the 10 s bound
                in.add(ev("READ_REPAIR", "north", T0 + 55_000, ""));
            }
        }
        in.add(ev("QUORUM_FAILURE", "north", T0 + 70_000, ""));
        in.add(ev("ANTI_ENTROPY_REPAIR", "global", T0 + 75_000, "\"repaired\":4"));
        return in;
    }

    /** Executes the job and returns results keyed by "region@windowStart". */
    public static Map<String, JsonNode> run() throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(1);
        DataStream<String> raw = env.fromCollection(input());
        DataStream<String> out = SituationPipeline.build(raw, 60, 5, 2.0);
        ObjectMapper m = new ObjectMapper();
        Map<String, JsonNode> res = new HashMap<>();
        try (CloseableIterator<String> it = out.executeAndCollect("s19-pipeline-scenario")) {
            while (it.hasNext()) {
                String line = it.next();
                System.out.println("RESULT " + line);
                JsonNode n = m.readTree(line);
                res.put(n.get("region").asText() + "@" + n.get("windowStart").asLong(), n);
            }
        }
        return res;
    }

    static void expect(boolean cond, String what, List<String> failures) {
        System.out.println((cond ? "[PASS] " : "[FAIL] ") + what);
        if (!cond) {
            failures.add(what);
        }
    }

    /** Returns the list of failed checks (empty = all passed). */
    public static List<String> verify(Map<String, JsonNode> r) {
        List<String> f = new ArrayList<>();
        JsonNode na = r.get("north@" + T0);
        JsonNode nb = r.get("north@" + (T0 + 60_000));
        JsonNode sa = r.get("south@" + T0);
        JsonNode gb = r.get("global@" + (T0 + 60_000));
        expect(r.size() == 4, "4 window results (north A, north B, south A, global B), got " + r.size(), f);
        expect(na != null && na.get("windowEnd").asLong() == T0 + 60_000, "north window A has 1-minute bounds", f);
        expect(na != null && na.get("incidents").asLong() == 2 && na.get("critical").asLong() == 1,
                "north A: 2 incidents, 1 critical", f);
        expect(na != null && na.get("uniqueReporters").asLong() == 1, "north A: 1 unique reporter (r1 twice)", f);
        expect(na != null && na.get("dispatches").asLong() == 1 && na.get("resourcesDispatched").asLong() == 3
                && na.get("volunteersDispatched").asLong() == 5, "north A: dispatch demand 3 resources / 5 volunteers", f);
        expect(na != null && na.get("conflicts").asLong() == 1 && na.get("readRepairs").asLong() == 2,
                "north A: 1 conflict, 2 read repairs (incl. the out-of-order event)", f);
        expect(na != null && !na.get("surge").asBoolean(), "north A: no surge (2 < surgeMin 5)", f);
        expect(nb != null && nb.get("incidents").asLong() == 6 && nb.get("uniqueReporters").asLong() == 6,
                "north B: 6 incidents from 6 unique reporters", f);
        expect(nb != null && nb.get("prevIncidents").asLong() == 2 && nb.get("baseline").asDouble() == 2.0,
                "north B: keyed state carried previous window (prev=2, baseline=2.0)", f);
        expect(nb != null && nb.get("surge").asBoolean(), "north B: SURGE detected (6 >= 5 and 6 >= 2 x 2)", f);
        expect(nb != null && nb.get("quorumFailures").asLong() == 1, "north B: 1 quorum failure", f);
        expect(sa != null && sa.get("incidents").asLong() == 1 && !sa.get("surge").asBoolean(), "south A: 1 incident", f);
        expect(gb != null && gb.get("antiEntropyRepairs").asLong() == 4, "global B: 4 anti-entropy repairs", f);
        return f;
    }

    public static void main(String[] args) throws Exception {
        List<String> failures = verify(run());
        System.out.println(failures.isEmpty() ? "ALL FLINK PIPELINE CHECKS PASSED"
                : failures.size() + " FLINK PIPELINE CHECK(S) FAILED");
        System.exit(failures.isEmpty() ? 0 : 1);
    }
}
