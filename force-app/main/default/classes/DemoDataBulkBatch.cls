/**
 * Adds ANY number of demo candidates in the background. Every candidate gets a designed PDF resume built in Apex (about 0.1 second of
 * CPU each), and one synchronous call has only 10 seconds of CPU, so DemoDataLoader adds at most 25 candidates per transaction. This
 * batch adds one chunk of up to 25 per batch run, so each run is its own transaction with its own limits and the total is not limited.
 * The runs go one after another, so each one continues the numbering of the one before.
 *
 * Start it with DemoDataLoader.addBulkAsync(500) (DemoDataLoader.addBulk(500) does the same) and watch it in Setup > Apex Jobs.
 * Run it with a scope of 1 (addBulkAsync does).
 */
public with sharing class DemoDataBulkBatch implements Database.Batchable<Integer>, Iterable<Integer> {
    /** How many candidates each batch run adds: one entry per run. */
    @TestVisible private final List<Integer> chunks = new List<Integer>();

    public DemoDataBulkBatch(Integer total) {
        this(total, DemoDataLoader.CHUNK_SIZE);
    }

    /** total candidates in chunks of chunkSize (never more than one transaction can add, never less than 1). */
    public DemoDataBulkBatch(Integer total, Integer chunkSize) {
        Integer size = Math.min(DemoDataLoader.CHUNK_SIZE, Math.max(1, chunkSize == null ? DemoDataLoader.CHUNK_SIZE : chunkSize));
        Integer left = total == null ? 0 : total;
        while (left > 0) {
            Integer n = Math.min(left, size);
            chunks.add(n);
            left -= n;
        }
    }

    /** How many batch runs (chunks) the total needs. */
    public Integer runs() {
        return chunks.size();
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        return this;
    }

    public Iterator<Integer> iterator() {
        return chunks.iterator();
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        for (Integer n : scope) { DemoDataLoader.addNow(n); }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('BULK DEMO DATA FINISHED: ' + chunks.size() + ' runs, demo contacts now '
            + [SELECT COUNT() FROM Contact WHERE Email LIKE '%@demo-candidates.example']);
    }
}
