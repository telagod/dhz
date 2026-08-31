// Lightweight SDK logs implementation for the embedded runtime.
const SUCCESS = 0;
class Logger {
    constructor(provider, name, version) { this.provider = provider; this.instrumentationScope = { name, version }; }
    emit(record) { if (!this.provider._shutdown) this.provider._processors.forEach((processor) => processor.onEmit(record)); }
}
class SimpleLogRecordProcessor {
    constructor(config = {}) { this._exporter = config.exporter || config; this._shutdown = false; }
    onEmit(record) { if (this._shutdown || !this._exporter || typeof this._exporter.export !== 'function') return; this._exporter.export([record], () => {}); }
    forceFlush() { return Promise.resolve(); }
    shutdown() { this._shutdown = true; return this._exporter && this._exporter.shutdown ? this._exporter.shutdown() : Promise.resolve(); }
}
class BatchLogRecordProcessor extends SimpleLogRecordProcessor {
    constructor(config = {}) { super(config); this._queue = []; this._maxExportBatchSize = config.maxExportBatchSize || 512; }
    onEmit(record) { if (this._shutdown) return; this._queue.push(record); if (this._queue.length >= this._maxExportBatchSize) this._flush(); }
    _flush() { if (!this._queue.length || !this._exporter || typeof this._exporter.export !== 'function') return Promise.resolve(); const batch = this._queue.splice(0, this._maxExportBatchSize); return new Promise((resolve) => this._exporter.export(batch, () => resolve())); }
    forceFlush() { return this._flush(); }
    shutdown() { return this.forceFlush().then(() => super.shutdown()); }
}
class LoggerProvider {
    constructor(config = {}) { this._processors = config.processors || []; this._resource = config.resource; this._shutdown = false; }
    getLogger(name, version) { return new Logger(this, name, version); }
    forceFlush() { return Promise.all(this._processors.map((processor) => processor.forceFlush ? processor.forceFlush() : Promise.resolve())).then(() => undefined); }
    shutdown() { if (this._shutdown) return Promise.resolve(); this._shutdown = true; return Promise.all(this._processors.map((processor) => processor.shutdown ? processor.shutdown() : Promise.resolve())).then(() => undefined); }
}
class NoopLogRecordProcessor { onEmit() {} forceFlush() { return Promise.resolve(); } shutdown() { return Promise.resolve(); } }
class InMemoryLogRecordExporter { constructor() { this.records = []; this._shutdown = false; } export(records, callback) { this.records.push(...records); callback({ code: SUCCESS }); } getFinishedLogRecords() { return this.records.slice(); } reset() { this.records = []; } shutdown() { this._shutdown = true; return Promise.resolve(); } forceFlush() { return Promise.resolve(); } }
class ConsoleLogRecordExporter extends InMemoryLogRecordExporter {}
export { Logger, LoggerProvider, BatchLogRecordProcessor, SimpleLogRecordProcessor, NoopLogRecordProcessor, InMemoryLogRecordExporter, ConsoleLogRecordExporter };
export default { Logger, LoggerProvider, BatchLogRecordProcessor, SimpleLogRecordProcessor };
