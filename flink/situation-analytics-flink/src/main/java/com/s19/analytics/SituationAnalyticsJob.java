package com.s19.analytics;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.java.utils.ParameterTool;
import org.apache.flink.connector.base.DeliveryGuarantee;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.runtime.state.storage.JobManagerCheckpointStorage;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.kafka.clients.consumer.OffsetResetStrategy;

import java.util.Arrays;
import java.util.List;

/**
 * Situation Analytics - real-time stream processing (requirement e).
 *
 * <pre>
 *  Kafka: incident-events, dispatch-events, consistency-events
 *     -> SituationPipeline (parse, event-time watermarks, 1-minute tumbling window per region with
 *        unique-reporter set, cross-window keyed-state surge detector)
 *     -> Kafka: incident-aggregates                       (separate results topic)
 * </pre>
 * Arguments (all optional): --bootstrap 10.10.0.100:9094 --group situation-analytics-flink
 *   --input-topics incident-events,dispatch-events,consistency-events --output-topic incident-aggregates
 *   --window-seconds 60 --checkpoint-dir hdfs:///flink/checkpoints/situation-analytics (or "jobmanager")
 *   --surge-min 5 --surge-factor 2.0 --starting-offsets latest|earliest --parallelism 1
 */
public class SituationAnalyticsJob {

    public static void main(String[] args) throws Exception {
        ParameterTool p = ParameterTool.fromArgs(args);
        String bootstrap = p.get("bootstrap", "10.10.0.100:9094");
        String group = p.get("group", "situation-analytics-flink");
        List<String> topics = Arrays.asList(
                p.get("input-topics", "incident-events,dispatch-events,consistency-events").split(","));
        String outputTopic = p.get("output-topic", "incident-aggregates");
        long windowSeconds = p.getLong("window-seconds", 60L);
        String checkpointDir = p.get("checkpoint-dir", "hdfs:///flink/checkpoints/situation-analytics");
        long surgeMin = p.getLong("surge-min", 5L);
        double surgeFactor = p.getDouble("surge-factor", 2.0);
        OffsetResetStrategy reset = "earliest".equalsIgnoreCase(p.get("starting-offsets", "latest"))
                ? OffsetResetStrategy.EARLIEST : OffsetResetStrategy.LATEST;

        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.getConfig().setGlobalJobParameters(p);
        env.setParallelism(p.getInt("parallelism", 1));
        env.enableCheckpointing(30_000L, CheckpointingMode.EXACTLY_ONCE);
        if ("jobmanager".equals(checkpointDir)) {
            // local docker compose: keep the (small) checkpoints in JobManager memory, no shared filesystem needed
            env.getCheckpointConfig().setCheckpointStorage(new JobManagerCheckpointStorage());
        } else {
            env.getCheckpointConfig().setCheckpointStorage(checkpointDir);   // Dataproc: hdfs:///...
        }
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(10_000L);

        KafkaSource<String> source = KafkaSource.<String>builder()
                .setBootstrapServers(bootstrap)
                .setTopics(topics)
                .setGroupId(group)
                .setStartingOffsets(OffsetsInitializer.committedOffsets(reset))
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .setProperty("partition.discovery.interval.ms", "60000")
                .setProperty("commit.offsets.on.checkpoint", "true")
                .build();

        DataStream<String> raw = env.fromSource(source, WatermarkStrategy.noWatermarks(), "kafka-disaster-events");
        DataStream<String> results = SituationPipeline.build(raw, windowSeconds, surgeMin, surgeFactor);

        KafkaSink<String> sink = KafkaSink.<String>builder()
                .setBootstrapServers(bootstrap)
                .setRecordSerializer(KafkaRecordSerializationSchema.builder()
                        .setTopic(outputTopic)
                        .setValueSerializationSchema(new SimpleStringSchema())
                        .build())
                .setDeliveryGuarantee(DeliveryGuarantee.AT_LEAST_ONCE)
                .build();
        results.sinkTo(sink).name("kafka-" + outputTopic);

        env.execute("s19-situation-analytics");
    }
}
